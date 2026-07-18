import Foundation

struct ProposedObjectChange: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    var translationXMetres: Double
    var translationZMetres: Double
    var rotationRadians: Double
    var isRemoved: Bool

    static func unchanged(objectID: String) -> ProposedObjectChange {
        ProposedObjectChange(
            id: objectID,
            translationXMetres: 0,
            translationZMetres: 0,
            rotationRadians: 0,
            isRemoved: false
        )
    }

    var hasEffect: Bool {
        abs(translationXMetres) > 0.000_001
            || abs(translationZMetres) > 0.000_001
            || abs(rotationRadians) > 0.000_001
            || isRemoved
    }
}

struct ProposedArrangement: Codable, Equatable, Hashable, Sendable {
    let roomID: UUID
    var changes: [ProposedObjectChange]

    static func empty(roomID: UUID) -> ProposedArrangement {
        ProposedArrangement(roomID: roomID, changes: [])
    }

    var hasChanges: Bool { changes.contains(where: \.hasEffect) }

    func change(for objectID: String) -> ProposedObjectChange? {
        changes.first { $0.id == objectID }
    }

    mutating func update(
        objectID: String,
        _ update: (inout ProposedObjectChange) -> Void
    ) {
        var change = change(for: objectID) ?? .unchanged(objectID: objectID)
        update(&change)
        changes.removeAll { $0.id == objectID }
        if change.hasEffect {
            changes.append(change)
            changes.sort { $0.id < $1.id }
        }
    }
}
