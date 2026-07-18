import Foundation

struct FloorPoint: Hashable, Sendable {
    let x: Double
    let z: Double

    func distance(to other: FloorPoint) -> Double {
        hypot(x - other.x, z - other.z)
    }
}

struct FloorPolygon: Equatable, Sendable {
    let points: [FloorPoint]

    var centre: FloorPoint {
        guard !points.isEmpty else { return FloorPoint(x: 0, z: 0) }
        return FloorPoint(
            x: points.map(\.x).reduce(0, +) / Double(points.count),
            z: points.map(\.z).reduce(0, +) / Double(points.count)
        )
    }

    var bounds: (minX: Double, maxX: Double, minZ: Double, maxZ: Double)? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce((first.x, first.x, first.z, first.z)) { result, point in
            (min(result.0, point.x), max(result.1, point.x), min(result.2, point.z), max(result.3, point.z))
        }
    }

    func contains(_ point: FloorPoint) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false
        var previous = points.last!
        for current in points {
            let crosses = (current.z > point.z) != (previous.z > point.z)
                && point.x < (previous.x - current.x) * (point.z - current.z)
                    / ((previous.z - current.z) == 0 ? .leastNonzeroMagnitude : (previous.z - current.z))
                    + current.x
            if crosses { inside.toggle() }
            previous = current
        }
        return inside
    }
}

enum AnalysisOutcome: String, Codable, CaseIterable, Sendable {
    case meetsNeed
    case doesNotMeetNeed
    case needsVerification

    var title: String {
        switch self {
        case .meetsNeed: "Meets Need"
        case .doesNotMeetNeed: "Does Not Meet Need"
        case .needsVerification: "Needs Verification"
        }
    }

    var symbolName: String {
        switch self {
        case .meetsNeed: "checkmark.circle.fill"
        case .doesNotMeetNeed: "xmark.octagon.fill"
        case .needsVerification: "questionmark.diamond.fill"
        }
    }
}

enum AssessmentRequirementKind: String, Codable, Sendable {
    case accessPoint
    case requiredDestination
    case turningZone
    case customMobilityNeed
}

struct AssessmentRoute: Identifiable, Equatable, Sendable {
    let id: String
    let accessPointID: String
    let targetID: String
    let points: [FloorPoint]
    let limitingClearanceMetres: Double?
    let outcome: AnalysisOutcome
}

struct AssessmentFinding: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let details: String
    let outcome: AnalysisOutcome
    let location: FloorPoint?
}

struct AssessmentRequirementResult: Identifiable, Equatable, Sendable {
    let id: String
    let kind: AssessmentRequirementKind
    let title: String
    let priority: MobilityNeedPriority
    let outcome: AnalysisOutcome
    let summary: String
    let routes: [AssessmentRoute]
    let findings: [AssessmentFinding]
    let focusPolygons: [FloorPolygon]
}

enum ArrangementStatus: String, Codable, Sendable {
    case doesNotSupportEssentialNeeds
    case needsVerification
    case supportsEssentialNeeds

    var title: String {
        switch self {
        case .doesNotSupportEssentialNeeds: "Does Not Support Essential Needs"
        case .needsVerification: "Needs Verification"
        case .supportsEssentialNeeds: "Supports Essential Needs"
        }
    }
}

struct LayoutScore: Equatable, Sendable {
    let lowerBound: Int
    let upperBound: Int

    var isProvisional: Bool { lowerBound != upperBound }
    var displayValue: String {
        isProvisional ? "\(lowerBound)–\(upperBound)" : "\(lowerBound)"
    }
}

struct AssessmentMapModel: Equatable, Sendable {
    struct LabelledPolygon: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let polygon: FloorPolygon
    }

    let floor: FloorPolygon
    let obstacles: [LabelledPolygon]
    let accessPoints: [LabelledPolygon]
    let zones: [LabelledPolygon]
}

struct AssessmentResult: Equatable, Sendable {
    let engineVersion: String
    let status: ArrangementStatus
    let score: LayoutScore
    let determinedRequirementCount: Int
    let totalRequirementCount: Int
    let requirements: [AssessmentRequirementResult]
    let map: AssessmentMapModel

    var coverageDescription: String {
        "\(determinedRequirementCount) of \(totalRequirementCount) requirements determined"
    }
}

enum AssessmentEngineError: LocalizedError, Sendable {
    case setupDoesNotMatchRoom
    case roomSetupNotConfirmed

    var errorDescription: String? {
        switch self {
        case .setupDoesNotMatchRoom:
            "The confirmed Room Setup does not belong to this Accepted Room."
        case .roomSetupNotConfirmed:
            "Confirm the Room Setup before running the assessment."
        }
    }
}

struct AssessmentEngine {
    static let engineVersion = "barebones-1"
    static let measurementToleranceMetres = 0.05
    static let preferredGridSizeMetres = 0.05

