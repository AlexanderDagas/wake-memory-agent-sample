import Foundation
import XCTest
@testable import WakeMemoryAgentCore

private actor TestModel: MemoryModel {
    let body: @Sendable (MemoryRequest) async throws -> Data
    private(set) var calls = 0
    init(_ body: @escaping @Sendable (MemoryRequest) async throws -> Data) { self.body = body }
    func proposeUpdate(for request: MemoryRequest) async throws -> Data {
        calls += 1
        return try await body(request)
    }
}

private actor BlockingModel: MemoryModel {
    private var continuation: CheckedContinuation<Data, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0

    func proposeUpdate(for request: MemoryRequest) async throws -> Data {
        calls += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            waiters.forEach { $0.resume() }; waiters.removeAll()
        }
    }
    func waitUntilRequested() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish(_ response: Data) { continuation?.resume(returning: response); continuation = nil }
}

private func encoded(_ operations: [MemoryOperation]) throws -> Data {
    try JSONEncoder().encode(ProposedBatch(operations: operations))
}
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private func turn(_ id: Int, role: SourceTurn.Role = .user, seconds: Double = 0) -> SourceTurn {
    .init(id: id, role: role, text: "Synthetic portfolio statement \(id).", date: epoch.addingTimeInterval(seconds))
}
private func goal(_ source: Int, text: String = "Finish the portfolio") -> MemoryOperation {
    .init(action: .add, kind: .goal, key: "portfolio", text: text, sourceTurnID: source)
}

@MainActor
final class MemoryWorkerTests: XCTestCase {
    func testValidResultCommitsFactsAndAcknowledgementTogether() async throws {
        let model = TestModel { _ in try encoded([goal(1)]) }
        let worker = MemoryWorker(model: model)
        try await worker.append(turn(1))
        let outcome = await worker.processPending(at: epoch)
        XCTAssertEqual(outcome, .applied(proposedOperationCount: 1, through: 1))
        let state = await worker.currentSnapshot()
        XCTAssertEqual(state.facts["goal:portfolio"]?.text, "Finish the portfolio")
        XCTAssertEqual(state.acknowledgedThrough, 1)
        let pending = await worker.pendingTurnCount()
        XCTAssertEqual(pending, 0)
    }

    func testOneInvalidOperationRejectsWholeBatchAndRetainsInput() async throws {
        let invalid = MemoryOperation(action: .add, kind: .goal, key: " ", text: "Invalid", sourceTurnID: 1)
        let model = TestModel { _ in try encoded([goal(1), invalid]) }
        let worker = MemoryWorker(model: model)
        try await worker.append(turn(1))
        let outcome = await worker.processPending(at: epoch)
        XCTAssertEqual(outcome, .retryScheduled(at: epoch.addingTimeInterval(60), reason: .invalidOperations))
        let state = await worker.currentSnapshot()
        XCTAssertTrue(state.facts.isEmpty)
        XCTAssertEqual(state.acknowledgedThrough, 0)
        let pending = await worker.pendingTurnCount()
        XCTAssertEqual(pending, 1)
    }

    func testAssistantOrInventedSourceCannotBecomeAUserFact() async throws {
        for source in [1, 999] {
            XCTAssertThrowsError(try MemoryValidator.applying(.init(operations: [goal(source)]),
                to: .init(), sourceTurns: [turn(1, role: .assistant)])) { error in
                XCTAssertEqual(error as? MemoryValidationError, .invalidSource)
            }
        }
    }

    func testOlderCorrectionCannotOverwriteNewerFact() async throws {
        let current = MemoryFact(kind: .goal, key: "portfolio", text: "Ship the demo",
            sourceTurnID: 2, sourceDate: epoch.addingTimeInterval(10))
        let initial = MemorySnapshot(facts: ["goal:portfolio": current])
        for operation in [goal(1, text: "Outdated plan"),
                          .init(action: .retract, kind: .goal, key: "portfolio", sourceTurnID: 1)] {
            let result = try MemoryValidator.applying(.init(operations: [operation]),
                to: initial, sourceTurns: [turn(1)])
            XCTAssertEqual(result, initial)
        }
    }

    func testDuplicateProposalsAreIdempotentAndOmittedStatusIsPreserved() async throws {
        let operation = MemoryOperation(action: .update, kind: .commitment, key: "portfolio",
            text: "Finish the revised demo", sourceTurnID: 1)
        let fact = MemoryFact(kind: .commitment, key: "portfolio", text: "Finish a demo",
            status: .open, sourceTurnID: 0, sourceDate: epoch.addingTimeInterval(-10))
        let initial = MemorySnapshot(facts: ["commitment:portfolio": fact])
        let once = try MemoryValidator.applying(.init(operations: [operation]), to: initial, sourceTurns: [turn(1)])
        let twice = try MemoryValidator.applying(.init(operations: [operation, operation]), to: initial, sourceTurns: [turn(1)])
        XCTAssertEqual(once, twice)
        XCTAssertEqual(twice.facts["commitment:portfolio"]?.status, .open)
    }

