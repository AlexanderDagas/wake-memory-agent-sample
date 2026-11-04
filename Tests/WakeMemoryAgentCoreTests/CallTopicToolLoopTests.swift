import Foundation
import XCTest
@testable import WakeMemoryAgentCore

/// Synthetic server frames exercise Wake's extracted tool router without a live account.
final class CallTopicToolLoopTests: XCTestCase {
    private func frame(id: String, name: String, arguments: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["toolCall": ["functionCalls": [
            ["id": id, "name": name, "args": arguments]
        ]]])
    }

    private func request(_ router: inout CallTopicRouter, id: String, name: String,
                         arguments: [String: Any]) throws -> CallTopicRouter.Request {
        try XCTUnwrap(router.requests(in: frame(id: id, name: name, arguments: arguments)).first)
    }

    private func respond(_ notebook: inout CallTopicNotebook, router: inout CallTopicRouter,
                         request: CallTopicRouter.Request, caller: String) throws -> [String: Any] {
        let payload = try notebook.payload(for: request, currentCaller: caller)
        XCTAssertNotNil(router.response(for: request, payload: payload))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    }

    private func finish(_ notebook: inout CallTopicNotebook, router: inout CallTopicRouter,
                        id: String = "finish", subject: String = "portfolio") throws -> [String: Any] {
        let proposal = try request(&router, id: id, name: CallTopicRouter.recordName,
                                  arguments: ["subject": subject, "state": "FINISHED"])
        return try respond(&notebook, router: &router, request: proposal,
                           caller: "That's everything about \(subject).")
    }

    private func choice(_ router: inout CallTopicRouter, id: String, subject: String,
                        comparisons: [[String: String]], invitation: String = "What are you learning next?") throws -> CallTopicRouter.Request {
        try request(&router, id: id, name: CallTopicRouter.chooseName, arguments: [
            "candidate_subject": subject, "invitation": invitation, "comparisons": comparisons
        ])
    }

    func testClosedSubjectIsRejectedAndAgentCanReviseItsChoice() throws {
        var notebook = CallTopicNotebook(), router = CallTopicRouter()
        let recorded = try finish(&notebook, router: &router)
        XCTAssertEqual(recorded["status"] as? String, "recorded")
        XCTAssertFalse(router.permitsModelOutput)

        // Even a model-supplied "different" comparison cannot override an exact closed label.
        let repeated = try choice(&router, id: "repeat", subject: "portfolio",
                                  comparisons: [["finished_topic_id": "t1", "relation": "different"]])
        let rejected = try respond(&notebook, router: &router, request: repeated,
                                   caller: "That's everything about portfolio.")
        XCTAssertEqual(rejected["status"] as? String, "candidate_is_finished")
        XCTAssertFalse(router.permitsModelOutput)

        let revised = try choice(&router, id: "revise", subject: "learning",
                                 comparisons: [["finished_topic_id": "t1", "relation": "different"]])
        let accepted = try respond(&notebook, router: &router, request: revised,
                                   caller: "That's everything about portfolio.")
        XCTAssertEqual(accepted["status"] as? String, "accepted")
        XCTAssertEqual(accepted["selected_opening"] as? String, "What are you learning next?")
        XCTAssertFalse(notebook.hasPendingChoice)
    }

    func testEveryClosedSubjectRequiresAKnownComparison() throws {
        for (comparisons, expected) in [
            ([], "missing_comparisons"),
            ([["finished_topic_id": "invented", "relation": "different"]], "unknown_comparison_ids")
        ] as [([[String: String]], String)] {
            var notebook = CallTopicNotebook(), router = CallTopicRouter()
            _ = try finish(&notebook, router: &router)
            let proposal = try choice(&router, id: "choice", subject: "learning", comparisons: comparisons)
            let result = try respond(&notebook, router: &router, request: proposal,
                                     caller: "That's everything about portfolio.")
            XCTAssertEqual(result["status"] as? String, expected)
            XCTAssertTrue(notebook.hasPendingChoice)
        }
    }

    func testFabricatedCallerEvidenceCannotCloseASubject() throws {
        var notebook = CallTopicNotebook(), router = CallTopicRouter()
        let proposal = try request(&router, id: "fabricated", name: CallTopicRouter.recordName,
                                  arguments: ["subject": "portfolio", "state": "FINISHED",
                                              "source_quote": "Please stop discussing the portfolio."])
        let result = try respond(&notebook, router: &router, request: proposal,
                                 caller: "I still have a question about the portfolio.")
        XCTAssertEqual(result["status"] as? String, "current_quote_not_found")
        XCTAssertEqual((result["finished_subjects"] as? [[String: String]])?.count, 0)
        XCTAssertFalse(notebook.hasPendingChoice)
    }

    func testRepeatedToolIDIsNotExecutedTwice() throws {
        var notebook = CallTopicNotebook(), router = CallTopicRouter()
        let data = try frame(id: "same-id", name: CallTopicRouter.recordName,
                             arguments: ["subject": "portfolio", "state": "FINISHED"])
        let proposal = try XCTUnwrap(router.requests(in: data).first)
        _ = try respond(&notebook, router: &router, request: proposal,
                        caller: "That's everything about portfolio.")
        XCTAssertTrue(router.requests(in: data).isEmpty)
        XCTAssertEqual(router.requestCount, 1)
    }

    func testCancelledAndPreviousSessionRequestsCannotReturnResults() throws {
        for resetSession in [false, true] {
            var notebook = CallTopicNotebook(), router = CallTopicRouter()
            let proposal = try request(&router, id: "pending", name: CallTopicRouter.recordName,
                                      arguments: ["subject": "portfolio", "state": "FINISHED"])
            let payload = try notebook.payload(for: proposal, currentCaller: "That's everything about portfolio.")
            if resetSession {
                router.invalidate()
            } else {
                _ = router.requests(in: Data(#"{"toolCallCancellation":{"ids":["pending"]}}"#.utf8))
            }
            XCTAssertFalse(router.isCurrent(proposal))
            XCTAssertNil(router.response(for: proposal, payload: payload))
        }
    }

    func testCoalescedOutputCannotAcknowledgeAToolResponseSentAfterIt() throws {
        var notebook = CallTopicNotebook(), router = CallTopicRouter()
        _ = try finish(&notebook, router: &router)
        let proposal = try choice(&router, id: "choose", subject: "learning",
                                 comparisons: [["finished_topic_id": "t1", "relation": "different"]])
        _ = try respond(&notebook, router: &router, request: proposal,
                        caller: "That's everything about portfolio.")
        router.noteServerCompletion()
        XCTAssertTrue(router.blocksTurnCompletion)
        XCTAssertFalse(router.permitsModelOutput)

        _ = router.requests(in: Data(#"{"serverContent":{"turnComplete":true}}"#.utf8))
        router.noteServerCompletion()
        XCTAssertFalse(router.blocksTurnCompletion)
        XCTAssertTrue(router.permitsModelOutput)
    }

    func testCallerChoiceOverridesAConflictingModelSuccessorWhenEnabled() throws {
        // This is an opt-in path retained from Wake; the default path is tested above.
        var notebook = CallTopicNotebook(respectCallerTopicChoice: true), router = CallTopicRouter()
        let proposal = try request(&router, id: "transition", name: CallTopicRouter.transitionName,
                                  arguments: ["finished_subject": "portfolio", "candidate_subject": "exercise",
                                              "invitation": "How is your exercise plan?",
                                              "relation_to_finished": "different", "comparisons": []])
        let result = try respond(&notebook, router: &router, request: proposal,
                                 caller: "Can we talk about learning?")
        XCTAssertEqual(result["status"] as? String, "accepted")
        XCTAssertEqual(result["caller_selected_subject"] as? String, "learning")
        XCTAssertNil(result["selected_opening"])
        XCTAssertFalse(notebook.hasPendingChoice)
    }

    func testCancellationRollsBackOnlyTheUncommittedClosure() throws {
        var notebook = CallTopicNotebook(), router = CallTopicRouter()
        _ = try finish(&notebook, router: &router)
        notebook.cancelPendingChoice()
        router.invalidate()
        let later = try finish(&notebook, router: &router, id: "later", subject: "learning")
        XCTAssertEqual((later["finished_subjects"] as? [[String: String]])?.map { $0["subject"] }, ["learning"])
    }

    func testMalformedChoicesCannotBecomeAcceptedActions() throws {
        for (subject, invitation, comparisons) in [
            ("learning", "What would you like to talk about?", [["finished_topic_id": "t1", "relation": "different"]]),
            (String(repeating: "x", count: 97), "What are you learning next?", [["finished_topic_id": "t1", "relation": "different"]]),
            ("learning", "What are you learning next?", [["finished_topic_id": "t1", "relation": "different"], ["finished_topic_id": "t1", "relation": "same"]])
        ] {
            var notebook = CallTopicNotebook(), router = CallTopicRouter()
            _ = try finish(&notebook, router: &router)
            let proposal = try choice(&router, id: "malformed", subject: subject,
                                      comparisons: comparisons, invitation: invitation)
            let result = try respond(&notebook, router: &router, request: proposal,
                                     caller: "That's everything about portfolio.")
            XCTAssertEqual(result["status"] as? String, "invalid_arguments")
            XCTAssertNil(result["selected_opening"])
            XCTAssertTrue(router.blocksTurnCompletion)
        }
    }

    func testTopicIDsCannotBeBorrowedToOverwriteAnotherSubject() throws {
        var notebook = CallTopicNotebook(), router = CallTopicRouter()
        _ = try finish(&notebook, router: &router)
        let proposal = try request(&router, id: "conflict", name: CallTopicRouter.recordName,
                                  arguments: ["topic_id": "t1", "subject": "learning", "state": "REOPENED"])
        let result = try respond(&notebook, router: &router, request: proposal,
                                 caller: "Can we talk about learning?")
        XCTAssertEqual(result["status"] as? String, "topic_id_label_conflict")
        XCTAssertEqual((result["finished_subjects"] as? [[String: String]])?.map { $0["subject"] }, ["portfolio"])
    }
}
