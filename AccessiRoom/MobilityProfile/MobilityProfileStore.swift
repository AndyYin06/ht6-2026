import Combine
import Foundation

@MainActor
final class MobilityProfileStore: ObservableObject {
    @Published private(set) var profile: MobilityProfile?
    @Published private(set) var confirmation: MobilityProfileConfirmation?

    var isConfirmed: Bool {
        guard let profile, let confirmation else { return false }
        return confirmation.profileID == profile.id && confirmation.revision == profile.revision
    }

    private struct PersistedState: Codable {
        let profile: MobilityProfile?
        let confirmation: MobilityProfileConfirmation?
    }

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let stateURL: URL

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.rootDirectory = rootDirectory
            ?? applicationSupport.appending(path: "AccessiRoom", directoryHint: .isDirectory)
        stateURL = self.rootDirectory.appending(path: "MobilityProfile.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: stateURL),
           let state = try? decoder.decode(PersistedState.self, from: data) {
            profile = state.profile
            confirmation = state.confirmation
        }
    }

    func save(_ draft: MobilityProfile) throws {
        var saved = draft
        saved.occupantName = draft.occupantName.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.customNeeds = draft.customNeeds.map { need in
            var cleaned = need
            cleaned.title = need.title.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.details = need.details.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned
        }

        let changed = profile.map { existing in
            var lhs = existing
            var rhs = saved
            lhs.revision = 0
            rhs.revision = 0
            lhs.modifiedAt = .distantPast
            rhs.modifiedAt = .distantPast
            return lhs != rhs
        } ?? true

        guard changed else { return }
        saved.revision = (profile?.revision ?? 0) + 1
        saved.modifiedAt = Date()
        profile = saved
        confirmation = nil
        try persist()
    }

    func confirm() throws {
        guard let profile, profile.isComplete else {
            throw MobilityProfileStoreError.incompleteProfile
        }
        confirmation = MobilityProfileConfirmation(
            profileID: profile.id,
            revision: profile.revision,
            confirmedAt: Date()
        )
        try persist()
    }

    private func persist() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        var storageURL = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try storageURL.setResourceValues(values)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: rootDirectory.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PersistedState(profile: profile, confirmation: confirmation))
            .write(to: stateURL, options: [.atomic, .completeFileProtection])
    }
}

enum MobilityProfileStoreError: LocalizedError {
    case incompleteProfile

    var errorDescription: String? {
        "Enter the Room Occupant and all required measurements before confirming."
    }
}
