import Foundation

public enum TurnInputError: Error { case nonIncreasingID, emptyText, oversizedTurn }

public enum FailureReason: Sendable, Equatable {
    case malformedOutput, invalidOperations, oversizedOutput, providerFailure
}

private enum ModelOutputError: Error { case oversized }

public enum WorkOutcome: Sendable, Equatable {
    case idle
    case coalesced
    case deferred(until: Date)
    case applied(proposedOperationCount: Int, through: Int)
    case retryScheduled(at: Date, reason: FailureReason)
    case superseded
}

/// Isolates concurrency and state mutation from the model/provider implementation.
public actor MemoryWorker {
    private let model: any MemoryModel
    private var snapshot: MemorySnapshot
    private var pending: [SourceTurn] = []
    private var lastAcceptedID: Int
    private var runningGeneration: Int?
    private var generation = 0
    private var retry = RetryState()
    private var budget: RequestBudget

    public init(model: any MemoryModel, initial: MemorySnapshot = .init(), dailyLimit: Int = 4) {
        precondition(dailyLimit > 0)
        self.model = model; self.snapshot = initial
        self.lastAcceptedID = initial.acknowledgedThrough
        self.budget = RequestBudget(dailyLimit: dailyLimit)
    }

    public func append(_ turn: SourceTurn) throws {
        guard turn.id > lastAcceptedID else { throw TurnInputError.nonIncreasingID }
        guard !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TurnInputError.emptyText
        }
        guard turn.text.utf8.count <= 16_000 else { throw TurnInputError.oversizedTurn }
        pending.append(turn)
        lastAcceptedID = turn.id
    }

    public func currentSnapshot() -> MemorySnapshot { snapshot }
    public func pendingTurnCount() -> Int { pending.count }

    public func processPending(at now: Date) async -> WorkOutcome {
        guard !pending.isEmpty else { return .idle }
        guard runningGeneration == nil else { return .coalesced }
        guard retry.canAttempt(at: now) else { return .deferred(until: retry.nextAttemptAfter!) }
        guard budget.consume(at: now) else {
            return .deferred(until: budget.nextRefill(at: now))
        }
        retry.begin(at: now)
        let requestGeneration = generation
        runningGeneration = requestGeneration
        // Bound the input. Arrivals while the model is suspended remain pending.
        let batch = Array(pending.prefix(50))
        let watermark = batch.last!.id
        let request = MemoryRequest(snapshot: snapshot, turns: batch)
        defer {
            if runningGeneration == requestGeneration { runningGeneration = nil }
        }

        do {
            let bytes = try await model.proposeUpdate(for: request)
            guard generation == requestGeneration else { return .superseded }
            guard bytes.count <= 65_536 else { throw ModelOutputError.oversized }
            let proposed = try JSONDecoder().decode(ProposedBatch.self, from: bytes)
            var candidate = try MemoryValidator.applying(proposed, to: snapshot, sourceTurns: batch)
            // The checkpoint advances only after the whole response validates.
            candidate.acknowledgedThrough = watermark
            snapshot = candidate
            pending.removeAll { $0.id <= watermark }
            retry.succeed()
            return .applied(proposedOperationCount: proposed.operations.count, through: watermark)
        } catch {
            guard generation == requestGeneration else { return .superseded }
            retry.fail(at: now)
            // Failed input is neither removed nor acknowledged.
            let reason: FailureReason
            switch error {
            case is DecodingError: reason = .malformedOutput
            case is MemoryValidationError: reason = .invalidOperations
            case is ModelOutputError: reason = .oversizedOutput
            default: reason = .providerFailure
            }
            return .retryScheduled(at: retry.nextAttemptAfter!, reason: reason)
        }
    }

    /// Account/session reset invalidates an outstanding response before clearing state.
    /// An old completion must not mutate the new session or clear its in-flight marker.
    public func reset() {
        generation += 1
        runningGeneration = nil
        pending.removeAll()
        snapshot = MemorySnapshot()
        lastAcceptedID = 0
        retry = RetryState()
    }
}