    func assess(
        room: CapturedRoomArtifact,
        profile: MobilityProfile,
        setup: RoomSetup
    ) throws -> AssessmentResult {
        guard setup.roomID == room.id else { throw AssessmentEngineError.setupDoesNotMatchRoom }
        guard setup.isConfirmed else { throw AssessmentEngineError.roomSetupNotConfirmed }

        let data = try Data(contentsOf: room.jsonURL)
        let document = try JSONDecoder().decode(RoomPlanDocument.self, from: data)
        let spatialRoom = SpatialRoom(document: document, setup: setup, profile: profile)
        let grid = NavigationGrid(room: spatialRoom)

        var requirements: [AssessmentRequirementResult] = []
        var accessOutcomes: [String: AnalysisOutcome] = [:]

        for accessPoint in spatialRoom.accessPoints {
            let outcome = Self.classify(
                measured: accessPoint.width,
                required: spatialRoom.minimumPassageWidth,
                tolerance: Self.measurementToleranceMetres
            )
            accessOutcomes[accessPoint.id] = outcome
            let finding = outcome == .meetsNeed ? [] : [AssessmentFinding(
                id: "access-\(accessPoint.id)",
                title: "\(accessPoint.label) opening clearance",
                details: Self.measurementExplanation(
                    measured: accessPoint.width,
                    required: spatialRoom.minimumPassageWidth,
                    outcome: outcome
                ),
                outcome: outcome,
                location: accessPoint.polygon.centre
            )]
            requirements.append(AssessmentRequirementResult(
                id: "access-\(accessPoint.id)",
                kind: .accessPoint,
                title: accessPoint.label,
                priority: .essential,
                outcome: outcome,
                summary: Self.measurementExplanation(
                    measured: accessPoint.width,
                    required: spatialRoom.minimumPassageWidth,
                    outcome: outcome
                ),
                routes: [],
                findings: finding,
                focusPolygons: [accessPoint.polygon]
            ))
        }

        for destination in spatialRoom.destinations {
            let zoneOutcome = spatialRoom.floorIsComplete
                ? spatialRoom.areaOutcome(for: destination.zone, excludingObstacleID: destination.objectID)
                : .needsVerification
            var routes: [AssessmentRoute] = []
            var findings: [AssessmentFinding] = []
            var componentOutcomes = [zoneOutcome]

            if zoneOutcome != .meetsNeed {
                findings.append(AssessmentFinding(
                    id: "zone-\(destination.id)",
                    title: "\(destination.label) Approach Zone",
                    details: zoneOutcome == .doesNotMeetNeed
                        ? "The required clear-floor area overlaps captured obstacles."
                        : "The required clear-floor area is within Measurement Tolerance or depends on incomplete captured evidence.",
                    outcome: zoneOutcome,
                    location: destination.zone.centre
                ))
            }

            for accessPoint in spatialRoom.accessPoints {
                let route: AssessmentRoute
                if accessOutcomes[accessPoint.id] != .meetsNeed {
                    let inherited = accessOutcomes[accessPoint.id] ?? .needsVerification
                    route = AssessmentRoute(
                        id: "route-\(accessPoint.id)-\(destination.id)",
                        accessPointID: accessPoint.id,
                        targetID: destination.id,
                        points: [],
                        limitingClearanceMetres: accessPoint.width,
                        outcome: inherited
                    )
                } else if !spatialRoom.floorIsComplete {
                    route = AssessmentRoute(
                        id: "route-\(accessPoint.id)-\(destination.id)",
                        accessPointID: accessPoint.id,
                        targetID: destination.id,
                        points: [],
                        limitingClearanceMetres: nil,
                        outcome: .needsVerification
                    )
                } else {
                    route = grid.widestRoute(
                        from: accessPoint.polygon.centre,
                        to: destination.zone,
                        accessPointID: accessPoint.id,
                        targetID: destination.id,
                        requiredWidth: spatialRoom.minimumPassageWidth
                    )
                }
                routes.append(route)
                componentOutcomes.append(route.outcome)
                if route.outcome != .meetsNeed, accessOutcomes[accessPoint.id] == .meetsNeed {
                    findings.append(AssessmentFinding(
                        id: route.id,
                        title: "Route from \(accessPoint.label) to \(destination.label)",
                        details: route.limitingClearanceMetres.map {
                            Self.measurementExplanation(
                                measured: $0,
                                required: spatialRoom.minimumPassageWidth,
                                outcome: route.outcome
                            )
                        } ?? "Captured evidence is insufficient to establish a Suitable Route.",
                        outcome: route.outcome,
                        location: route.points.isEmpty ? nil : route.points[route.points.count / 2]
                    ))
                }
            }

            let outcome = Self.aggregate(componentOutcomes)
            requirements.append(AssessmentRequirementResult(
                id: destination.id,
                kind: .requiredDestination,
                title: destination.label,
                priority: destination.priority,
                outcome: outcome,
                summary: Self.destinationSummary(outcome: outcome, routeCount: routes.count),
                routes: routes,
                findings: findings,
                focusPolygons: [destination.zone]
            ))
        }

        for turningZone in spatialRoom.turningZones {
            let zoneOutcome = spatialRoom.floorIsComplete
                ? spatialRoom.areaOutcome(for: turningZone.polygon, excludingObstacleID: nil)
                : .needsVerification
            var componentOutcomes = [zoneOutcome]
            var routes: [AssessmentRoute] = []
            var findings: [AssessmentFinding] = []

            for accessPoint in spatialRoom.accessPoints {
                let route: AssessmentRoute
                if accessOutcomes[accessPoint.id] != .meetsNeed {
                    route = AssessmentRoute(
                        id: "route-\(accessPoint.id)-\(turningZone.id)",
                        accessPointID: accessPoint.id,
                        targetID: turningZone.id,
                        points: [],
                        limitingClearanceMetres: accessPoint.width,
                        outcome: accessOutcomes[accessPoint.id] ?? .needsVerification
                    )
                } else if spatialRoom.floorIsComplete {
                    route = grid.widestRoute(
                        from: accessPoint.polygon.centre,
                        to: turningZone.polygon,
                        accessPointID: accessPoint.id,
                        targetID: turningZone.id,
                        requiredWidth: spatialRoom.minimumPassageWidth
                    )
                } else {
                    route = AssessmentRoute(
                        id: "route-\(accessPoint.id)-\(turningZone.id)",
                        accessPointID: accessPoint.id,
                        targetID: turningZone.id,
                        points: [],
                        limitingClearanceMetres: nil,
                        outcome: .needsVerification
                    )
                }
                routes.append(route)
                componentOutcomes.append(route.outcome)
            }

            if zoneOutcome != .meetsNeed {
                findings.append(AssessmentFinding(
                    id: "turning-clearance-\(turningZone.id)",
                    title: "\(turningZone.label) clearance",
                    details: zoneOutcome == .doesNotMeetNeed
                        ? "The required turning circle overlaps captured obstacles or leaves the captured floor boundary."
                        : "Turning clearance depends on incomplete or tolerance-boundary evidence.",
                    outcome: zoneOutcome,
                    location: turningZone.polygon.centre
                ))
            }

            let outcome = Self.aggregate(componentOutcomes)
            requirements.append(AssessmentRequirementResult(
                id: turningZone.id,
                kind: .turningZone,
                title: turningZone.label,
                priority: .essential,
                outcome: outcome,
                summary: outcome == .meetsNeed
                    ? "The complete turning area is clear and reachable from every Access Point."
                    : "Turning clearance or reachability requires attention.",
                routes: routes,
                findings: findings,
                focusPolygons: [turningZone.polygon]
            ))
        }

        for need in profile.customNeeds {
            requirements.append(AssessmentRequirementResult(
                id: "custom-\(need.id.uuidString)",
                kind: .customMobilityNeed,
                title: need.title,
                priority: need.priority,
                outcome: .needsVerification,
                summary: "This free-text need has no structured measurement rule and requires Guided Verification.",
                routes: [],
                findings: [AssessmentFinding(
                    id: "custom-\(need.id.uuidString)",
                    title: need.title,
                    details: need.details.isEmpty
                        ? "A measurable rule or explicit Operator Verification is required."
                        : need.details,
                    outcome: .needsVerification,
                    location: nil
                )],
                focusPolygons: []
            ))
        }

        let status = Self.status(for: requirements)
        let score = Self.score(for: requirements)
        let determined = requirements.filter { $0.outcome != .needsVerification }.count
        return AssessmentResult(
            engineVersion: Self.engineVersion,
            status: status,
            score: score,
            determinedRequirementCount: determined,
            totalRequirementCount: requirements.count,
            requirements: requirements,
            map: spatialRoom.mapModel
        )
    }

