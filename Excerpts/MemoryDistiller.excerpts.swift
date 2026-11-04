// Selected implementation from Wake/Services/MemoryDistiller.swift.
// Contract types and method bodies are unchanged. The extension is a presentation
// wrapper; stored properties, prompt construction, provider configuration and
// application-owned stores remain in the private app.

import Foundation
import GoogleGenerativeAI

// MARK: - Distiller contract types
//
// The background distiller PROPOSES these ops; MemoryStore.apply() and
// MindMapManager.apply() DISPOSE them deterministically. The model never edits
// either store directly. One distill call now produces BOTH the coach-memory ops
// AND the user-facing Mind Map category ops — no second Gemini request.

struct DistillResult: Codable {
    var summaryDelta: String?
    var factOps: [FactOp]?
    var safetyOps: [SafetyOp]?
    var approachNotes: [String]?
    var pushLevel: String?
    /// Advice, questions, or framing Wake gave. Stored separately from user facts.
    var wakeGuidanceOps: [GuidanceOp]?
    /// Mind Map (the visible category circles). Optional + additive: existing
    /// memory behaviour is unchanged when this is absent.
    var categoryOps: [CategoryOp]?
    /// Mind Map v2: recurring loops, shifts, and tiny next actions. The model
    /// proposes; MindMapManager caps, dedupes, and merges deterministically.
    var patternOps: [PatternOp]?
    var insightOps: [InsightOp]?
    var nextStepOps: [NextStepOp]?
}

struct FactOp: Codable {
    var op: String      // "add" | "update" | "retract"
    var kind: String    // goal | commitment | pattern | triedRejected | person | preference
    var key: String     // normalized dedup key
    var text: String?
    var status: String? // commitments only: open | done | dropped
    var sourceTurn: Int? = nil // exact user-turn sequence, validated before applying
}

struct SafetyOp: Codable {
    var op: String      // "add" | "raise"  (never lower / clear)
    var text: String    // internal guidance, non-verbatim
    var severity: String // monitor | elevated | acute
}

struct GuidanceOp: Codable {
    var op: String      // "add" | "update" | "retract"
    var key: String     // normalized dedup key
    var text: String?   // <=140 char canonical statement of what Wake said/suggested
}

// MARK: Mind Map ops (consumed by MindMapManager.apply)

struct CategoryOp: Codable {
    var key: String            // stable kebab key, e.g. "relationships"
    var name: String?          // display name, e.g. "Relationships"
    var weightNudge: Double?   // multiplicative on share-of-mind: >1 grew, <1 eased, ~1 stable
    var items: [MindItemOp]?
}

struct MindItemOp: Codable {
    var op: String?            // "add" | "update" | "resolve" (flip bothers→peaceful). default add
    var key: String
    var text: String?
    var sentiment: String?     // "bothers" | "peaceful"
    var weight: Double?        // 0...1 within the category
}

struct PatternOp: Codable {
    var op: String?            // "add" | "update" | "ease" | "resolve" | "retract". default add
    var key: String
    var title: String?
    var detail: String?
    var categoryKey: String?
    var kind: String?          // avoidance | rumination | trigger | value | support | progress | other
    var confidence: Double?    // 0...1
    var suggestedMove: String?
    var evidence: String?      // short non-verbatim evidence from the new turns
}

struct InsightOp: Codable {
    var key: String
    var title: String?
    var body: String?
    var categoryKey: String?
    var tone: String?          // useful | progress | caution
    var confidence: Double?
}

struct NextStepOp: Codable {
    var op: String?            // "add" | "update" | "done" | "drop" | "retract". default add
    var key: String
    var text: String?
    var categoryKey: String?
    var status: String?        // open | done | dropped
}


extension MemoryDistiller {
    // Original source lines 144–172.
    func requestDistill(reason: String) async {
        guard !suppressAutomaticTestHostRequests else { return }
        // Claim single-flight before any await. Coalesced triggers are not API
        // requests and must not consume the user's daily budget.
        if running { rerunRequested = true; return }
        guard retryState.canAttempt(at: Date()) else { scheduleDeferredRequest(); return }
        deferredRequest?.cancel()
        deferredRequest = nil
        running = true
        rerunRequested = false
        defer { running = false }
        let subscribed = await MainActor.run { SubscriptionManager.shared.hasActiveSubscription() }

        // Nothing new to fold → don't spend a call (or a free-budget unit).
        let hasTurns = await MainActor.run { !MessageManager.shared.unfoldedTurns().isEmpty }
        guard hasTurns else {
            await MainActor.run { MemoryStore.shared.resetDistillCounter() }
            return
        }

        guard await runOnce(reason: reason, subscribed: subscribed) else { return }
        while rerunRequested {
            rerunRequested = false
            guard await runOnce(reason: "rerun", subscribed: subscribed) else { return }
        }
        if await MainActor.run(body: { !MessageManager.shared.unfoldedTurns().isEmpty }) {
            scheduleDeferredRequest()
        }
    }