    func testUnknownEnumAndOversizedResponseDoNotAcknowledgeInput() async throws {
        let unknown = Data(#"{"operations":[{"action":"execute_shell","kind":"goal","key":"x","sourceTurnID":1}]}"#.utf8)
        let cases: [(Data, FailureReason)] = [(unknown, .malformedOutput),
                                             (Data(repeating: 32, count: 65_537), .oversizedOutput)]
        for (bytes, reason) in cases {
            let worker = MemoryWorker(model: TestModel { _ in bytes })
            try await worker.append(turn(1))
            let outcome = await worker.processPending(at: epoch)
            XCTAssertEqual(outcome, .retryScheduled(at: epoch.addingTimeInterval(60), reason: reason))
            let state = await worker.currentSnapshot()
            XCTAssertEqual(state.acknowledgedThrough, 0)
        }
    }

    func testRetryBackoffCapsAndClockRollbackDoesNotFreezeWork() async {
        var retry = RetryState()
        var now = epoch
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            XCTAssertTrue(retry.canAttempt(at: now))
            retry.begin(at: now); retry.fail(at: now)
            let next = retry.nextAttemptAfter!
            delays.append(next.timeIntervalSince(now)); now = next
        }
        XCTAssertEqual(delays, [60, 120, 240, 480, 960, 1_800, 1_800, 1_800])
        XCTAssertTrue(retry.canAttempt(at: epoch.addingTimeInterval(-1)))
    }

    func testEmptyAndCoalescedTriggersDoNotSpendRequests() async throws {
        let model = BlockingModel()
        let worker = MemoryWorker(model: model)
        let empty = await worker.processPending(at: epoch)
        XCTAssertEqual(empty, .idle)
        try await worker.append(turn(1))
        let first = Task { await worker.processPending(at: epoch) }
        await model.waitUntilRequested()
        let coalesced = await worker.processPending(at: epoch)
        XCTAssertEqual(coalesced, .coalesced)
        await model.finish(try encoded([goal(1)]))
        _ = await first.value
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
    }

    func testNewTurnsArrivingDuringRequestRemainPending() async throws {
        let model = BlockingModel()
        let worker = MemoryWorker(model: model)
        try await worker.append(turn(1))
        let first = Task { await worker.processPending(at: epoch) }
        await model.waitUntilRequested()
        try await worker.append(turn(2, seconds: 1))
        await model.finish(try encoded([goal(1)]))
        _ = await first.value
        let state = await worker.currentSnapshot()
        let pending = await worker.pendingTurnCount()
        XCTAssertEqual(state.acknowledgedThrough, 1)
        XCTAssertEqual(pending, 1)
    }

    func testResetRejectsCompletionFromPreviousSession() async throws {
        let model = BlockingModel()
        let worker = MemoryWorker(model: model)
        try await worker.append(turn(1))
        let first = Task { await worker.processPending(at: epoch) }
        await model.waitUntilRequested()
        await worker.reset()
        try await worker.append(turn(1, seconds: 1))
        await model.finish(try encoded([goal(1, text: "Previous session")]))
        let outcome = await first.value
        XCTAssertEqual(outcome, .superseded)
        let state = await worker.currentSnapshot()
        let pending = await worker.pendingTurnCount()
        XCTAssertTrue(state.facts.isEmpty)
        XCTAssertEqual(state.acknowledgedThrough, 0)
        XCTAssertEqual(pending, 1)
    }

    func testDailyBudgetAndMinimumSpacingLimitProviderCalls() async throws {
        let model = TestModel { request in try encoded([goal(request.turns.last!.id)]) }
        let worker = MemoryWorker(model: model, dailyLimit: 1)
        try await worker.append(turn(1))
        _ = await worker.processPending(at: epoch)
        try await worker.append(turn(2, seconds: 1))
        let immediate = await worker.processPending(at: epoch.addingTimeInterval(1))
        XCTAssertEqual(immediate, .deferred(until: epoch.addingTimeInterval(60)))
        _ = await worker.processPending(at: epoch.addingTimeInterval(61))
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
        let pending = await worker.pendingTurnCount()
        XCTAssertEqual(pending, 1)
    }

    func testBudgetDoesNotRefillWhenClockMovesBackward() async {
        var budget = RequestBudget(dailyLimit: 1)
        XCTAssertTrue(budget.consume(at: epoch))
        XCTAssertFalse(budget.consume(at: epoch.addingTimeInterval(-86_400)))
        XCTAssertTrue(budget.consume(at: epoch.addingTimeInterval(86_400)))
    }

    func testNonIncreasingTurnIDsAndEmptyInputAreRejected() async throws {
        let model = TestModel { _ in try encoded([]) }
        let worker = MemoryWorker(model: model)
        try await worker.append(turn(1))
        do { try await worker.append(turn(1)); XCTFail("Duplicate input ID accepted") }
        catch TurnInputError.nonIncreasingID { }
        do {
            try await worker.append(.init(id: 2, role: .user, text: "  ", date: epoch))
            XCTFail("Blank input accepted")
        } catch TurnInputError.emptyText { }
    }
}