    static func classify(measured: Double, required: Double, tolerance: Double) -> AnalysisOutcome {
        let epsilon = 0.000_001
        if measured - tolerance + epsilon >= required { return .meetsNeed }
        if measured + tolerance < required - epsilon { return .doesNotMeetNeed }
        return .needsVerification
    }

    static func aggregate(_ outcomes: [AnalysisOutcome]) -> AnalysisOutcome {
        if outcomes.contains(.doesNotMeetNeed) { return .doesNotMeetNeed }
        if outcomes.contains(.needsVerification) { return .needsVerification }
        return .meetsNeed
    }

    static func status(for requirements: [AssessmentRequirementResult]) -> ArrangementStatus {
        let essential = requirements.filter { $0.priority == .essential }
        if essential.contains(where: { $0.outcome == .doesNotMeetNeed }) {
            return .doesNotSupportEssentialNeeds
        }
        if essential.contains(where: { $0.outcome == .needsVerification }) {
            return .needsVerification
        }
        return .supportsEssentialNeeds
    }

    static func score(for requirements: [AssessmentRequirementResult]) -> LayoutScore {
        let essential = requirements.filter { $0.priority == .essential }
        let preferences = requirements.filter { $0.priority == .preference }
        let essentialPool = preferences.isEmpty ? 100.0 : 80.0
        let preferencePool = preferences.isEmpty ? 0.0 : 20.0

        func bounds(for group: [AssessmentRequirementResult], pool: Double) -> (Double, Double) {
            guard !group.isEmpty else { return (0, 0) }
            let weight = pool / Double(group.count)
            let lower = Double(group.filter { $0.outcome == .meetsNeed }.count) * weight
            let upper = Double(group.filter { $0.outcome != .doesNotMeetNeed }.count) * weight
            return (lower, upper)
        }

        let essentialBounds = bounds(for: essential, pool: essentialPool)
        let preferenceBounds = bounds(for: preferences, pool: preferencePool)
        return LayoutScore(
            lowerBound: Int((essentialBounds.0 + preferenceBounds.0).rounded()),
            upperBound: Int((essentialBounds.1 + preferenceBounds.1).rounded())
        )
    }