    // Original source lines 174–240.
    private func runOnce(reason: String, subscribed: Bool) async -> Bool {
        guard retryState.canAttempt(at: Date()) else { scheduleDeferredRequest(); return false }
        let all = await MainActor.run { MessageManager.shared.unfoldedTurns() }
        guard !all.isEmpty else {
            await MainActor.run { MemoryStore.shared.resetDistillCounter() }
            return false
        }
        let delta = MemoryTurnLog.nextBatch(all)
        let maxSeq = delta.last?.seq ?? 0
        let memory = await MainActor.run { MemoryStore.shared.memory }
        let mindMap = await MainActor.run { MindMapManager.shared.map }

        guard let prompt = Self.buildPrompt(memory: memory, mindMap: mindMap, turns: delta) else { return false }
        if !subscribed, !Self.consumeFreeDistillBudget() {
            await MainActor.run { MemoryStore.shared.resetDistillCounter() }
            return false
        }
        guard beginMemoryRequest() else { return false }

        await MainActor.run { MindMapManager.shared.setDistilling(true) }
        do {
            let response = try await Self.makeModel(apiKey: APIKeyManager.shared.currentKey).generateContent(prompt)
            guard let text = response.text, let result = Self.parse(text) else {
                memoryRequestFailed()
                print("[MemoryDistiller] unparseable response — leaving stores unchanged")
                await MainActor.run { MindMapManager.shared.setDistilling(false) }
                return false
            }
            let channel = delta.last?.channel ?? "chat"
            let applied = await MainActor.run {
                guard !subscribed || MemoryStore.canApplyFactOperations(result, to: MemoryStore.shared.memory, sourceTurns: delta) else {
                    MindMapManager.shared.setDistilling(false)
                    return false
                }
                if subscribed {
                    MemoryStore.shared.apply(result, channel: channel, sourceTurns: delta)
                } else {
                    MemoryStore.shared.applySafetyOnly(result, channel: channel) // safety is never paywalled
                    MemoryStore.shared.resetDistillCounter()
                }
                MindMapManager.shared.apply(categoryOps: result.categoryOps,
                                            patternOps: result.patternOps,
                                            insightOps: result.insightOps,
                                            nextStepOps: result.nextStepOps,
                                            note: result.summaryDelta,
                                            channel: channel,
                                            sessionID: MessageManager.shared.currentSessionID,
                                            sourceTurns: delta)
                MessageManager.shared.markFolded(upTo: maxSeq)
                MindMapManager.shared.setDistilling(false)
                return true
            }
            guard applied else {
                memoryRequestFailed()
                print("[MemoryDistiller] invalid fact batch — retaining pending source turns")
                return false
            }
            memoryRequestSucceeded()
            print("[MemoryDistiller] folded \(delta.count) turns (reason: \(reason), subscribed: \(subscribed))")
            return true
        } catch {
            memoryRequestFailed()
            await MainActor.run { MindMapManager.shared.setDistilling(false) }
            print("[MemoryDistiller] distill failed (\(reason)): \(error.localizedDescription)")
            return false
        }
    }


    // Original source lines 306–310.
    private func beginMemoryRequest() -> Bool {
        guard retryState.beginAttempt(at: Date()) else { return false }
        persistRetryState()
        return true
    }


    // Original source lines 312–316.
    private func memoryRequestFailed() {
        retryState.failed(at: Date())
        persistRetryState()
        scheduleDeferredRequest()
    }


    // Original source lines 318–321.
    private func memoryRequestSucceeded() {
        retryState.succeeded()
        persistRetryState()
    }


    // Original source lines 323–327.
    private func persistRetryState() {
        if let data = try? JSONEncoder().encode(retryState) {
            UserDefaults.standard.set(data, forKey: Self.retryStateKey)
        }
    }


    // Original source lines 331–341.
    private func scheduleDeferredRequest() {
        guard deferredRequest == nil else { return }
        let delay = max(1, retryState.nextAttemptAfter?.timeIntervalSinceNow ?? 1)
        deferredRequest = Task {
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self.deferredRequest = nil
            await self.requestDistill(reason: "deferred")
        }
    }

}
