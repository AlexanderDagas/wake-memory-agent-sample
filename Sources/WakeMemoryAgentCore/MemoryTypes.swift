import Foundation

public struct SourceTurn: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let id: Int
    public let role: Role
    public let text: String
    public let date: Date

    public init(id: Int, role: Role, text: String, date: Date) {
        self.id = id; self.role = role; self.text = text; self.date = date
    }
}

public struct MemoryOperation: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case add, update, retract }
    public enum Kind: String, Codable, Sendable { case goal, commitment, preference }
    public enum Status: String, Codable, Sendable { case open, done, dropped }

    public let action: Action
    public let kind: Kind
    public let key: String
    public let text: String?
    public let sourceTurnID: Int
    public let status: Status?

    public init(action: Action, kind: Kind, key: String, text: String? = nil,
                sourceTurnID: Int, status: Status? = nil) {
        self.action = action; self.kind = kind; self.key = key; self.text = text
        self.sourceTurnID = sourceTurnID; self.status = status
    }
}

public struct ProposedBatch: Codable, Sendable {
    public let operations: [MemoryOperation]
    public init(operations: [MemoryOperation]) { self.operations = operations }
}

public struct MemoryFact: Sendable, Equatable {
    public let kind: MemoryOperation.Kind
    public let key: String
    public var text: String
    public var status: MemoryOperation.Status?
    public var sourceTurnID: Int
    public var sourceDate: Date

    public init(kind: MemoryOperation.Kind, key: String, text: String,
                status: MemoryOperation.Status? = nil, sourceTurnID: Int, sourceDate: Date) {
        self.kind = kind; self.key = key; self.text = text; self.status = status
        self.sourceTurnID = sourceTurnID; self.sourceDate = sourceDate
    }
}

public struct MemorySnapshot: Sendable, Equatable {
    public var facts: [String: MemoryFact]
    public var acknowledgedThrough: Int

    public init(facts: [String: MemoryFact] = [:], acknowledgedThrough: Int = 0) {
        self.facts = facts; self.acknowledgedThrough = acknowledgedThrough
    }

    public static func storageKey(kind: MemoryOperation.Kind, key: String) -> String {
        "\(kind.rawValue):\(key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}

public struct MemoryRequest: Sendable {
    public let snapshot: MemorySnapshot
    public let turns: [SourceTurn]
}

/// A provider adapter returns structured model output; it never receives a store reference.
public protocol MemoryModel: Sendable {
    func proposeUpdate(for request: MemoryRequest) async throws -> Data
}