    private static func measurementExplanation(
        measured: Double,
        required: Double,
        outcome: AnalysisOutcome
    ) -> String {
        let measuredText = measured.formatted(.number.precision(.fractionLength(2)))
        let requiredText = required.formatted(.number.precision(.fractionLength(2)))
        return "Captured clearance is \(measuredText) m; required clearance is \(requiredText) m with ±5 cm Measurement Tolerance. \(outcome.title)."
    }

    private static func destinationSummary(outcome: AnalysisOutcome, routeCount: Int) -> String {
        switch outcome {
        case .meetsNeed:
            "The Approach Zone is clear and all \(routeCount) required routes meet the configured passage requirement."
        case .doesNotMeetNeed:
            "At least one required route or the complete Approach Zone does not meet the configured requirement."
        case .needsVerification:
            "No confirmed failure was found, but at least one route or zone remains unresolved."
        }
    }
}

private struct SpatialRoom {
    struct SpatialElement {
        let id: String
        let label: String
        let width: Double
        let polygon: FloorPolygon
    }

    struct Destination {
        let id: String
        let objectID: String
        let label: String
        let priority: MobilityNeedPriority
        let zone: FloorPolygon
    }

    struct TurningZone {
        let id: String
        let label: String
        let polygon: FloorPolygon
    }

    struct Obstacle {
        enum Kind { case wall, object }
        let id: String
        let polygon: FloorPolygon
        let kind: Kind
    }

    let floor: FloorPolygon
    let floorIsComplete: Bool
    let obstacles: [Obstacle]
    let passages: [FloorPolygon]
    let accessPoints: [SpatialElement]
    let destinations: [Destination]
    let turningZones: [TurningZone]
    let minimumPassageWidth: Double
    let mapModel: AssessmentMapModel

    init(document: RoomPlanDocument, setup: RoomSetup, profile: MobilityProfile) {
        let floorElement = document.floors.first
        let resolvedFloor = floorElement.map(Self.floorPolygon) ?? FloorPolygon(points: [])
        floor = resolvedFloor
        floorIsComplete = resolvedFloor.points.count >= 3 && abs(Self.signedArea(resolvedFloor)) > 0.25
        minimumPassageWidth = profile.measurements.minimumPassageWidthCentimetres / 100

        let doorsAndOpenings = document.doors + document.openings
        passages = doorsAndOpenings.map { Self.rectangle(for: $0, depthOverride: 0.30) }
        accessPoints = doorsAndOpenings
            .filter { setup.accessPointIDs.contains($0.identifier) }
            .map {
                SpatialElement(
                    id: $0.identifier,
                    label: Self.label(for: $0, fallback: "Access Point"),
                    width: $0.dimensions.first ?? 0,
                    polygon: Self.rectangle(for: $0, depthOverride: 0.18)
                )
            }

        let wallObstacles = document.walls
            .filter { setup.architecturalFeatureIDs.contains($0.identifier) }
            .map {
                Obstacle(
                    id: $0.identifier,
                    polygon: Self.rectangle(for: $0, depthOverride: 0.08),
                    kind: .wall
                )
            }
        let includedObjectIDs = Set(setup.objects.filter(\.isIncluded).map(\.id))
        let objectElements = Dictionary(uniqueKeysWithValues: document.objects.map { ($0.identifier, $0) })
        let objectObstacles = document.objects
            .filter { includedObjectIDs.contains($0.identifier) }
            .map {
                Obstacle(id: $0.identifier, polygon: Self.rectangle(for: $0), kind: .object)
            }
        obstacles = wallObstacles + objectObstacles

        let approachWidth = profile.measurements.clearFloorSpaceWidthCentimetres / 100
        let approachDepth = profile.measurements.clearFloorSpaceDepthCentimetres / 100
        destinations = setup.objects.compactMap { objectSetup in
            guard objectSetup.isIncluded,
                  objectSetup.isRequiredDestination,
                  let element = objectElements[objectSetup.id]
            else { return nil }
            let objectPolygon = Self.rectangle(for: element)
            return Destination(
                id: "destination-\(objectSetup.id)",
                objectID: objectSetup.id,
                label: Self.label(for: element, fallback: "Required Destination"),
                priority: objectSetup.destinationPriority == .essential ? .essential : .preference,
                zone: Self.approachZone(
                    beside: objectPolygon,
                    side: objectSetup.approachZone.side,
                    width: approachWidth,
                    depth: approachDepth
                )
            )
        }

        let turningDiameter = profile.measurements.turningSpaceDiameterCentimetres / 100
        turningZones = setup.turningZones.map { zone in
            TurningZone(
                id: "turning-\(zone.id.uuidString)",
                label: zone.name,
                polygon: Self.circle(
                    centre: FloorPoint(x: zone.centreXMetres, z: zone.centreZMetres),
                    radius: turningDiameter / 2
                )
            )
        }

        mapModel = AssessmentMapModel(
            floor: resolvedFloor,
            obstacles: obstacles.map {
                AssessmentMapModel.LabelledPolygon(id: $0.id, label: "Obstacle", polygon: $0.polygon)
            },
            accessPoints: accessPoints.map {
                AssessmentMapModel.LabelledPolygon(id: $0.id, label: $0.label, polygon: $0.polygon)
            },
            zones: destinations.map {
                AssessmentMapModel.LabelledPolygon(id: $0.id, label: $0.label, polygon: $0.zone)
            } + turningZones.map {
                AssessmentMapModel.LabelledPolygon(id: $0.id, label: $0.label, polygon: $0.polygon)
            }
        )
    }

