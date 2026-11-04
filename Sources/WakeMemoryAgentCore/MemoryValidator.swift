import Foundation

public enum MemoryValidationError: Error, Equatable {
    case tooManyOperations
    case invalidKey
    case invalidSource
    case invalidText
    case invalidStatus
}

public enum MemoryValidator {
    /// Work on a value copy. One invalid operation rejects the entire batch.
    /// Provenance checks do not prove that a model's interpretation is semantically correct.
    public static func applying(_ batch: ProposedBatch, to snapshot: MemorySnapshot,
                                sourceTurns: [SourceTurn]) throws -> MemorySnapshot {
        guard batch.operations.count <= 64 else { throw MemoryValidationError.tooManyOperations }
        var result = snapshot
        let sources = Dictionary(sourceTurns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for operation in batch.operations {
            let key = operation.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, key.count <= 80 else { throw MemoryValidationError.invalidKey }
            guard let source = sources[operation.sourceTurnID], source.role == .user,
                  !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoryValidationError.invalidSource
            }
            guard operation.kind == .commitment || operation.status == nil else {
                throw MemoryValidationError.invalidStatus
            }
            let text = operation.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            if operation.action != .retract {
                guard let text, !text.isEmpty, text.count <= 160 else {
                    throw MemoryValidationError.invalidText
                }
            }
            let id = MemorySnapshot.storageKey(kind: operation.kind, key: key)
            if let current = result.facts[id],
               current.sourceDate > source.date ||
                (current.sourceDate == source.date && current.sourceTurnID > source.id) {
                // A delayed result may acknowledge its own old input, but cannot overwrite
                // a fact supported by a more recent correction.
                continue
            }
            if operation.action == .retract {
                result.facts.removeValue(forKey: id)
            } else {
                result.facts[id] = MemoryFact(kind: operation.kind, key: key, text: text!,
                    status: operation.status ?? result.facts[id]?.status, sourceTurnID: source.id, sourceDate: source.date)
            }
        }
        return result
    }
}
