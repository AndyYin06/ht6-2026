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

struct ProposedPlacementGeometry {
    static func polygon(
        _ polygon: FloorPolygon,
        applying change: ProposedObjectChange?,
        around rotationCentre: FloorPoint? = nil
    ) -> FloorPolygon {
        guard let change, change.hasEffect else { return polygon }
        let centre = rotationCentre ?? polygon.centre
        let cosine = cos(change.rotationRadians)
        let sine = sin(change.rotationRadians)
        return FloorPolygon(points: polygon.points.map { point in
            let localX = point.x - centre.x
            let localZ = point.z - centre.z
            return FloorPoint(
                x: centre.x + localX * cosine - localZ * sine + change.translationXMetres,
                z: centre.z + localX * sine + localZ * cosine + change.translationZMetres
            )
        })
    }

    static func translated(
        _ polygon: FloorPolygon,
        by translation: FloorPoint
    ) -> FloorPolygon {
        FloorPolygon(points: polygon.points.map {
            FloorPoint(x: $0.x + translation.x, z: $0.z + translation.z)
        })
    }

    static func constrainedTranslation(
        for objectID: String,
        requested: FloorPoint,
        map: AssessmentMapModel,
        arrangement: ProposedArrangement
    ) -> FloorPoint {
        guard arrangement.change(for: objectID)?.isRemoved != true,
              let observedObject = map.obstacles.first(where: { $0.id == objectID })
        else { return FloorPoint(x: 0, z: 0) }

        let object = polygon(observedObject.polygon, applying: arrangement.change(for: objectID))
        let blockingPolygons = map.obstacles.compactMap { obstacle -> FloorPolygon? in
            guard obstacle.id != objectID,
                  arrangement.change(for: obstacle.id)?.isRemoved != true
            else { return nil }
            return polygon(obstacle.polygon, applying: arrangement.change(for: obstacle.id))
        }

        var accepted = FloorPoint(x: 0, z: 0)
        var current = object
        let components = abs(requested.x) >= abs(requested.z)
            ? [FloorPoint(x: requested.x, z: 0), FloorPoint(x: 0, z: requested.z)]
            : [FloorPoint(x: 0, z: requested.z), FloorPoint(x: requested.x, z: 0)]

        for component in components {
            let allowed = allowedTranslation(
                for: current,
                requested: component,
                floor: map.floor,
                obstacles: blockingPolygons
            )
            accepted = FloorPoint(x: accepted.x + allowed.x, z: accepted.z + allowed.z)
            current = translated(current, by: allowed)
        }
        return accepted
    }

    private static func allowedTranslation(
        for polygon: FloorPolygon,
        requested: FloorPoint,
        floor: FloorPolygon,
        obstacles: [FloorPolygon]
    ) -> FloorPoint {
        let distance = hypot(requested.x, requested.z)
        guard distance > 0.000_001 else { return FloorPoint(x: 0, z: 0) }

        let startsValid = placementIsValid(polygon, floor: floor, obstacles: obstacles)
        let steps = max(1, Int(ceil(distance / 0.02)))
        var lastValidFraction = startsValid ? 0.0 : nil

        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            let candidate = translated(
                polygon,
                by: FloorPoint(x: requested.x * fraction, z: requested.z * fraction)
            )
            if placementIsValid(candidate, floor: floor, obstacles: obstacles) {
                lastValidFraction = fraction
                continue
            }

            guard let lastValidFraction else { continue }
            var lower = lastValidFraction
            var upper = fraction
            for _ in 0..<18 {
                let midpoint = (lower + upper) / 2
                let midpointPolygon = translated(
                    polygon,
                    by: FloorPoint(x: requested.x * midpoint, z: requested.z * midpoint)
                )
                if placementIsValid(midpointPolygon, floor: floor, obstacles: obstacles) {
                    lower = midpoint
                } else {
                    upper = midpoint
                }
            }
            return FloorPoint(x: requested.x * lower, z: requested.z * lower)
        }

        guard let lastValidFraction else { return FloorPoint(x: 0, z: 0) }
        return FloorPoint(
            x: requested.x * lastValidFraction,
            z: requested.z * lastValidFraction
        )
    }

    private static func placementIsValid(
        _ polygon: FloorPolygon,
        floor: FloorPolygon,
        obstacles: [FloorPolygon]
    ) -> Bool {
        polygon.points.allSatisfy(floor.contains)
            && !obstacles.contains(where: { polygonsIntersect(polygon, $0) })
    }

    private static func polygonsIntersect(_ lhs: FloorPolygon, _ rhs: FloorPolygon) -> Bool {
        if lhs.points.contains(where: rhs.contains) || rhs.points.contains(where: lhs.contains) {
            return true
        }
        let lhsEdges = edges(of: lhs)
        let rhsEdges = edges(of: rhs)
        return lhsEdges.contains { lhsEdge in
            rhsEdges.contains { rhsEdge in
                segmentsIntersect(lhsEdge.0, lhsEdge.1, rhsEdge.0, rhsEdge.1)
            }
        }
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
        func contains(_ point: FloorPoint, start: FloorPoint, end: FloorPoint) -> Bool {
            let epsilon = 0.000_001
            return point.x >= min(start.x, end.x) - epsilon
                && point.x <= max(start.x, end.x) + epsilon
                && point.z >= min(start.z, end.z) - epsilon
                && point.z <= max(start.z, end.z) + epsilon
        }

        let abC = cross(a, b, c)
        let abD = cross(a, b, d)
        let cdA = cross(c, d, a)
        let cdB = cross(c, d, b)
        let epsilon = 0.000_001
        if ((abC > epsilon && abD < -epsilon) || (abC < -epsilon && abD > epsilon)),
           ((cdA > epsilon && cdB < -epsilon) || (cdA < -epsilon && cdB > epsilon)) {
            return true
        }
        if abs(abC) <= epsilon, contains(c, start: a, end: b) { return true }
        if abs(abD) <= epsilon, contains(d, start: a, end: b) { return true }
        if abs(cdA) <= epsilon, contains(a, start: c, end: d) { return true }
        if abs(cdB) <= epsilon, contains(b, start: c, end: d) { return true }
        return false
    }
}