    func isBlocked(_ point: FloorPoint, excludingObstacleID: String? = nil) -> Bool {
        guard floor.contains(point) else { return true }
        for obstacle in obstacles where obstacle.id != excludingObstacleID {
            guard obstacle.polygon.contains(point) else { continue }
            if obstacle.kind == .wall, passages.contains(where: { $0.contains(point) }) {
                continue
            }
            return true
        }
        return false
    }

    func areaOutcome(for polygon: FloorPolygon, excludingObstacleID: String?) -> AnalysisOutcome {
        let expanded = Self.scaled(polygon, by: AssessmentEngine.measurementToleranceMetres)
        if areaIsClear(expanded, excludingObstacleID: excludingObstacleID) { return .meetsNeed }
        let inset = Self.scaled(polygon, by: -AssessmentEngine.measurementToleranceMetres)
        if !areaIsClear(inset, excludingObstacleID: excludingObstacleID) { return .doesNotMeetNeed }
        return .needsVerification
    }

    private func areaIsClear(_ polygon: FloorPolygon, excludingObstacleID: String?) -> Bool {
        guard polygon.points.allSatisfy(floor.contains) else { return false }
        for obstacle in obstacles where obstacle.id != excludingObstacleID {
            if Self.polygonsIntersect(polygon, obstacle.polygon) {
                if obstacle.kind == .wall,
                   polygon.points.allSatisfy({ point in passages.contains(where: { $0.contains(point) }) }) {
                    continue
                }
                return false
            }
        }
        return true
    }

