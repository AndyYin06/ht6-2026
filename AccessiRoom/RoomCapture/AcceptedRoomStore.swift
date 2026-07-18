import Combine
import Foundation

@MainActor
final class AcceptedRoomStore: ObservableObject {
    @Published private(set) var acceptedRoom: CapturedRoomArtifact?
    @Published private(set) var roomSetup: RoomSetup?

    private struct Manifest: Codable {
        let id: UUID
        let capturedAt: Date
        let source: CapturedRoomSource
        let directoryName: String
    }

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let roomsDirectory: URL
    private let manifestURL: URL

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager

        let resolvedRoot = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        self.rootDirectory = resolvedRoot
        roomsDirectory = resolvedRoot.appending(path: "Rooms", directoryHint: .isDirectory)
        manifestURL = resolvedRoot.appending(path: "AcceptedRoom.json")
        acceptedRoom = Self.loadAcceptedRoom(
            manifestURL: manifestURL,
            roomsDirectory: roomsDirectory,
            fileManager: fileManager
        )
        roomSetup = acceptedRoom.flatMap {
            Self.loadRoomSetup(for: $0, fileManager: fileManager)
        }
    }

    func accept(_ candidate: CapturedRoomArtifact) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try excludeStorageFromDeviceBackup()
        try fileManager.createDirectory(at: roomsDirectory, withIntermediateDirectories: true)

        let acceptedID = UUID()
        let directoryName = acceptedID.uuidString
        let acceptedDirectory = roomsDirectory
            .appending(path: directoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: acceptedDirectory, withIntermediateDirectories: false)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: acceptedDirectory.path
        )

        let jsonURL = acceptedDirectory.appending(path: "CapturedRoom.json")
        let usdzURL = acceptedDirectory.appending(path: "CapturedRoom.usdz")

        do {
            try fileManager.copyItem(at: candidate.jsonURL, to: jsonURL)
            try fileManager.copyItem(at: candidate.usdzURL, to: usdzURL)

            let manifest = Manifest(
                id: acceptedID,
                capturedAt: candidate.capturedAt,
                source: candidate.source,
                directoryName: directoryName
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

            acceptedRoom = CapturedRoomArtifact(
                id: acceptedID,
                jsonURL: jsonURL,
                usdzURL: usdzURL,
                source: candidate.source,
                capturedAt: candidate.capturedAt,
                disposableDirectory: nil
            )
            roomSetup = nil
            removeUnacceptedRoomDirectories(keepingDirectoryNamed: directoryName)
        } catch {
            try? fileManager.removeItem(at: acceptedDirectory)
            throw error
        }
    }

    func confirm(_ setup: RoomSetup, inventory: CapturedRoomInventory) throws {
        guard let acceptedRoom, setup.roomID == acceptedRoom.id else {
            throw AcceptedRoomStoreError.setupDoesNotMatchAcceptedRoom
        }
        if let message = setup.validationMessage(inventory: inventory) {
            throw AcceptedRoomStoreError.invalidSetup(message)
        }

        var confirmed = setup
        confirmed.confirmedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(confirmed).write(
            to: acceptedRoom.jsonURL.deletingLastPathComponent().appending(path: "RoomSetup.json"),
            options: [.atomic, .completeFileProtection]
        )
        roomSetup = confirmed
    }

    private func excludeStorageFromDeviceBackup() throws {
        var storageURL = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try storageURL.setResourceValues(values)
    }

    private func removeUnacceptedRoomDirectories(keepingDirectoryNamed acceptedDirectoryName: String) {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: roomsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for directory in directories where directory.lastPathComponent != acceptedDirectoryName {
            try? fileManager.removeItem(at: directory)
        }
    }

    private static func defaultRootDirectory(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport.appending(path: "AccessiRoom", directoryHint: .isDirectory)
    }

    private static func loadAcceptedRoom(
        manifestURL: URL,
        roomsDirectory: URL,
        fileManager: FileManager
    ) -> CapturedRoomArtifact? {
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }

        let directory = roomsDirectory
            .appending(path: manifest.directoryName, directoryHint: .isDirectory)
        let jsonURL = directory.appending(path: "CapturedRoom.json")
        let usdzURL = directory.appending(path: "CapturedRoom.usdz")
        guard
            fileManager.fileExists(atPath: jsonURL.path),
            fileManager.fileExists(atPath: usdzURL.path)
        else { return nil }

        return CapturedRoomArtifact(
            id: manifest.id,
            jsonURL: jsonURL,
            usdzURL: usdzURL,
            source: manifest.source,
            capturedAt: manifest.capturedAt,
            disposableDirectory: nil
        )
    }

    private static func loadRoomSetup(
        for room: CapturedRoomArtifact,
        fileManager: FileManager
    ) -> RoomSetup? {
        let url = room.jsonURL.deletingLastPathComponent().appending(path: "RoomSetup.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let setup = try? decoder.decode(RoomSetup.self, from: data),
              setup.roomID == room.id else { return nil }
        return setup
    }
}

enum AcceptedRoomStoreError: LocalizedError {
    case setupDoesNotMatchAcceptedRoom
    case invalidSetup(String)

    var errorDescription: String? {
        switch self {
        case .setupDoesNotMatchAcceptedRoom:
            "This setup belongs to a different Accepted Room."
        case .invalidSetup(let message):
            message
        }
    }
}
