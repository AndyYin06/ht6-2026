import Foundation

enum MobilityNeedPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case essential
    case preference

    var id: String { rawValue }
}

struct CustomMobilityNeed: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var title: String
    var details: String
    var priority: MobilityNeedPriority
}

struct MobilityMeasurements: Codable, Equatable, Sendable {
    var minimumPassageWidthCentimetres: Double
    var turningSpaceDiameterCentimetres: Double
    var clearFloorSpaceWidthCentimetres: Double
    var clearFloorSpaceDepthCentimetres: Double
}

struct ProfileTemplateReference: Codable, Equatable, Sendable {
    let name: String
    let source: String
    let jurisdiction: String
    let version: String
    let sections: String
    let sourceURL: URL
}

struct MobilityProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var revision: Int
    var occupantName: String
    var measurements: MobilityMeasurements
    var customNeeds: [CustomMobilityNeed]
    var templateReference: ProfileTemplateReference?
    var modifiedAt: Date

    var isComplete: Bool {
        !occupantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && measurements.minimumPassageWidthCentimetres > 0
            && measurements.turningSpaceDiameterCentimetres > 0
            && measurements.clearFloorSpaceWidthCentimetres > 0
            && measurements.clearFloorSpaceDepthCentimetres > 0
            && !customNeeds.contains {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    static func customDraft(from profile: MobilityProfile? = nil) -> MobilityProfile {
        profile ?? MobilityProfile(
            id: UUID(),
            revision: 0,
            occupantName: "",
            measurements: MobilityMeasurements(
                minimumPassageWidthCentimetres: 90,
                turningSpaceDiameterCentimetres: 150,
                clearFloorSpaceWidthCentimetres: 75,
                clearFloorSpaceDepthCentimetres: 120
            ),
            customNeeds: [],
            templateReference: nil,
            modifiedAt: Date()
        )
    }

    static func adaDemonstrationDraft(occupantName: String = "") -> MobilityProfile {
        MobilityProfile(
            id: UUID(),
            revision: 0,
            occupantName: occupantName,
            measurements: MobilityMeasurements(
                minimumPassageWidthCentimetres: 91.5,
                turningSpaceDiameterCentimetres: 152.5,
                clearFloorSpaceWidthCentimetres: 76,
                clearFloorSpaceDepthCentimetres: 122
            ),
            customNeeds: [],
            templateReference: ProfileTemplateReference(
                name: "2010 ADA demonstration starting point",
                source: "U.S. Department of Justice, 2010 ADA Standards for Accessible Design",
                jurisdiction: "United States federal accessibility standards",
                version: "2010 Standards",
                sections: "§403.5.1 clear width; §304.3.1 circular turning space; §305.3 clear floor space",
                sourceURL: URL(string: "https://www.ada.gov/law-and-regs/design-standards/2010-stds/")!
            ),
            modifiedAt: Date()
        )
    }
}

struct MobilityProfileConfirmation: Codable, Equatable {
    let profileID: UUID
    let revision: Int
    let confirmedAt: Date
}