    private static func label(for element: RoomPlanDocument.Element, fallback: String) -> String {
        (element.category.keys.first ?? fallback)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private static func floorPolygon(_ element: RoomPlanDocument.Element) -> FloorPolygon {
        let points = element.polygonCorners.compactMap { corner -> FloorPoint? in
            guard corner.count >= 3 else { return nil }
            return transform(point: corner, with: element.transform)
        }
        return FloorPolygon(points: points)
    }

    private static func rectangle(
        for element: RoomPlanDocument.Element,
        depthOverride: Double? = nil
    ) -> FloorPolygon {
        let width = max(element.dimensions.first ?? 0.05, 0.02)
        let rawDepth = element.dimensions.count > 2 ? element.dimensions[2] : 0
        let depth = max(depthOverride ?? rawDepth, 0.02)
        let local = [
            [-width / 2, 0, -depth / 2],
            [width / 2, 0, -depth / 2],
            [width / 2, 0, depth / 2],
            [-width / 2, 0, depth / 2],
        ]
        return FloorPolygon(points: local.map { transform(point: $0, with: element.transform) })
    }

    private static func transform(point: [Double], with matrix: [Double]) -> FloorPoint {
        guard matrix.count >= 16, point.count >= 3 else {
            return FloorPoint(x: point.first ?? 0, z: point.count > 2 ? point[2] : 0)
        }
        return FloorPoint(
            x: matrix[0] * point[0] + matrix[4] * point[1] + matrix[8] * point[2] + matrix[12],
            z: matrix[2] * point[0] + matrix[6] * point[1] + matrix[10] * point[2] + matrix[14]
        )
    }

    private static func approachZone(
        beside object: FloorPolygon,
        side: ApproachSide,
        width: Double,
        depth: Double
    ) -> FloorPolygon {
        guard object.points.count == 4 else { return FloorPolygon(points: []) }
        let centre = object.centre
        let widthAxis = normalized(from: object.points[0], to: object.points[1])
        let depthAxis = normalized(from: object.points[1], to: object.points[2])
        let objectWidth = object.points[0].distance(to: object.points[1])
        let objectDepth = object.points[1].distance(to: object.points[2])
        let outward: FloorPoint
        let tangent: FloorPoint
        let objectExtent: Double
        switch side {
        case .front:
            outward = depthAxis
            tangent = widthAxis
            objectExtent = objectDepth / 2
        case .back:
            outward = FloorPoint(x: -depthAxis.x, z: -depthAxis.z)
            tangent = widthAxis
            objectExtent = objectDepth / 2
        case .left:
            outward = FloorPoint(x: -widthAxis.x, z: -widthAxis.z)
            tangent = depthAxis
            objectExtent = objectWidth / 2
        case .right:
            outward = widthAxis
            tangent = depthAxis
            objectExtent = objectWidth / 2
        }
        let zoneCentre = FloorPoint(
            x: centre.x + outward.x * (objectExtent + depth / 2),
            z: centre.z + outward.z * (objectExtent + depth / 2)
        )
        return orientedRectangle(
            centre: zoneCentre,
            tangent: tangent,
            outward: outward,
            width: width,
            depth: depth
        )
    }

    private static func orientedRectangle(
        centre: FloorPoint,
        tangent: FloorPoint,
        outward: FloorPoint,
        width: Double,
        depth: Double
    ) -> FloorPolygon {
        let offsets = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)]
        return FloorPolygon(points: offsets.map { alongWidth, alongDepth in
            FloorPoint(
                x: centre.x + tangent.x * width * alongWidth + outward.x * depth * alongDepth,
                z: centre.z + tangent.z * width * alongWidth + outward.z * depth * alongDepth
            )
        })
    }

    private static func circle(centre: FloorPoint, radius: Double) -> FloorPolygon {
        FloorPolygon(points: (0..<32).map { index in
            let angle = Double(index) / 32 * 2 * Double.pi
            return FloorPoint(x: centre.x + cos(angle) * radius, z: centre.z + sin(angle) * radius)
        })
    }

    private static func normalized(from start: FloorPoint, to end: FloorPoint) -> FloorPoint {
        let length = max(start.distance(to: end), .leastNonzeroMagnitude)
        return FloorPoint(x: (end.x - start.x) / length, z: (end.z - start.z) / length)
    }

    private static func signedArea(_ polygon: FloorPolygon) -> Double {
        guard polygon.points.count >= 3 else { return 0 }
        return zip(polygon.points, polygon.points.dropFirst() + [polygon.points[0]])
            .reduce(0) { $0 + $1.0.x * $1.1.z - $1.1.x * $1.0.z } / 2
    }

    private static func scaled(_ polygon: FloorPolygon, by distance: Double) -> FloorPolygon {
        let centre = polygon.centre
        return FloorPolygon(points: polygon.points.map { point in
            let length = max(centre.distance(to: point), .leastNonzeroMagnitude)
            let scale = max(0.05, (length + distance) / length)
            return FloorPoint(
                x: centre.x + (point.x - centre.x) * scale,
                z: centre.z + (point.z - centre.z) * scale
            )
        })
    }

    private static func polygonsIntersect(_ lhs: FloorPolygon, _ rhs: FloorPolygon) -> Bool {
        if lhs.points.contains(where: rhs.contains) || rhs.points.contains(where: lhs.contains) {
            return true
        }
        let lhsEdges = edges(of: lhs)
        let rhsEdges = edges(of: rhs)
        return lhsEdges.contains { a in rhsEdges.contains { b in segmentsIntersect(a.0, a.1, b.0, b.1) } }
    }

    private static func edges(of polygon: FloorPolygon) -> [(FloorPoint, FloorPoint)] {
        guard let first = polygon.points.first else { return [] }
        return Array(zip(polygon.points, polygon.points.dropFirst() + [first]))
    }

    private static func segmentsIntersect(
        _ a: FloorPoint,
        _ b: FloorPoint,
        _ c: FloorPoint,
        _ d: FloorPoint
    ) -> Bool {
        func cross(_ p: FloorPoint, _ q: FloorPoint, _ r: FloorPoint) -> Double {
            (q.x - p.x) * (r.z - p.z) - (q.z - p.z) * (r.x - p.x)
        }
        let abC = cross(a, b, c)
        let abD = cross(a, b, d)
        let cdA = cross(c, d, a)
        let cdB = cross(c, d, b)
        return abC * abD <= 0 && cdA * cdB <= 0
    }
}

