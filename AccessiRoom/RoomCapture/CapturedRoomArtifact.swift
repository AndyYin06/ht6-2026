import Foundation
import RoomPlan

enum CapturedRoomSource: String, Codable, Sendable {
    case liveScan
    case demo

    var displayName: String {
        switch self {
        case .liveScan: "Room Scan"
        case .demo: "Demo Room"
        }
    }
}

struct CapturedRoomArtifact: Identifiable, Equatable, Sendable {
    let id: UUID
    let jsonURL: URL
    let usdzURL: URL
    let source: CapturedRoomSource
    let capturedAt: Date
    let disposableDirectory: URL?
}

enum CapturedRoomArtifactError: LocalizedError {
    case demoResourcesMissing

    var errorDescription: String? {
        switch self {
        case .demoResourcesMissing:
            "The bundled Demo Room files could not be loaded."
        }
    }
}

struct CapturedRoomArtifactProcessor {
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func process(_ room: CapturedRoom) throws -> CapturedRoomArtifact {
        let id = UUID()
        let directory = temporaryDirectory
            .appending(path: "AccessiRoom-Candidate-\(id.uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let jsonURL = directory.appending(path: "CapturedRoom.json")
            let usdzURL = directory.appending(path: "CapturedRoom.usdz")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(room).write(to: jsonURL, options: .atomic)
            try room.export(to: usdzURL, exportOptions: .parametric)

            return CapturedRoomArtifact(
                id: id,
                jsonURL: jsonURL,
                usdzURL: usdzURL,
                source: .liveScan,
                capturedAt: Date(),
                disposableDirectory: directory
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func demoArtifact(bundle: Bundle = .main) throws -> CapturedRoomArtifact {
        guard
            let jsonURL = bundle.url(forResource: "DemoRoom", withExtension: "json"),
            let usdzURL = bundle.url(forResource: "DemoRoom", withExtension: "usdz")
        else {
            throw CapturedRoomArtifactError.demoResourcesMissing
        }

        return CapturedRoomArtifact(
            id: UUID(),
            jsonURL: jsonURL,
            usdzURL: usdzURL,
            source: .demo,
            capturedAt: Date(),
            disposableDirectory: nil
        )
    }

    func discard(_ artifact: CapturedRoomArtifact) {
        guard let directory = artifact.disposableDirectory else { return }
        try? fileManager.removeItem(at: directory)
    }
}
