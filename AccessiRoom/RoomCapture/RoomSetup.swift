import Foundation

struct CapturedRoomInventory: Equatable {
    struct Item: Identifiable, Equatable {
        let id: String
        let category: String
        let widthMetres: Double
        let depthMetres: Double
        let confidence: String?

        var displayName: String {
            category.replacingOccurrences(of: "_", with: " ").capitalized
        }

        var dimensionsDescription: String {
            String(format: "%.2f × %.2f m", widthMetres, depthMetres)
        }
    }

    let accessPointCandidates: [Item]
    let architecturalFeatures: [Item]
    let objects: [Item]

    static func load(from url: URL) throws -> CapturedRoomInventory {
        let data = try Data(contentsOf: url)
        let room = try JSONDecoder().decode(RoomPlanDocument.self, from: data)

        let doors = room.items(in: room.doors, fallbackCategory: "door")
        let openings = room.items(in: room.openings, fallbackCategory: "opening")
        let windows = room.items(in: room.windows, fallbackCategory: "window")
        let walls = room.items(in: room.walls, fallbackCategory: "wall")

        return CapturedRoomInventory(
            accessPointCandidates: doors + openings,
            architecturalFeatures: walls + doors + openings + windows,
            objects: room.items(in: room.objects, fallbackCategory: "object")
        )
    }
}

private struct RoomPlanDocument: Decodable {
    struct Element: Decodable {
        let identifier: String
        let category: [String: JSONValue]
        let dimensions: [Double]
        let confidence: [String: JSONValue]?
    }

    let doors: [Element]
    let openings: [Element]
    let windows: [Element]
    let walls: [Element]
    let objects: [Element]

    private enum CodingKeys: String, CodingKey {
        case doors, openings, windows, walls, objects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        doors = try container.decodeIfPresent([Element].self, forKey: .doors) ?? []
        openings = try container.decodeIfPresent([Element].self, forKey: .openings) ?? []
        windows = try container.decodeIfPresent([Element].self, forKey: .windows) ?? []
        walls = try container.decodeIfPresent([Element].self, forKey: .walls) ?? []
        objects = try container.decodeIfPresent([Element].self, forKey: .objects) ?? []
    }

    func items(
        in elements: [Element],
        fallbackCategory: String
    ) -> [CapturedRoomInventory.Item] {
        elements.map { element in
            CapturedRoomInventory.Item(
                id: element.identifier,
                category: element.category.keys.first ?? fallbackCategory,
                widthMetres: element.dimensions.first ?? 0,
                depthMetres: element.dimensions.count > 2
                    ? element.dimensions[2]
                    : element.dimensions.dropFirst().first ?? 0,
                confidence: element.confidence?.keys.first
            )
        }
    }
}

private enum JSONValue: Decodable {
    case ignored

    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
        self = .ignored
    }
}

enum DestinationPriority: String, Codable, CaseIterable, Identifiable {
    case essential
    case preference

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ApproachSide: String, Codable, CaseIterable, Identifiable {
    case front
    case left
    case right
    case back

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ApproachZoneSetup: Codable, Equatable {
    var side: ApproachSide
    var widthMetres: Double
    var depthMetres: Double
}

struct CapturedObjectSetup: Codable, Equatable, Identifiable {
    let id: String
    var isIncluded: Bool
    var isMovable: Bool
    var isRequiredDestination: Bool
    var destinationPriority: DestinationPriority
    var approachZone: ApproachZoneSetup
}

struct TurningZoneSetup: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var centreXMetres: Double
    var centreZMetres: Double
    var diameterMetres: Double
}

struct RoomSetup: Codable, Equatable {
    let roomID: UUID
    var accessPointIDs: Set<String>
    var architecturalFeatureIDs: Set<String>
    var objects: [CapturedObjectSetup]
    var turningZones: [TurningZoneSetup]
    var confirmedAt: Date?

    var isConfirmed: Bool { confirmedAt != nil }

    static func draft(
        roomID: UUID,
        inventory: CapturedRoomInventory,
        measurements: MobilityMeasurements?
    ) -> RoomSetup {
        let approachWidth = (measurements?.clearFloorSpaceWidthCentimetres ?? 75) / 100
        let approachDepth = (measurements?.clearFloorSpaceDepthCentimetres ?? 120) / 100
        return RoomSetup(
            roomID: roomID,
            accessPointIDs: [],
            architecturalFeatureIDs: Set(inventory.architecturalFeatures.map(\.id)),
            objects: inventory.objects.map {
                CapturedObjectSetup(
                    id: $0.id,
                    isIncluded: true,
                    isMovable: false,
                    isRequiredDestination: false,
                    destinationPriority: .essential,
                    approachZone: ApproachZoneSetup(
                        side: .front,
                        widthMetres: approachWidth,
                        depthMetres: approachDepth
                    )
                )
            },
            turningZones: [],
            confirmedAt: nil
        )
    }

    func validationMessage(inventory: CapturedRoomInventory) -> String? {
        guard !accessPointIDs.isEmpty else {
            return "Confirm at least one circulation door or opening as an Access Point."
        }
        guard !architecturalFeatureIDs.isEmpty else {
            return "Confirm the fixed features that constrain movement."
        }
        guard objects.contains(where: { $0.isIncluded && $0.isRequiredDestination }) else {
            return "Select at least one Required Destination."
        }
        guard objects.filter({ $0.isIncluded && $0.isRequiredDestination }).allSatisfy({
            $0.approachZone.widthMetres > 0 && $0.approachZone.depthMetres > 0
        }) else {
            return "Every Required Destination needs a usable Approach Zone."
        }
        guard turningZones.allSatisfy({
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.diameterMetres > 0
        }) else {
            return "Name every Turning Zone and give it a usable diameter."
        }
        let knownAccessPoints = Set(inventory.accessPointCandidates.map(\.id))
        guard accessPointIDs.isSubset(of: knownAccessPoints) else {
            return "One or more Access Points no longer exist in this capture."
        }
        return nil
    }
}