private struct NavigationGrid {
    struct Cell: Hashable { let column: Int; let row: Int }
    struct QueueEntry { let cell: Cell; let priority: Double }

    let room: SpatialRoom
    let cellSize: Double
    let minX: Double
    let minZ: Double
    let columns: Int
    let rows: Int
    let blocked: [Bool]
    let clearance: [Double]

    init(room: SpatialRoom) {
        self.room = room
        let bounds = room.floor.bounds ?? (0, 1, 0, 1)
        minX = bounds.minX
        minZ = bounds.minZ
        let width = max(bounds.maxX - bounds.minX, 0.1)
        let depth = max(bounds.maxZ - bounds.minZ, 0.1)
        cellSize = max(
            AssessmentEngine.preferredGridSizeMetres,
            sqrt(width * depth / 250_000)
        )
        columns = max(1, Int(ceil(width / cellSize)) + 1)
        rows = max(1, Int(ceil(depth / cellSize)) + 1)

        var blockedCells = Array(repeating: false, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let point = FloorPoint(
                    x: minX + (Double(column) + 0.5) * cellSize,
                    z: minZ + (Double(row) + 0.5) * cellSize
                )
                blockedCells[row * columns + column] = room.isBlocked(point)
            }
        }
        blocked = blockedCells
        clearance = Self.distanceField(
            blocked: blockedCells,
            columns: columns,
            rows: rows,
            cellSize: cellSize
        )
    }

    func widestRoute(
        from startPoint: FloorPoint,
        to target: FloorPolygon,
        accessPointID: String,
        targetID: String,
        requiredWidth: Double
    ) -> AssessmentRoute {
        guard let start = nearestFreeCell(to: startPoint) else {
            return unresolvedRoute(accessPointID: accessPointID, targetID: targetID)
        }
        let goals = allFreeCells(in: target)
        guard !goals.isEmpty else {
            return unresolvedRoute(accessPointID: accessPointID, targetID: targetID)
        }

        var capacity = Array(repeating: -Double.infinity, count: columns * rows)
        var distance = Array(repeating: Double.infinity, count: columns * rows)
        var previous: [Cell: Cell] = [:]
        var queue = MaxHeap()
        let startIndex = index(start)
        capacity[startIndex] = clearance[startIndex] * 2
        distance[startIndex] = 0
        queue.push(QueueEntry(cell: start, priority: capacity[startIndex]))
        let goalSet = Set(goals)
        var reachedGoal: Cell?

        while let current = queue.pop() {
            if goalSet.contains(current.cell) {
                reachedGoal = current.cell
                break
            }
            let currentIndex = index(current.cell)
            if current.priority + 0.0001 < capacity[currentIndex] { continue }
            for (neighbor, stepDistance) in neighbors(of: current.cell) {
                let neighborIndex = index(neighbor)
                guard !blocked[neighborIndex] else { continue }
                let candidateCapacity = min(capacity[currentIndex], clearance[neighborIndex] * 2)
                let candidateDistance = distance[currentIndex] + stepDistance
                if candidateCapacity > capacity[neighborIndex] + 0.0001
                    || (abs(candidateCapacity - capacity[neighborIndex]) <= 0.0001
                        && candidateDistance < distance[neighborIndex]) {
                    capacity[neighborIndex] = candidateCapacity
                    distance[neighborIndex] = candidateDistance
                    previous[neighbor] = current.cell
                    queue.push(QueueEntry(cell: neighbor, priority: candidateCapacity))
                }
            }
        }

        guard let goal = reachedGoal else {
            return AssessmentRoute(
                id: "route-\(accessPointID)-\(targetID)",
                accessPointID: accessPointID,
                targetID: targetID,
                points: [],
                limitingClearanceMetres: 0,
                outcome: .doesNotMeetNeed
            )
        }

        var cells = [goal]
        var cursor = goal
        while cursor != start, let parent = previous[cursor] {
            cells.append(parent)
            cursor = parent
        }
        cells.reverse()
        let measured = max(0, capacity[index(goal)] - cellSize)
        return AssessmentRoute(
            id: "route-\(accessPointID)-\(targetID)",
            accessPointID: accessPointID,
            targetID: targetID,
            points: cells.map(point(for:)),
            limitingClearanceMetres: measured,
            outcome: AssessmentEngine.classify(
                measured: measured,
                required: requiredWidth,
                tolerance: AssessmentEngine.measurementToleranceMetres
            )
        )
    }

    private func unresolvedRoute(accessPointID: String, targetID: String) -> AssessmentRoute {
        AssessmentRoute(
            id: "route-\(accessPointID)-\(targetID)",
            accessPointID: accessPointID,
            targetID: targetID,
            points: [],
            limitingClearanceMetres: nil,
            outcome: .needsVerification
        )
    }

    private func nearestFreeCell(to point: FloorPoint) -> Cell? {
        let baseColumn = Int((point.x - minX) / cellSize)
        let baseRow = Int((point.z - minZ) / cellSize)
        for radius in 0...10 {
            var candidates: [(Cell, Double)] = []
            for row in (baseRow - radius)...(baseRow + radius) {
                for column in (baseColumn - radius)...(baseColumn + radius) {
                    guard column >= 0, row >= 0, column < columns, row < rows else { continue }
                    let cell = Cell(column: column, row: row)
                    guard !blocked[index(cell)] else { continue }
                    candidates.append((cell, self.point(for: cell).distance(to: point)))
                }
            }
            if let best = candidates.min(by: { $0.1 < $1.1 }) { return best.0 }
        }
        return nil
    }

    private func allFreeCells(in polygon: FloorPolygon) -> [Cell] {
        guard let bounds = polygon.bounds else { return [] }
        let minColumn = max(0, Int((bounds.minX - minX) / cellSize) - 1)
        let maxColumn = min(columns - 1, Int((bounds.maxX - minX) / cellSize) + 1)
        let minRow = max(0, Int((bounds.minZ - minZ) / cellSize) - 1)
        let maxRow = min(rows - 1, Int((bounds.maxZ - minZ) / cellSize) + 1)
        var result: [Cell] = []
        for row in minRow...maxRow {
            for column in minColumn...maxColumn {
                let cell = Cell(column: column, row: row)
                if !blocked[index(cell)], polygon.contains(point(for: cell)) { result.append(cell) }
            }
        }
        return result
    }

    private func neighbors(of cell: Cell) -> [(Cell, Double)] {
        var result: [(Cell, Double)] = []
        for rowOffset in -1...1 {
            for columnOffset in -1...1 where rowOffset != 0 || columnOffset != 0 {
                let neighbor = Cell(column: cell.column + columnOffset, row: cell.row + rowOffset)
                guard neighbor.column >= 0, neighbor.row >= 0,
                      neighbor.column < columns, neighbor.row < rows else { continue }
                if rowOffset != 0, columnOffset != 0 {
                    let horizontal = Cell(column: cell.column + columnOffset, row: cell.row)
                    let vertical = Cell(column: cell.column, row: cell.row + rowOffset)
                    guard !blocked[index(horizontal)], !blocked[index(vertical)] else { continue }
                }
                result.append((neighbor, hypot(Double(columnOffset), Double(rowOffset)) * cellSize))
            }
        }
        return result
    }

    private func index(_ cell: Cell) -> Int { cell.row * columns + cell.column }

    private func point(for cell: Cell) -> FloorPoint {
        FloorPoint(
            x: minX + (Double(cell.column) + 0.5) * cellSize,
            z: minZ + (Double(cell.row) + 0.5) * cellSize
        )
    }

    private static func distanceField(
        blocked: [Bool],
        columns: Int,
        rows: Int,
        cellSize: Double
    ) -> [Double] {
        let infinity = Double.infinity
        var distance = blocked.map { $0 ? 0 : infinity }
        let diagonal = sqrt(2.0) * cellSize
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                guard distance[index] != 0 else { continue }
                if column > 0 { distance[index] = min(distance[index], distance[index - 1] + cellSize) }
                if row > 0 { distance[index] = min(distance[index], distance[index - columns] + cellSize) }
                if column > 0, row > 0 {
                    distance[index] = min(distance[index], distance[index - columns - 1] + diagonal)
                }
                if column + 1 < columns, row > 0 {
                    distance[index] = min(distance[index], distance[index - columns + 1] + diagonal)
                }
            }
        }
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                let index = row * columns + column
                guard distance[index] != 0 else { continue }
                if column + 1 < columns { distance[index] = min(distance[index], distance[index + 1] + cellSize) }
                if row + 1 < rows { distance[index] = min(distance[index], distance[index + columns] + cellSize) }
                if column + 1 < columns, row + 1 < rows {
                    distance[index] = min(distance[index], distance[index + columns + 1] + diagonal)
                }
                if column > 0, row + 1 < rows {
                    distance[index] = min(distance[index], distance[index + columns - 1] + diagonal)
                }
            }
        }
        return distance
    }

    private struct MaxHeap {
        private var entries: [QueueEntry] = []

        mutating func push(_ entry: QueueEntry) {
            entries.append(entry)
            var index = entries.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard entries[index].priority > entries[parent].priority else { break }
                entries.swapAt(index, parent)
                index = parent
            }
        }

        mutating func pop() -> QueueEntry? {
            guard !entries.isEmpty else { return nil }
            if entries.count == 1 { return entries.removeLast() }
            let result = entries[0]
            entries[0] = entries.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                let right = left + 1
                var largest = index
                if left < entries.count, entries[left].priority > entries[largest].priority { largest = left }
                if right < entries.count, entries[right].priority > entries[largest].priority { largest = right }
                guard largest != index else { break }
                entries.swapAt(index, largest)
                index = largest
            }
            return result
        }
    }
}
