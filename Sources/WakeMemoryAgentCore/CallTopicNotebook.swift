// Extracted from Wake/Models/CallTopicNotebook.swift.
// Swift 6 package adaptation: tool declarations are computed to avoid shared non-Sendable state.

import Foundation

/// Keeps a bounded set of recent call topics and validates boundary choices.
struct CallTopicNotebook {
    private let includeRecentCallerEvidence: Bool
    private let protectPersonalContinuations: Bool
    private let respectCallerTopicChoice: Bool
    private var recentCallerEvidence: [String] = []
    init(includeRecentCallerEvidence: Bool = false, protectPersonalContinuations: Bool = false,
         respectCallerTopicChoice: Bool = false) {
        self.includeRecentCallerEvidence = includeRecentCallerEvidence
        self.protectPersonalContinuations = protectPersonalContinuations
        self.respectCallerTopicChoice = respectCallerTopicChoice
    }
    private struct Topic { let id: String; let subject: String; var closed: Bool; var closureQuote: String = ""; var lastOpening: String = "" }
    private var topics: [Topic] = []
    private var nextTopicID = 0

    private mutating func addTopic(_ subject: String) -> Topic {
        if topics.count >= 64 {
            let removable = topics.firstIndex { $0.closed && $0.id != pendingClosure?.id }
                ?? topics.firstIndex { $0.id != pendingClosure?.id } ?? 0
            topics.remove(at: removable)
        }
        nextTopicID += 1
        let topic = Topic(id: "t\(nextTopicID)", subject: subject, closed: false)
        topics.append(topic)
        return topic
    }
    private var awaitingChoice = false
    var hasPendingChoice: Bool { awaitingChoice }
    struct ContinuationReview: Sendable {
        let selectedText: String?
        let failedChecks: [String]
        let similarityAvailable: Bool
        var hasSpecificResponse: Bool {
            guard failedChecks.isEmpty, let text = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return false }
            return !CallTopicNotebook.isEmptyContinuation(text) && !CallTopicRouter.handsBackAgenda(text)
        }
        func fulfilsContinuation(for caller: String) -> Bool {
            hasSpecificResponse && (CallTopicNotebook.callerRequestedAnAnswer(caller) ||
                CallTopicNotebook.hasInvitation(selectedText ?? ""))
        }
    }
    private struct PendingContinuation {
        let id: String
        let caller: String
        var attempts: Int = 0
    }
    private var pendingContinuation: PendingContinuation?
    private var continuationApproval: (id: String, caller: String, draft: String, selected: String)?
    var pendingContinuationID: String? { pendingContinuation?.id }
    var hasPendingContinuation: Bool { pendingContinuation != nil }
    var continuationCaller: String? { pendingContinuation?.caller ?? continuationApproval?.caller }
    private var pendingClosure: (id: String, wasClosed: Bool, previousQuote: String)?
    private(set) var lastCompletedCaller = ""
    mutating func append(role: String, text: String) {
        guard role == "user", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 16_000 else { return }
        lastCompletedCaller = text
        if includeRecentCallerEvidence {
            recentCallerEvidence.append(text)
            recentCallerEvidence = Array(recentCallerEvidence.suffix(4))
        }
    }
    mutating func cancelPendingChoice(preserveContinuation: Bool = false) {
        if let pendingClosure, let index = topics.firstIndex(where: { $0.id == pendingClosure.id }) {
            topics[index].closed = pendingClosure.wasClosed
            topics[index].closureQuote = pendingClosure.previousQuote
        }
        pendingClosure = nil
        awaitingChoice = false
        if !preserveContinuation { pendingContinuation = nil; continuationApproval = nil }
    }
    mutating func commitCallerSwitch() {
        if !awaitingChoice { pendingClosure = nil }
    }
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    private static func sameLabel(_ lhs: String, _ rhs: String) -> Bool {
        if folded(lhs) == folded(rhs) { return true }
        let ignored: Set<String> = ["a", "an", "the", "to", "of", "for", "in", "on", "with", "and", "my", "your", "our", "their"]
        func terms(_ text: String) -> Set<String> {
            Set(folded(text).split(separator: " ").map(String.init).filter { !ignored.contains($0) })
        }
        let left = terms(lhs), right = terms(rhs)
        // Match only two-word category/entity labels ("trip to Galway" and
        // "Galway trip"). Do not equate reordered sentences: reversing who
        // criticized whom can change the meaning even with identical words.
        let categoryNouns: Set<String> = ["trip", "holiday", "vacation", "visit", "project", "game"]
        return left.count == 2 && left == right && !left.isDisjoint(with: categoryNouns)
    }
    private static func sameCallerSubject(_ label: String, _ choice: String) -> Bool {
        func bare(_ value: String) -> String {
            folded(value).replacingOccurrences(of: #"^(?:my|your|the) "#, with: "", options: .regularExpression)
        }
        // The model's "your family" and the caller's "my family" refer to
        // the caller. Keep third-person possessives and sentence roles intact.
        return sameLabel(bare(label), bare(choice))
    }
    private static func excerpt(_ text: String) -> String {
        var result = ""
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let next = result.isEmpty ? String(word) : result + " " + word
            if next.utf8.count > 160 { break }; result = next
        }
        return result
    }
    func hasSource(for request: CallTopicRouter.Request, currentCaller: String) -> Bool {
        if request.state == "CHOOSE" { return request.valid }
        guard request.valid, !currentCaller.isEmpty, currentCaller.utf8.count <= 16_000 else { return false }
        // The app owns the current transcript. New tool calls needn't reproduce
        // speech recognition verbatim; legacy calls that supply a quote still
        // have to match it, so fabricated evidence is never stored.
        if request.quote.isEmpty { return true }
        let quote = Self.folded(request.quote), actual = Self.folded(currentCaller)
        return !quote.isEmpty && (quote.count >= 6 || quote == actual) && (" " + actual + " ").contains(" " + quote + " ")
    }
    func canReviewContinuation(_ request: CallTopicRouter.Request, currentCaller: String) -> Bool {
        request.valid && request.state == "CONTINUE" &&
            pendingContinuation?.id == request.continuationID &&
            pendingContinuation?.caller == currentCaller
    }
    mutating func payload(for request: CallTopicRouter.Request, currentCaller: String,
                          currentCallerAlreadyAnswered: Bool = false,
                          currentCallerIsActive: Bool = true,
                          continuationReview: ContinuationReview? = nil) throws -> Data {
        if respectCallerTopicChoice, currentCallerIsActive, request.valid,
           ["FINISHED", "TRANSITION", "CHOOSE"].contains(request.state),
           hasSource(for: request, currentCaller: currentCaller),
           let choice = CallTopicCallerChoice.subject(in: currentCaller) {
            // The caller already chose the next focus. A mistaken FINISHED
            // state must not require the model to choose it again, or authorize
            // the different successor proposed by an atomic transition.
            let state = request.state != "CHOOSE" && Self.sameCallerSubject(request.subject, choice)
                ? "REOPENED" : "CALLER_SWITCH"
            var result: [String: Any]
            if request.state == "CHOOSE" {
                // A redundant model choice cannot replace an explicit caller
                // choice, even when its proposed label or comparisons differ.
                awaitingChoice = false
                pendingContinuation = nil
                continuationApproval = nil
                result = ["kind": "model_call_notes", "status": "accepted", "awaiting_next_choice": false,
                          "finished_subjects": topics.filter { $0.closed }.map {
                              ["id": $0.id, "subject": $0.subject, "caller_quote": $0.closureQuote]
                          }]
                if includeRecentCallerEvidence, currentCaller.utf8.count <= 1_200 {
                    result["current_call_user_evidence"] = [currentCaller]
                }
            } else {
                let corrected = request.replacing(subject: request.subject, state: state, comparisons: [:])
                let data = try payload(for: corrected, currentCaller: currentCaller,
                                       currentCallerAlreadyAnswered: currentCallerAlreadyAnswered,
                                       currentCallerIsActive: currentCallerIsActive)
                result = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            if result["status"] as? String == "accepted" {
                if let index = topics.firstIndex(where: { Self.sameCallerSubject($0.subject, choice) }) {
                    topics[index].closed = false
                    topics[index].closureQuote = ""
                    result["caller_reopened_topic_id"] = topics[index].id
                    result["selected_topic"] = ["id": topics[index].id, "subject": topics[index].subject]
                    result["finished_subjects"] = topics.filter { $0.closed }.map {
                        ["id": $0.id, "subject": $0.subject, "caller_quote": $0.closureQuote]
                    }
                }
                result["caller_selected_subject"] = choice
                result["applied_boundary_state"] = state
                result["next_action"] = "The caller chose the focus: \(choice). Follow their current request directly. No choose_next_topic call is needed; do not introduce a different subject."
            }
            return try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
        }
        let callerExpression = protectPersonalContinuations && CallTopicContinuationCue.matches(currentCaller)
        let continueCurrent = !currentCallerAlreadyAnswered &&
            callerExpression &&
            ["FINISHED", "TRANSITION", "CHOOSE"].contains(request.state) &&
            !CallTopicBoundaryCue.matches(currentCaller)
        if request.valid, request.state == "TRANSITION", !continueCurrent {
            let previousClosedIDs = Set(topics.filter { $0.closed }.map(\.id))
            let boundary = request.replacing(subject: request.subject, state: "FINISHED", comparisons: [:])
            let recorded = try payload(for: boundary, currentCaller: currentCaller,
                                       currentCallerAlreadyAnswered: currentCallerAlreadyAnswered,
                                       currentCallerIsActive: currentCallerIsActive)
            guard let result = try JSONSerialization.jsonObject(with: recorded) as? [String: Any],
                  result["status"] as? String == "recorded",
                  let closedID = result["recorded_topic_id"] as? String else { return recorded }
            let closedIDs = Set(topics.filter { $0.closed }.map(\.id))
            // Recording at capacity can evict an old known ID. Unknown IDs are
            // still rejected; only a note just evicted by this operation is skipped.
            var comparisons = request.comparisons.filter { !previousClosedIDs.contains($0.key) || closedIDs.contains($0.key) }
            comparisons[closedID] = request.finishedRelation == "same" || comparisons[closedID] == "same" ? "same" : "different"
            let choice = request.replacing(subject: request.nextSubject, state: "CHOOSE", comparisons: comparisons)
            let chosen = try payload(for: choice, currentCaller: currentCaller,
                                     currentCallerAlreadyAnswered: currentCallerAlreadyAnswered,
                                     currentCallerIsActive: currentCallerIsActive)
            var response = (try JSONSerialization.jsonObject(with: chosen) as? [String: Any]) ?? [:]
            response["recorded_topic_id"] = closedID
            return try JSONSerialization.data(withJSONObject: response, options: .sortedKeys)
        }
        var status = "invalid_arguments"
        var result: [String: Any] = [:]
        var selected: Topic?
        if request.valid {
            if request.state == "CONTINUE" {
                if let approved = continuationApproval, approved.id == request.continuationID,
                   approved.caller == currentCaller, approved.draft == request.opening {
                    status = "accepted"
                    result["selected_response"] = approved.selected
                } else if !canReviewContinuation(request, currentCaller: currentCaller) {
                    if pendingContinuation?.caller != currentCaller { pendingContinuation = nil }
                    status = "continuation_not_requested"
                    result["next_action"] = "That continuation request has expired or belongs to different caller words. Never reuse its approval. Follow the current caller; do not invent a continuation_id."
                } else if let continuationReview, var pending = pendingContinuation {
                    pending.attempts += 1
                    var issues = continuationReview.failedChecks
                    let text = continuationReview.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let text, Self.isEmptyContinuation(text) || CallTopicRouter.handsBackAgenda(text) {
                        issues.append("no_specific_continuation")
                    }
                    if issues.isEmpty, !continuationReview.fulfilsContinuation(for: currentCaller) {
                        issues.append("no_specific_invitation")
                    }
                    if issues.isEmpty, let text, !text.isEmpty, request.opening.contains(text) {
                        status = "accepted"
                        result["selected_response"] = text
                        continuationApproval = (pending.id, currentCaller, request.opening, text)
                        pendingContinuation = nil
                    } else {
                        if issues.isEmpty { issues = ["no_exact_approved_text"] }
                        if pending.attempts >= 2 {
                            status = "not_recorded"
                            result["continuation_review_failed"] = true
                            result["next_action"] = "No continuation was approved. Stop retrying tools for this exchange. Respond directly to the latest caller on the current subject without introducing another subject."
                            pendingContinuation = nil
                        } else {
                            status = "revise_continuation"
                            result["continuation_id"] = pending.id
                            result["next_action"] = "Revise once using continue_current_topic. Ask one specific question about the caller's unfinished point, or invite them to describe a specific part. If they asked you a question, answer it directly instead. No stand-alone appraisal or agenda handoff."
                            pendingContinuation = pending
                        }
                        result["failed_checks"] = issues
                    }
                    result["style_signal_available"] = continuationReview.similarityAvailable
                } else {
                    status = "continuation_review_required"
                }
            } else if continueCurrent, hasSource(for: request, currentCaller: currentCaller) {
                // This is a declined boundary proposal, not a saved fact or a
                // new subject. Undo only an uncommitted closure, if any.
                let previous = pendingContinuation?.caller == currentCaller ? pendingContinuation : nil
                cancelPendingChoice()
                pendingContinuation = previous ?? PendingContinuation(id: UUID().uuidString, caller: currentCaller)
                status = "continuation_required"
                result["continuing_current_subject"] = true
                result["continuation_basis"] = "caller_expression"
                result["continuation_id"] = pendingContinuation!.id
                result["next_action"] = "No subject was closed: the caller added an unfinished personal point. Call continue_current_topic with this continuation_id. Ask one specific question about that point, or invite them to describe a specific part. If they asked you a question, answer it directly instead. A stand-alone appraisal does not continue the exchange."
            } else if request.state == "CHOOSE" {
                let closed = topics.filter { $0.closed }
                let missing = closed.filter { request.comparisons[$0.id] == nil }.map { $0.id }
                let unknown = request.comparisons.keys.filter { id in !closed.contains { $0.id == id } }
                let matches = closed.filter { request.comparisons[$0.id] == "same" || Self.sameLabel($0.subject, request.subject) }.map { $0.id }
                result["candidate_subject"] = request.subject
                if !awaitingChoice { status = "boundary_record_required" }
                else if !unknown.isEmpty { status = "unknown_comparison_ids"; result["unknown_ids"] = unknown.sorted() }
                else if !missing.isEmpty { status = "missing_comparisons"; result["missing_finished_topic_ids"] = missing }
                else if !matches.isEmpty { status = "candidate_is_finished"; result["matched_finished_topic_ids"] = matches }
                else if topics.contains(where: { !$0.lastOpening.isEmpty && Self.folded($0.lastOpening) == Self.folded(request.opening) }) { status = "opening_already_used" }
                else if let existing = topics.first(where: { Self.sameLabel($0.subject, request.subject) && !$0.closed }) {
                    selected = existing; status = "accepted"; awaitingChoice = false; pendingClosure = nil
                } else {
                    selected = addTopic(request.subject); status = "accepted"; awaitingChoice = false; pendingClosure = nil
                }
            } else if !hasSource(for: request, currentCaller: currentCaller) {
                status = "current_quote_not_found"; result["current_caller_excerpt"] = Self.excerpt(currentCaller)
                result["next_action"] = "Use exact words from current_caller_excerpt, which is the latest caller turn, not an earlier answer. Record the OLD subject that is ending. If the caller has supplied a new subject, use CALLER_SWITCH and follow it directly; no choose_next_topic call is needed."
            } else {
                let byID = topics.firstIndex { $0.id == request.topicID }
                let byLabel = topics.firstIndex { Self.sameLabel($0.subject, request.subject) }
                if !request.topicID.isEmpty && byID == nil { status = "unknown_topic_id" }
                else if let byID, !Self.sameLabel(topics[byID].subject, request.subject) {
                    status = "topic_id_label_conflict"
                    result["existing_topic"] = ["id": topics[byID].id, "subject": topics[byID].subject]
                }
                else {
                    var index = byID ?? byLabel
                    if index == nil {
                        let topic = addTopic(request.subject)
                        index = topics.firstIndex { $0.id == topic.id }
                    }
                    if let index {
                        let id = topics[index].id
                        if awaitingChoice && (request.state != "FINISHED" || pendingClosure?.id != id) {
                            cancelPendingChoice()
                        }
                        if ["FINISHED", "CALLER_SWITCH"].contains(request.state), !awaitingChoice, pendingClosure == nil {
                            pendingClosure = (id: id, wasClosed: topics[index].closed, previousQuote: topics[index].closureQuote)
                        }
                        topics[index].closed = request.state != "REOPENED"
                        topics[index].closureQuote = request.state != "REOPENED"
                            ? (request.quote.isEmpty ? Self.excerpt(currentCaller) : request.quote) : ""
                        result["recorded_topic_id"] = id
                        if request.state == "FINISHED" { status = "recorded"; awaitingChoice = true }
                        else if request.state == "CALLER_SWITCH" { status = "accepted"; awaitingChoice = false }
                        else { status = "accepted"; awaitingChoice = false; pendingClosure = nil; selected = topics[index] }
                    } else { status = "capacity_reached" }
                }
            }
        }
        result["kind"] = "model_call_notes"; result["status"] = status
        result["finished_subjects"] = topics.filter { $0.closed }.map { ["id": $0.id, "subject": $0.subject, "caller_quote": $0.closureQuote] }
        result["awaiting_next_choice"] = awaitingChoice
        if includeRecentCallerEvidence {
            // Only emitted as part of an existing boundary-tool result. Keep
            // whole actual caller turns; truncation could remove a correction.
            var candidates = recentCallerEvidence
            if !currentCaller.isEmpty, candidates.last != currentCaller { candidates.append(currentCaller) }
            var evidence: [String] = []
            var remaining = 1_200
            for text in candidates.reversed() where evidence.count < 4 {
                guard text.utf8.count <= remaining else { continue }
                evidence.append(text)
                remaining -= text.utf8.count
            }
            if !evidence.isEmpty { result["current_call_user_evidence"] = Array(evidence.reversed()) }
        }
        if !request.argumentIssues.isEmpty { result["invalid_fields"] = request.argumentIssues }
        if let selected {
            result["selected_topic"] = ["id": selected.id, "subject": selected.subject]
            if request.state == "CHOOSE" {
                result["selected_opening"] = request.opening
                if let index = topics.firstIndex(where: { $0.id == selected.id }) { topics[index].lastOpening = request.opening }
            }
        }
        return try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
    }
    private static func isEmptyContinuation(_ text: String) -> Bool {
        let value = folded(text)
        if ["okay", "ok", "right", "all right", "good", "great", "yes", "no", "mhm",
                "go on", "i m listening", "i am listening", "tell me more", "how do you feel",
                "how are you feeling", "how are you feeling about it"].contains(value) { return true }
        // A stand-alone good-time wish isn't an answer to an unfinished
        // personal point. Keep this anchored so a useful follow-up survives.
        let wish = #"^(?:(?:i )?hope you(?: both| two)? have (?:a |an )?(?:really |very )?(?:good|great|lovely|nice|wonderful|relaxing|fun) (?:time|day|evening|weekend|trip|holiday|catch up|meeting|coffee)|enjoy (?:your |the )?(?:trip|holiday|weekend|coffee|time away))(?: on (?:sunday|saturday|monday|tuesday|wednesday|thursday|friday))?$"#
        return value.range(of: wish, options: .regularExpression) != nil
    }
    private static func callerRequestedAnAnswer(_ text: String) -> Bool {
        text.contains("?") || folded(text).range(of:
            #"\b(?:(?:can|could|would) you|(?:please )?(?:give|show) me (?:an? )?example|explain (?:it|that|this)|what do you mean|how (?:do|would|can|should) i)\b"#,
            options: .regularExpression) != nil
    }
    private static func hasInvitation(_ text: String) -> Bool {
        // Validate the spoken function, not particular praise synonyms. This
        // applies only after a premature boundary, never to ordinary replies.
        let unquoted = text.replacingOccurrences(of: #"["“][^"”]*["”]"#, with: "", options: .regularExpression)
        if unquoted.range(of: #"\b(?:what|how|when|where|who|which|why|do|does|did|is|are|have|has|would|could|can)\b[^.!?\n]{3,}\?"#,
                          options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return folded(unquoted).range(of:
            #"\b(?:(?:tell|show) me (?:about|what|how|when)|(?:talk|walk) me through|say (?:a little )?more about) [a-z0-9]"#,
            options: .regularExpression) != nil
    }
}

/// Recognizes a direct, named conversational choice, using only the actual
/// caller transcript at a proposed boundary. Ambiguous, quoted, deferred and
/// generic requests retain the ordinary model-managed boundary path.
enum CallTopicCallerChoice {
    static func subject(in source: String) -> String? {
        guard !source.isEmpty, source.utf8.count <= 16_000 else { return nil }
        let unquoted = source.replacingOccurrences(of: #"["“][^"”]*["”]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\w)[‘'].*?[’'](?!\w)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "’", with: "'")
        // A later retraction or a demonstration cannot authorize a switch.
        let veto = #"\b(?:imagine|suppose|pretend|hypothetically|for example|in (?:a|the) (?:script|role.?play)|(?:he|she|they|i) (?:said|asked|was like)|never mind|nevermind|(?:actually|wait|hold on)[, ]+(?:no|not)|changed my mind|forget (?:it|that request)|not (?:now|yet|tonight|today|right now|for now|until)|another time|next time|goodbye|hang up|end the call|wrap up|stay (?:on|with)|keep (?:talking|discussing)|don't (?:switch|change))\b"#
        guard unquoted.range(of: veto, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        guard unquoted.range(of: #"\b(?:go|get) back to (?:bed|sleep)\b|\b(?:let's|let us) (?:go|get) back to work\b"#,
                             options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        let action = #"(?:(?:talk|chat|speak) about|discuss|(?:go|get|come) back to|return to|switch to|focus on)"#
        let discussion = #"(?:(?:talk|chat|speak) about|discuss|focus on)"#
        let patterns = [
            #"^(?:can|could|shall) we (?:please )?"# + action + #" (.+)$"#,
            #"^(?:let's|let us) (?:please )?"# + action + #" (.+)$"#,
            #"^i (?:want|would like) to "# + discussion + #" (.+)$"#,
            #"^i'd like to "# + discussion + #" (.+)$"#
        ]
        var choices: [String] = []
        for clause in unquoted.components(separatedBy: CharacterSet(charactersIn: ".!?;\n")) {
            let text = clause.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^(?:(?:okay|ok|right|all right|alright|well|so|actually)[, ]+)+"#,
                                      with: "", options: [.regularExpression, .caseInsensitive])
            for pattern in patterns {
                let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                let string = text as NSString
                guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: string.length)) else { continue }
                let target = string.substring(with: match.range(at: 1))
                    .replacingOccurrences(of: #",? please$"#, with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let ambiguous = #"\b(?:but|though|instead|maybe|perhaps|or|if|whether)\b|^(?:something|anything|nothing|everything|another|a different|the other|it|this|that|what|how|why|when|where|who|dr|mr|mrs)(?:\b|$)|\b(?:later|tomorrow|tonight|next week|next month)$"#
                guard target.utf8.count <= 96, target.count >= 3,
                      target.range(of: ambiguous, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
                choices.append(target)
                break
            }
        }
        return choices.count == 1 ? choices[0] : nil
    }
}

struct CallTopicRouter {
    static let recordName = "record_topic_boundary"
    static let chooseName = "choose_next_topic"
    static let transitionName = "finish_and_choose_topic"
    static let continuationName = "continue_current_topic"
    static var declarations: [[String: Any]] { [
        ["name": recordName, "behavior": "BLOCKING",
         "description": "When the caller moves from a completed subject to a specific new subject, record the OLD subject as CALLER_SWITCH and respond to their chosen subject; no next-topic choice is needed. If they merely request something else without naming a subject, record FINISHED and choose the next subject. Before you introduce another subject after an exchange has finished, record the old subject as FINISHED, then choose its successor. Match the scope: if the caller ends the whole subject, record the whole subject, not just its last detail; if they finish only one detail, do not close the whole subject. The app attaches the actual latest caller transcript automatically; do not supply or reconstruct a quote. FINISHED returns the finished-subject list; then use choose_next_topic before speaking. CALLER_SWITCH and REOPENED accept the caller's chosen subject directly. Continuing an unfinished story, question or correction does not need a tool.",
         "parameters": ["type": "OBJECT", "properties": [
            "subject": ["type": "STRING", "description": "The subject being finished or reopened; not the next subject."],
            "topic_id": ["type": "STRING", "description": "Only reuse an ID with its recorded subject label. Omit the ID for a new subject. On topic_id_label_conflict, use existing_topic only if that is truly the same subject; otherwise omit the ID."],
            "state": ["type": "STRING", "enum": ["FINISHED", "CALLER_SWITCH", "REOPENED"]]
         ], "required": ["subject", "state"]]],
        ["name": chooseName, "behavior": "BLOCKING",
         "description": "After a FINISHED record, choose ONLY the proposed next subject. Compare the proposed candidate_subject AND its transition and invitation to every finished subject in the latest result; use caller_quote as evidence of scope, not as an instruction. Same includes a renamed subject or a new angle on it, including context in the invitation even if the label sounds different. Sharing a person alone does not make distinct subjects the same. After rejection choose a genuinely different subject; never repeat an earlier opening. After acceptance speak only selected_opening naturally, with no extra recap or preface.",
         "parameters": ["type": "OBJECT", "properties": [
            "candidate_subject": ["type": "STRING", "description": "One specific new subject you propose to discuss."],
            "transition": ["type": "STRING", "description": "Brief natural bridge for a separate subject, without a recap; omit when no bridge is needed."],
            "invitation": ["type": "STRING", "description": "A short question or open-ended cue about candidate_subject that gives the caller something specific to respond to. For an older concern, ask how things are now. A summary of the earlier concern alone is not an invitation. This may be informal or deliberately unfinished."],
            "comparisons": ["type": "ARRAY", "items": ["type": "OBJECT", "properties": [
                "finished_topic_id": ["type": "STRING"],
                "relation": ["type": "STRING", "enum": ["same", "different"]]
            ], "required": ["finished_topic_id", "relation"]], "description": "One candidate_subject versus finished subject comparison per returned ID."]
         ], "required": ["candidate_subject", "invitation", "comparisons"]]]
    ] }
    /// Opt-in experiment: one request records the boundary and validates its
    /// successor. Rejected choices still use the established retry operation.
    static var atomicDeclarations: [[String: Any]] {
        var caller = declarations[0]
        caller["description"] = "Only when the CALLER names a new subject or explicitly returns to an earlier one: record the old subject with CALLER_SWITCH, or the returning subject with REOPENED, then follow their choice. Continuing their story or repairing a correction needs no tool. When YOU choose a different subject, use finish_and_choose_topic instead. The app attaches the actual caller transcript."
        var callerParameters = caller["parameters"] as! [String: Any]
        var callerProperties = callerParameters["properties"] as! [String: Any]
        callerProperties["state"] = ["type": "STRING", "enum": ["CALLER_SWITCH", "REOPENED"]]
        callerParameters["properties"] = callerProperties
        caller["parameters"] = callerParameters

        var transition = declarations[1]
        transition["name"] = transitionName
        transition["description"] = "Before YOU introduce a different subject after an exchange finishes, record what is finished AND propose its successor in this one request. The app checks the invitation against finished subjects. Do not close an unfinished story or correction. Match the caller's scope. Compare your candidate with finished_subject using relation_to_finished, and with all earlier returned finished IDs using comparisons. If there are none, comparisons is empty. If accepted, speak only selected_opening naturally. If rejected, keep the recorded boundary and revise the candidate using choose_next_topic. A caller-chosen subject uses record_topic_boundary instead."
        var parameters = transition["parameters"] as! [String: Any]
        var properties = parameters["properties"] as! [String: Any]
        properties["finished_subject"] = ["type": "STRING", "description": "The old subject that is ending, at the caller's intended scope."]
        properties["topic_id"] = ["type": "STRING", "description": "Optional existing ID of finished_subject; never borrow another subject's ID."]
        properties["relation_to_finished"] = ["type": "STRING", "enum": ["same", "different"], "description": "Does the candidate and its invitation return to finished_subject, including a new angle on it?"]
        parameters["properties"] = properties
        parameters["required"] = ["finished_subject", "candidate_subject", "invitation", "relation_to_finished", "comparisons"]
        transition["parameters"] = parameters
        return [caller, transition, declarations[1]]
    }
    /// Experimental check inside an already proposed topic boundary. Ordinary
    /// replies do not call this tool and receive no extra app instructions.
    static func toolDeclarations(atomic: Bool, checkContinuation: Bool) -> [[String: Any]] {
        let base = atomic ? atomicDeclarations : declarations
        guard checkContinuation else { return base }
        return base + [["name": continuationName, "behavior": "BLOCKING",
            "description": "Only after a topic-boundary result requests a continuation. Use its continuation_id. Invite the caller to expand on a specific part of their unfinished point with one question or concrete invitation. If they asked a question, answer it directly instead. Do not change subjects or merely praise/recap. Wait for acceptance, then speak only selected_response. One revision is allowed. Never use this for ordinary turns.",
            "parameters": ["type": "OBJECT", "properties": [
                "continuation_id": ["type": "STRING"],
                "response": ["type": "STRING", "description": "Exact proposed words, at most 1200 UTF8 bytes."]
            ], "required": ["continuation_id", "response"]]]]
    }
    struct Request: Equatable {
        let id: String; let generation: Int; let order: Int; let name: String
        let subject: String; let topicID: String; let state: String; let quote: String
        let nextTopicID: String; let nextSubject: String; let opening: String; let valid: Bool
        let argumentIssues: [String]; let comparisons: [String: String]
        let finishedRelation: String
        let continuationID: String

        fileprivate func replacing(subject: String, state: String, comparisons: [String: String]) -> Self {
            .init(id: id, generation: generation, order: order, name: name,
                  subject: subject, topicID: topicID, state: state, quote: quote,
                  nextTopicID: nextTopicID, nextSubject: nextSubject, opening: opening,
                  valid: valid, argumentIssues: argumentIssues, comparisons: comparisons,
                  finishedRelation: finishedRelation, continuationID: continuationID)
        }
    }
    private let checkContinuation: Bool
    init(checkContinuation: Bool = false) { self.checkContinuation = checkContinuation }
    private var generation = 0
    private var frame = 0
    private var pending: [String: Request] = [:]
    private var waiting: [String: Int] = [:]
    private var seen: Set<String> = []
    private var decisionPending = false
    private var decisionRequestID: String?
    private var acceptedFrame: Int?
    private var rejectedTurnFinished = false
    private var freshMicActivity = false
    private(set) var requestCount = 0
    var currentRequests: [Request] { pending.values.sorted { $0.order < $1.order } }
    var blocksTurnCompletion: Bool { decisionPending || !pending.isEmpty || !waiting.isEmpty }
    var permitsModelOutput: Bool {
        pending.isEmpty && (!decisionPending || (acceptedFrame.map { frame > $0 } ?? false))
    }
    var needsChoiceReminder: Bool { decisionPending && pending.isEmpty && acceptedFrame == nil }
    mutating func requireDecision() {
        guard !decisionPending else { return }
        decisionPending = true; acceptedFrame = nil
    }

    /// A failed evidence note is not permission to store it. It also mustn't
    /// hold the caller in an endless retry loop. Outstanding tool requests still
    /// receive responses before speech can resume.
    mutating func permitUnrecordedContinuation() {
        decisionPending = false
        decisionRequestID = nil
        acceptedFrame = nil
        rejectedTurnFinished = false
        freshMicActivity = false
    }

    func cancelsActiveRequest(_ ids: Set<String>) -> Bool {
        ids.contains { pending[$0] != nil || waiting[$0] != nil || $0 == decisionRequestID }
    }
    mutating func invalidate() {
        generation += 1; pending.removeAll(); waiting.removeAll(); seen.removeAll()
        decisionPending = false; decisionRequestID = nil; acceptedFrame = nil
        rejectedTurnFinished = false; freshMicActivity = false
    }
    mutating func noteSuppressedCompletion() {
        if decisionPending, acceptedFrame == nil {
            rejectedTurnFinished = true; freshMicActivity = false
        }
    }
    mutating func noteMicrophoneActivity() {
        if rejectedTurnFinished { freshMicActivity = true }
    }
    mutating func beginFreshCallerTranscript() -> Bool {
        guard rejectedTurnFinished, freshMicActivity else { return false }
        invalidate()
        return true
    }
    mutating func requests(in data: Data) -> [Request] {
        frame += 1
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let cancelled = ((root["toolCallCancellation"] ?? root["tool_call_cancellation"]) as? [String: Any])?["ids"] as? [String] ?? []
        for id in cancelled {
            pending.removeValue(forKey: id); waiting.removeValue(forKey: id); seen.insert(id)
            if id == decisionRequestID { decisionPending = false; decisionRequestID = nil; acceptedFrame = nil }
        }
        let tool = (root["toolCall"] ?? root["tool_call"]) as? [String: Any]
        let calls = (tool?["functionCalls"] ?? tool?["function_calls"]) as? [[String: Any]] ?? []
        var result: [Request] = []
        for call in calls {
            guard let function = call["name"] as? String,
                  ([Self.recordName, Self.chooseName, Self.transitionName] + (checkContinuation ? [Self.continuationName] : [])).contains(function), let id = call["id"] as? String,
                  !id.isEmpty, id.utf8.count <= 256, !seen.contains(id) else { continue }
            let args = call["args"] as? [String: Any] ?? [:]
            let choosing = function == Self.chooseName
            let transitioning = function == Self.transitionName
            let continuing = function == Self.continuationName
            let state = continuing ? "CONTINUE" : (choosing ? "CHOOSE" : (transitioning ? "TRANSITION" : (args["state"] as? String ?? "")))
            let subject = args[choosing ? "candidate_subject" : (transitioning ? "finished_subject" : "subject")] as? String ?? ""
            let nextSubject = transitioning ? (args["candidate_subject"] as? String ?? "") : (choosing ? subject : "")
            let finishedRelation = args["relation_to_finished"] as? String ?? ""
            let topicID = args["topic_id"] as? String ?? ""
            let quote = args["source_quote"] as? String ?? ""
            let transition = (args["transition"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let invitation = (args["invitation"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let opening = continuing ? (args["response"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                : [transition, invitation].filter { !$0.isEmpty }.joined(separator: " ")
            let continuationID = args["continuation_id"] as? String ?? ""
            var issues: [String] = []
            if continuing {
                if continuationID.isEmpty || continuationID.utf8.count > 64 { issues.append("continuation_id: use the ID from the current boundary result") }
                if opening.isEmpty || opening.utf8.count > 1200 { issues.append("response: nonempty, at most 1200 UTF8 bytes") }
            }
            if !continuing, !Self.validLabel(subject) { issues.append("subject: nonempty, at most 96 UTF8 bytes") }
            if topicID.utf8.count > 64 { issues.append("topic_id: at most 64 UTF8 bytes") }
            var comparisons: [String: String] = [:]
            if transitioning {
                if !Self.validLabel(nextSubject) { issues.append("candidate_subject: nonempty, at most 96 UTF8 bytes") }
                if !["same", "different"].contains(finishedRelation) { issues.append("relation_to_finished: same or different") }
            }
            if choosing || transitioning {
                if invitation.isEmpty || invitation.utf8.count > 384 {
                    issues.append("invitation: a nonempty question or open-ended cue, at most 384 UTF8 bytes")
                } else if Self.handsBackAgenda(invitation) {
                    issues.append("invitation: ask about candidate_subject specifically; do not ask the caller to choose the subject")
                }
                if transition.utf8.count > 128 || opening.utf8.count > 512 {
                    issues.append("transition: optional brief bridge, at most 128 UTF8 bytes")
                }
                if let entries = args["comparisons"] as? [[String: Any]], entries.count <= 64 {
                    for entry in entries {
                        guard let id = entry["finished_topic_id"] as? String, !id.isEmpty,
                              let relation = entry["relation"] as? String, ["same", "different"].contains(relation),
                              comparisons[id] == nil else { issues.append("comparisons: unique IDs and same/different relations"); continue }
                        comparisons[id] = relation
                    }
                } else { issues.append("comparisons: one comparison per finished subject") }
            } else if !continuing {
                if !["FINISHED", "CALLER_SWITCH", "REOPENED"].contains(state) { issues.append("state: FINISHED, CALLER_SWITCH or REOPENED") }
            }
            if !choosing {
                if args["source_quote"] != nil &&
                    (quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || quote.utf8.count > 160) {
                    issues.append("legacy source_quote: if supplied, an exact current-caller quote at most 160 UTF8 bytes")
                }
            }
            let valid = issues.isEmpty
            let request = Request(id: id, generation: generation, order: requestCount,
                                  name: function, subject: subject, topicID: topicID, state: state, quote: quote,
                                  nextTopicID: "", nextSubject: nextSubject, opening: opening, valid: valid, argumentIssues: issues, comparisons: comparisons,
                                  finishedRelation: finishedRelation, continuationID: continuationID)
            pending[id] = request; seen.insert(id); requestCount += 1; result.append(request)
            decisionPending = true; decisionRequestID = id; acceptedFrame = nil
            rejectedTurnFinished = false; freshMicActivity = false
        }
        return result
    }
    private static func validLabel(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 96 &&
            text.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// Only validates model-proposed invitations at a topic boundary. A broad
    /// agenda question does not fulfil the tool's existing specific-subject
    /// contract. Anchoring preserves named-topic questions, consent, quotations,
    /// and ordinary opening questions outside this boundary mechanism.
    fileprivate static func handsBackAgenda(_ invitation: String) -> Bool {
        let text = invitation.replacingOccurrences(of: "’", with: "'")
            .lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:(?:so|well|okay|ok|right|all right|alright)[,.]?\s+)+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .?!…"))
        let patterns = [
            #"^(?:is there )?(?:anything|something)(?: else)? (?:that )?you(?:'d like| would like| want) to (?:talk about|discuss|share|add|update me on)(?: (?:today|next|now|right now))?$"#,
            #"^what(?: else)? (?:would you like|do you want) to (?:talk about|discuss|focus on|explore|work on)(?: (?:today|next|now|right now))?$"#,
            #"^what(?: else)? (?:should|shall|could) we (?:talk about|discuss|focus on|explore|work on)(?: (?:today|next|now|right now))?$"#,
            #"^what(?:'s| is| has been)(?: else)? on your mind(?: (?:today|lately|now|right now))?$"#,
            #"^where (?:would you like|do you want) to (?:start|go from here|go next)$"#
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
    mutating func noteModelOutput() {
        guard permitsModelOutput else { return }
        waiting = waiting.filter { $0.value >= frame }
        decisionPending = false; decisionRequestID = nil; acceptedFrame = nil
        rejectedTurnFinished = false; freshMicActivity = false
    }
    /// A completed accepted check need not produce more speech: the question
    /// may already have been streamed before the tool call. Wait for a later
    /// server frame so coalesced output from the original tool-call frame cannot
    /// acknowledge a response we have only just sent.
    mutating func noteServerCompletion() {
        guard let acceptedFrame, frame > acceptedFrame, pending.isEmpty else { return }
        noteModelOutput()
    }
    func isCurrent(_ request: Request) -> Bool { request.generation == generation && pending[request.id] == request }
    mutating func response(for request: Request, payload: Data) -> Data? {
        guard isCurrent(request), payload.count <= 65_536,
              let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              value["kind"] as? String == "model_call_notes" else { return nil }
        let message: [String: Any] = ["toolResponse": ["functionResponses": [[
            "id": request.id, "name": request.name, "response": value
        ]]]]
        guard let encoded = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        pending.removeValue(forKey: request.id)
        waiting[request.id] = frame
        acceptedFrame = value["status"] as? String == "accepted" ? frame : nil
        if acceptedFrame != nil { rejectedTurnFinished = false; freshMicActivity = false }
        return encoded
    }
}

/// Conservative, English-only evidence of a personal contribution at a
/// proposed boundary. It does not diagnose emotion, classify all intent, or
/// run on ordinary replies. Negation, quotes and explicit closure take priority.
enum CallTopicContinuationCue {
    static func matches(_ source: String) -> Bool {
        guard source.utf8.count <= 16_000, !CallTopicBoundaryCue.matches(source) else { return false }
        let text = source.replacingOccurrences(of: "[\"“][^\"”]*[\"”]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?<!\\w)[‘'].*?[’'](?!\\w)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "’", with: "'").lowercased()
        let closure = #"\b(?:(?:let's|let us|can we|could we) (?:move on|change (?:the )?subject|leave [^.!?;]{0,80}there|not (?:discuss|talk about))|i (?:don't|do not) want to (?:discuss|talk about)|(?:goodbye|hang up|end the call|wrap up))\b"#
        if text.range(of: closure, options: .regularExpression) != nil { return false }
        let feelings = "(?:excited|nervous|worried|scared|afraid|angry|upset|sad|frustrated|anxious|relieved|disappointed|overwhelmed|lonely|confused|torn|hopeful)"
        let modifiers = "(?:(?:just|really|so|very|quite|a bit|a little|pretty|still) )*"
        let expressions = [
            "^i(?: am|'m| feel| am feeling|'m feeling) " + modifiers + feelings + "\\b",
            #"^i (?:can't|cannot) (?:wait\b|stop (?:smiling|grinning|worrying)\b)"#,
            #"^i(?: am|'m) (?:really |so |very much )?looking forward to\b"#,
            "^(?:it|that|this) (?:makes|is making) me " + modifiers + feelings + "\\b"
        ]
        for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?;\n")) {
            // A hypothetical or someone else's quoted/reported speech is not
            // a direct present-tense report from this caller.
            if sentence.range(of: #"\b(?:if|suppose|imagine|for example|said|says|saying|told me|asked me)\b"#, options: .regularExpression) != nil { continue }
            for clause in sentence.components(separatedBy: ",") {
                let value = clause.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^(?:(?:and|but|honestly|actually|well|yeah|yes|no|you know|to be honest) )+"#, with: "", options: .regularExpression)
                if expressions.contains(where: { value.range(of: $0, options: .regularExpression) != nil }) { return true }
            }
        }
        return false
    }
}

/// Conservative cue for explicit English requests to close a subject.
/// It does not classify every natural or implicit transition.
enum CallTopicBoundaryCue {
    static func matches(_ source: String) -> Bool {
        guard source.count <= 16_000 else { return false }
        let unquoted = source.replacingOccurrences(of: "[\"“][^\"”]*[\"”]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?<!\\w)[‘'].*?[’'](?!\\w)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "’", with: "'").lowercased()
        if unquoted.range(of: "\\b(?:goodbye|hang up|end the call|wrap up|don't want to talk at all|don't want to talk about anything)\\b", options: .regularExpression) != nil { return false }
        let clauses = unquoted.components(separatedBy: CharacterSet(charactersIn: ".!?;\n"))
        for clause in clauses {
            var text = clause.replacingOccurrences(of: "[^a-z0-9']+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            text = text.replacingOccurrences(of: "^(?:(?:actually|okay|ok|alright|right|well|so) )+", with: "", options: .regularExpression)
            if text.contains(" but ") { continue }
            let patterns = [
                "^(?:that's|that is|this is) (?:everything|enough) about ",
                "^(?:that's|that is) all (?:(?:i|we) (?:want|wanted|need|needed) to say )?about ",
                "^(?:let's|let us) (?:talk|chat) about (?:something|anything) else",
                "^(?:can|could) we (?:keep|continue) (?:chatting|talking) about (?:something|anything) (?:ordinary|else|lighter)",
                "^(?:let's|let us) not (?:get into|discuss|talk about) ",
                "^i (?:don't|do not) want to (?:get into|discuss|talk about) "
            ]
            if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { return true }
        }
        return false
    }
}
