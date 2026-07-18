import SwiftUI

struct AssessmentView: View {
    let room: CapturedRoomArtifact
    let profile: MobilityProfile
    let setup: RoomSetup
    let onClose: () -> Void

    @State private var result: AssessmentResult?
    @State private var selectedRequirementID: String?
    @State private var errorMessage: String?

    private var selectedRequirement: AssessmentRequirementResult? {
        result?.requirements.first { $0.id == selectedRequirementID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    assessment(result)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Unable to Assess Room",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Assessing Observed Arrangement…")
                }
            }
            .navigationTitle("Accessibility Assessment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left", action: onClose)
                }
            }
        }
        .task { await runAssessment() }
    }

    private func assessment(_ result: AssessmentResult) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                summary(result)
                AccessibilityMap(
                    map: result.map,
                    requirement: selectedRequirement
                )
                .frame(height: 330)
                .accessibilityLabel(mapAccessibilityLabel)

                Text("Assessment Requirements")
                    .font(.title2.bold())

                ForEach(result.requirements) { requirement in
                    RequirementCard(
                        requirement: requirement,
                        isSelected: requirement.id == selectedRequirementID
                    ) {
                        withAnimation { selectedRequirementID = requirement.id }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func summary(_ result: AssessmentResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(result.status.title, systemImage: statusSymbol(result.status))
                .font(.title2.bold())
                .foregroundStyle(statusColor(result.status))

            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading) {
                    Text("Layout Score")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(result.score.displayValue + " / 100")
                        .font(.title.bold())
                }
                VStack(alignment: .leading) {
                    Text("Evidence Coverage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(result.coverageDescription)
                        .font(.headline)
                }
            }

            if result.score.isProvisional {
                Label(
                    "The score is a range because unresolved requirements are not treated as passes or failures.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var mapAccessibilityLabel: String {
        guard let requirement = selectedRequirement else {
            return "Accessibility map of the captured room. Select a requirement to focus its zones and routes."
        }
        return "Accessibility map focused on \(requirement.title), outcome \(requirement.outcome.title), with \(requirement.routes.count) routes."
    }

    private func runAssessment() async {
        guard result == nil, errorMessage == nil else { return }
        do {
            let assessed = try await Task.detached(priority: .userInitiated) {
                try AssessmentEngine().assess(room: room, profile: profile, setup: setup)
            }.value
            result = assessed
            selectedRequirementID = assessed.requirements.first(where: { $0.outcome == .doesNotMeetNeed })?.id
                ?? assessed.requirements.first(where: { $0.outcome == .needsVerification })?.id
                ?? assessed.requirements.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func statusColor(_ status: ArrangementStatus) -> Color {
        switch status {
        case .supportsEssentialNeeds: .green
        case .doesNotSupportEssentialNeeds: .red
        case .needsVerification: .orange
        }
    }

    private func statusSymbol(_ status: ArrangementStatus) -> String {
        switch status {
        case .supportsEssentialNeeds: "checkmark.seal.fill"
        case .doesNotSupportEssentialNeeds: "xmark.seal.fill"
        case .needsVerification: "questionmark.diamond.fill"
        }
    }
}

private struct RequirementCard: View {
    let requirement: AssessmentRequirementResult
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Label(requirement.title, systemImage: requirement.outcome.symbolName)
                        .font(.headline)
                        .foregroundStyle(outcomeColor)
                    Spacer()
                    Text(requirement.priority == .essential ? "Essential" : "Preference")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }

                Text(requirement.summary)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                if isSelected {
                    if !requirement.routes.isEmpty {
                        Divider()
                        Text("Routes")
                            .font(.subheadline.bold())
                        ForEach(requirement.routes) { route in
                            Label(routeDescription(route), systemImage: route.outcome.symbolName)
                                .font(.footnote)
                                .foregroundStyle(color(for: route.outcome))
                        }
                    }
                    ForEach(requirement.findings) { finding in
                        Divider()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(finding.title).font(.subheadline.bold())
                            Text(finding.details).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? outcomeColor : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows this requirement's evidence and routes on the map")
    }

    private var outcomeColor: Color { color(for: requirement.outcome) }

    private func color(for outcome: AnalysisOutcome) -> Color {
        switch outcome {
        case .meetsNeed: .green
        case .doesNotMeetNeed: .red
        case .needsVerification: .orange
        }
    }

    private func routeDescription(_ route: AssessmentRoute) -> String {
        if let clearance = route.limitingClearanceMetres {
            return "From Access Point · limiting clearance \(clearance.formatted(.number.precision(.fractionLength(2)))) m · \(route.outcome.title)"
        }
        return "From Access Point · captured evidence incomplete · \(route.outcome.title)"
    }
}

private struct AccessibilityMap: View {
    let map: AssessmentMapModel
    let requirement: AssessmentRequirementResult?

    var body: some View {
        Canvas { context, size in
            let transform = MapTransform(
                points: allPoints,
                size: size,
                padding: 18
            )

            drawPolygon(map.floor, color: .secondary.opacity(0.12), stroke: .secondary, context: &context, transform: transform)
            for obstacle in map.obstacles {
                drawPolygon(obstacle.polygon, color: .gray.opacity(0.65), stroke: .gray, context: &context, transform: transform)
            }
            for accessPoint in map.accessPoints {
                drawPolygon(accessPoint.polygon, color: .blue.opacity(0.45), stroke: .blue, context: &context, transform: transform)
            }
            for zone in map.zones {
                drawPolygon(zone.polygon, color: .teal.opacity(0.18), stroke: .teal, context: &context, transform: transform)
            }
            for polygon in requirement?.focusPolygons ?? [] {
                drawPolygon(polygon, color: outcomeColor.opacity(0.22), stroke: outcomeColor, context: &context, transform: transform, lineWidth: 3)
            }
            for route in requirement?.routes ?? [] where route.points.count > 1 {
                var path = Path()
                path.move(to: transform.point(route.points[0]))
                for point in route.points.dropFirst() { path.addLine(to: transform.point(point)) }
                context.stroke(path, with: .color(color(for: route.outcome)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            Text(requirement.map { "Map focus: \($0.title)" } ?? "Accessibility Map")
                .font(.caption.bold())
                .padding(10)
        }
    }

    private var allPoints: [FloorPoint] {
        map.floor.points
            + map.obstacles.flatMap(\.polygon.points)
            + map.accessPoints.flatMap(\.polygon.points)
            + map.zones.flatMap(\.polygon.points)
            + (requirement?.routes.flatMap(\.points) ?? [])
    }

    private var outcomeColor: Color { color(for: requirement?.outcome ?? .needsVerification) }

    private func color(for outcome: AnalysisOutcome) -> Color {
        switch outcome {
        case .meetsNeed: .green
        case .doesNotMeetNeed: .red
        case .needsVerification: .orange
        }
    }

    private func drawPolygon(
        _ polygon: FloorPolygon,
        color: Color,
        stroke: Color,
        context: inout GraphicsContext,
        transform: MapTransform,
        lineWidth: CGFloat = 1
    ) {
        guard let first = polygon.points.first else { return }
        var path = Path()
        path.move(to: transform.point(first))
        for point in polygon.points.dropFirst() { path.addLine(to: transform.point(point)) }
        path.closeSubpath()
        context.fill(path, with: .color(color))
        context.stroke(path, with: .color(stroke), lineWidth: lineWidth)
    }
}

private struct MapTransform {
    let minX: Double
    let maxZ: Double
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat

    init(points: [FloorPoint], size: CGSize, padding: CGFloat) {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minZ = points.map(\.z).min() ?? 0
        let maxZ = points.map(\.z).max() ?? 1
        let width = max(maxX - minX, 0.1)
        let depth = max(maxZ - minZ, 0.1)
        let usableWidth = max(size.width - padding * 2, 1)
        let usableHeight = max(size.height - padding * 2, 1)
        scale = min(usableWidth / width, usableHeight / depth)
        offsetX = padding + (usableWidth - width * scale) / 2
        offsetY = padding + (usableHeight - depth * scale) / 2
        self.minX = minX
        self.maxZ = maxZ
    }

    func point(_ point: FloorPoint) -> CGPoint {
        CGPoint(
            x: offsetX + (point.x - minX) * scale,
            y: offsetY + (maxZ - point.z) * scale
        )
    }
}
