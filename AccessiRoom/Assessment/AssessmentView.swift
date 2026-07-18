import SwiftUI

struct AssessmentView: View {
    let room: CapturedRoomArtifact
    let profile: MobilityProfile
    let setup: RoomSetup
    @ObservedObject var store: AcceptedRoomStore
    let onClose: () -> Void

    @State private var result: AssessmentResult?
    @State private var comparison: ArrangementComparison?
    @State private var selectedRequirementID: String?
    @State private var selectedObjectID: String?
    @State private var arrangement: ProposedArrangement
    @State private var undoStack: [ProposedArrangement] = []
    @State private var redoStack: [ProposedArrangement] = []
    @State private var isAssessing = false
    @State private var errorMessage: String?

    private let movableObjects: [CapturedRoomInventory.Item]

    init(
        room: CapturedRoomArtifact,
        profile: MobilityProfile,
        setup: RoomSetup,
        store: AcceptedRoomStore,
        onClose: @escaping () -> Void
    ) {
        self.room = room
        self.profile = profile
        self.setup = setup
        self.store = store
        self.onClose = onClose
        let initial = store.proposedArrangement ?? .empty(roomID: room.id)
        _arrangement = State(initialValue: initial)
        let movableIDs = Set(setup.objects.filter { $0.isIncluded && $0.isMovable }.map(\.id))
        movableObjects = ((try? CapturedRoomInventory.load(from: room.jsonURL))?.objects ?? [])
            .filter { movableIDs.contains($0.id) }
        _selectedObjectID = State(initialValue: movableObjects.first?.id)
    }

    private var selectedRequirement: AssessmentRequirementResult? {
        result?.requirements.first { $0.id == selectedRequirementID }
    }

    private var selectedObservedRequirement: AssessmentRequirementResult? {
        comparison?.observed.requirements.first { $0.id == selectedRequirementID }
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
                    ProgressView("Assessing Arrangement…")
                }
            }
            .navigationTitle(arrangement.hasChanges ? "Proposed Arrangement" : "Observed Arrangement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left", action: onClose)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                        .disabled(undoStack.isEmpty)
                    Button("Redo", systemImage: "arrow.uturn.forward", action: redo)
                        .disabled(redoStack.isEmpty)
                }
            }
        }
        .task(id: arrangement) { await runAssessment(for: arrangement) }
        .alert("Unable to Save Proposed Arrangement", isPresented: Binding(
            get: { errorMessage != nil && result != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private func assessment(_ result: AssessmentResult) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                summary(result)
                if let comparison {
                    comparisonSection(comparison)
                } else {
                    AccessibilityMap(
                        map: result.map,
                        requirement: selectedRequirement
                    )
                    .frame(height: 330)
                    .accessibilityLabel(mapAccessibilityLabel)
                }

                proposalEditor

                if !result.conflicts.isEmpty {
                    conflictList(result.conflicts)
                }

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

    private func comparisonSection(_ comparison: ArrangementComparison) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                comparison.classificationTitle,
                systemImage: comparison.isImproved ? "arrow.up.right.circle.fill" : "equal.circle.fill"
            )
            .font(.title2.bold())
            .foregroundStyle(comparison.isImproved ? .green : .secondary)

            Text(classificationExplanation(comparison))
                .font(.footnote)
                .foregroundStyle(.secondary)

            comparisonMetrics(comparison)

            let alignmentPoints = mapPoints(
                map: comparison.observed.map,
                requirement: selectedObservedRequirement
            ) + mapPoints(
                map: comparison.proposed.map,
                requirement: selectedRequirement
            )

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    comparisonMap(
                        title: "Observed Arrangement",
                        result: comparison.observed,
                        requirement: selectedObservedRequirement,
                        alignmentPoints: alignmentPoints
                    )
                    comparisonMap(
                        title: "Proposed Arrangement",
                        result: comparison.proposed,
                        requirement: selectedRequirement,
                        alignmentPoints: alignmentPoints
                    )
                }
            }
            .scrollIndicators(.visible)

            changedObjects(comparison)
            findingChanges(comparison)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func comparisonMetrics(_ comparison: ArrangementComparison) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text("")
                Text("Observed").font(.caption.bold())
                Text("Proposed").font(.caption.bold())
            }
            comparisonMetricRow(
                "Arrangement Status",
                observed: comparison.observed.status.title,
                proposed: comparison.proposed.status.title
            )
            comparisonMetricRow(
                "Analysis Coverage",
                observed: comparison.observed.coverageDescription,
                proposed: comparison.proposed.coverageDescription
            )
            comparisonMetricRow(
                "Layout Score",
                observed: scoreDescription(comparison.observed),
                proposed: scoreDescription(comparison.proposed)
            )
        }
        .accessibilityElement(children: .contain)
    }

    private func comparisonMetricRow(
        _ label: String,
        observed: String,
        proposed: String
    ) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(observed).font(.subheadline.bold())
            Text(proposed).font(.subheadline.bold())
        }
    }

    private func comparisonMap(
        title: String,
        result: AssessmentResult,
        requirement: AssessmentRequirementResult?,
        alignmentPoints: [FloorPoint]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            AccessibilityMap(
                map: result.map,
                requirement: requirement,
                alignmentPoints: alignmentPoints
            )
            .frame(width: 340, height: 300)
            .accessibilityLabel(
                "\(title) accessibility map, status \(result.status.title), \(result.coverageDescription)."
            )
        }
    }

    @ViewBuilder
    private func changedObjects(_ comparison: ArrangementComparison) -> some View {
        if !comparison.changedPlacements.isEmpty || !comparison.proposedRemovals.isEmpty {
            Divider()
            Text("Proposed Changes").font(.headline)
            ForEach(comparison.changedPlacements) { change in
                Label(placementDescription(change), systemImage: "move.3d")
                    .font(.subheadline)
            }
            ForEach(comparison.proposedRemovals) { change in
                Label("Proposed Removal: \(objectName(change.id))", systemImage: "minus.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    private func findingChanges(_ comparison: ArrangementComparison) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Finding Changes").font(.headline)
            findingGroup("Resolved", findings: comparison.resolvedFindings, color: .green, symbol: "checkmark.circle.fill")
            findingGroup("Remaining", findings: comparison.remainingFindings, color: .orange, symbol: "equal.circle.fill")
            findingGroup("Newly Introduced", findings: comparison.newlyIntroducedFindings, color: .red, symbol: "plus.circle.fill")
        }
    }

    private func findingGroup(
        _ title: String,
        findings: [FindingChange],
        color: Color,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("\(title) (\(findings.count))", systemImage: symbol)
                .font(.subheadline.bold())
                .foregroundStyle(color)
            if findings.isEmpty {
                Text("None").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(findings) { change in
                    Text("\(change.requirementTitle): \(change.finding.title)")
                        .font(.footnote)
                }
            }
        }
    }

    private func classificationExplanation(_ comparison: ArrangementComparison) -> String {
        switch comparison.improvementBasis {
        case .status: "Classification is determined by the Arrangement Status change."
        case .unmetEssentialNeeds: "Statuses are equal; classification is determined by unmet Essential Needs."
        case .unresolvedEssentialNeeds: "Statuses and unmet Essential Needs are equal; classification is determined by unresolved Essential Needs."
        case .layoutScore: "Essential outcomes are equal; classification is determined by the Layout Score bounds."
        case .preferenceOutcomes: "Status, Essential outcomes, and score are equal; classification is determined by Preference outcomes."
        case .noDifference: "The proposal changes placements, but its assessed outcomes are unchanged."
        }
    }

    private func scoreDescription(_ result: AssessmentResult) -> String {
        result.score.map { $0.displayValue + " / 100" } ?? "No score"
    }

    private func objectName(_ id: String) -> String {
        movableObjects.first(where: { $0.id == id })?.displayName ?? id
    }

    private func placementDescription(_ change: ProposedObjectChange) -> String {
        let degrees = Measurement(value: change.rotationRadians, unit: UnitAngle.radians)
            .converted(to: .degrees).value
        return "\(objectName(change.id)): X \(metres(change.translationXMetres)), Z \(metres(change.translationZMetres)), rotation \(degrees.formatted(.number.precision(.fractionLength(0))))°"
    }

    private func mapPoints(
        map: AssessmentMapModel,
        requirement: AssessmentRequirementResult?
    ) -> [FloorPoint] {
        map.floor.points
            + map.obstacles.flatMap(\.polygon.points)
            + map.accessPoints.flatMap(\.polygon.points)
            + map.zones.flatMap(\.polygon.points)
            + (requirement?.routes.flatMap(\.points) ?? [])
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
                    Text(result.score.map { $0.displayValue + " / 100" } ?? "No score")
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

            if result.score?.isProvisional == true {
                Label(
                    "The score is a range because unresolved requirements are not treated as passes or failures.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if isAssessing {
                ProgressView("Updating analysis…")
                    .font(.footnote)
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

    @ViewBuilder
    private var proposalEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Propose a Change")
                        .font(.title2.bold())
                    Text("Captured placements remain unchanged. Adjustments below describe one hypothetical arrangement.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset Proposal", systemImage: "arrow.counterclockwise", role: .destructive, action: reset)
                    .disabled(!arrangement.hasChanges)
            }

            if movableObjects.isEmpty {
                Label(
                    "No objects were confirmed as movable during Room Setup Review.",
                    systemImage: "lock.fill"
                )
                .foregroundStyle(.secondary)
            } else {
                Picker("Movable Object", selection: $selectedObjectID) {
                    ForEach(movableObjects) { object in
                        Text(object.displayName).tag(Optional(object.id))
                    }
                }

                if let objectID = selectedObjectID,
                   let object = movableObjects.first(where: { $0.id == objectID }) {
                    objectEditor(object)
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func objectEditor(_ object: CapturedRoomInventory.Item) -> some View {
        let change = arrangement.change(for: object.id) ?? .unchanged(objectID: object.id)
        return VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Proposed position") {
                Text("X \(metres(change.translationXMetres)), Z \(metres(change.translationZMetres))")
                    .monospacedDigit()
            }
            HStack {
                adjustmentButton("Move left", systemImage: "arrow.left") {
                    adjust(object.id) { $0.translationXMetres -= 0.05 }
                }
                adjustmentButton("Move right", systemImage: "arrow.right") {
                    adjust(object.id) { $0.translationXMetres += 0.05 }
                }
                adjustmentButton("Move forward", systemImage: "arrow.up") {
                    adjust(object.id) { $0.translationZMetres += 0.05 }
                }
                adjustmentButton("Move back", systemImage: "arrow.down") {
                    adjust(object.id) { $0.translationZMetres -= 0.05 }
                }
            }
            .labelStyle(.iconOnly)

            LabeledContent("Proposed rotation") {
                Text(Measurement(value: change.rotationRadians, unit: UnitAngle.radians)
                    .converted(to: .degrees).value.formatted(.number.precision(.fractionLength(0))) + "°")
                    .monospacedDigit()
            }
            HStack {
                Button("Rotate left 15 degrees", systemImage: "rotate.left") {
                    adjust(object.id) { $0.rotationRadians -= .pi / 12 }
                }
                Button("Rotate right 15 degrees", systemImage: "rotate.right") {
                    adjust(object.id) { $0.rotationRadians += .pi / 12 }
                }
            }
            .buttonStyle(.bordered)

            Toggle("Propose removing \(object.displayName)", isOn: Binding(
                get: { change.isRemoved },
                set: { value in adjust(object.id) { $0.isRemoved = value } }
            ))
            .tint(.red)
        }
    }

    private func adjustmentButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("Moves the object by 5 centimetres")
    }

    private func conflictList(_ conflicts: [ArrangementConflict]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Arrangement Conflicts", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)
            Text("Resolve every conflict before this proposal can receive a Layout Score.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(conflicts) { conflict in
                VStack(alignment: .leading, spacing: 3) {
                    Text(conflict.title).font(.headline)
                    Text(conflict.details).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func adjust(
        _ objectID: String,
        update: (inout ProposedObjectChange) -> Void
    ) {
        undoStack.append(arrangement)
        redoStack.removeAll()
        arrangement.update(objectID: objectID, update)
        persistArrangement()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(arrangement)
        arrangement = previous
        persistArrangement()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(arrangement)
        arrangement = next
        persistArrangement()
    }

    private func reset() {
        guard arrangement.hasChanges else { return }
        undoStack.append(arrangement)
        redoStack.removeAll()
        arrangement = .empty(roomID: room.id)
        persistArrangement()
    }

    private func persistArrangement() {
        do {
            try store.save(arrangement)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runAssessment(for arrangement: ProposedArrangement) async {
        isAssessing = true
        do {
            let assessment = try await Task.detached(priority: .userInitiated) {
                let engine = AssessmentEngine()
                let observed = try engine.assess(
                    room: room,
                    profile: profile,
                    setup: setup,
                    arrangement: nil
                )
                guard arrangement.hasChanges else {
                    return (observed, Optional<ArrangementComparison>.none)
                }
                let proposed = try engine.assess(
                    room: room,
                    profile: profile,
                    setup: setup,
                    arrangement: arrangement
                )
                let comparison = ArrangementComparisonEngine().compare(
                    observed: observed,
                    proposed: proposed,
                    arrangement: arrangement
                )
                return (proposed, comparison)
            }.value
            guard self.arrangement == arrangement else { return }
            result = assessment.0
            comparison = assessment.1
            selectedRequirementID = assessment.0.requirements.first(where: { $0.outcome == .doesNotMeetNeed })?.id
                ?? assessment.0.requirements.first(where: { $0.outcome == .needsVerification })?.id
                ?? assessment.0.requirements.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
        if self.arrangement == arrangement { isAssessing = false }
    }

    private func metres(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " m"
    }

    private func statusColor(_ status: ArrangementStatus) -> Color {
        switch status {
        case .invalidProposal: .red
        case .supportsEssentialNeeds: .green
        case .doesNotSupportEssentialNeeds: .red
        case .needsVerification: .orange
        }
    }

    private func statusSymbol(_ status: ArrangementStatus) -> String {
        switch status {
        case .invalidProposal: "exclamationmark.triangle.fill"
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
    var alignmentPoints: [FloorPoint]? = nil

    var body: some View {
        Canvas { context, size in
            let transform = MapTransform(
                points: alignmentPoints ?? allPoints,
                size: size,
                padding: 18
            )

            drawPolygon(map.floor, color: .secondary.opacity(0.12), stroke: .secondary, context: &context, transform: transform)
            for obstacle in map.obstacles {
                drawPolygon(
                    obstacle.polygon,
                    color: obstacle.isRemoved
                        ? .red.opacity(0.12)
                        : obstacle.isProposed ? .purple.opacity(0.55) : .gray.opacity(0.65),
                    stroke: obstacle.isRemoved ? .red : obstacle.isProposed ? .purple : .gray,
                    context: &context,
                    transform: transform,
                    lineWidth: obstacle.isProposed ? 3 : 1
                )
                if obstacle.isRemoved {
                    drawRemovalMark(obstacle.polygon, context: &context, transform: transform)
                }
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
                let routeColor: Color = route.outcome == .doesNotMeetNeed ? .secondary : color(for: route.outcome)
                context.stroke(
                    path,
                    with: .color(routeColor),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
                if route.outcome == .doesNotMeetNeed, let limitingPoint = route.limitingPoint {
                    let centre = transform.point(limitingPoint)
                    let marker = Path(ellipseIn: CGRect(x: centre.x - 6, y: centre.y - 6, width: 12, height: 12))
                    context.fill(marker, with: .color(.red))
                }
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

    private func drawRemovalMark(
        _ polygon: FloorPolygon,
        context: inout GraphicsContext,
        transform: MapTransform
    ) {
        guard polygon.points.count == 4 else { return }
        var mark = Path()
        mark.move(to: transform.point(polygon.points[0]))
        mark.addLine(to: transform.point(polygon.points[2]))
        mark.move(to: transform.point(polygon.points[1]))
        mark.addLine(to: transform.point(polygon.points[3]))
        context.stroke(mark, with: .color(.red), style: StrokeStyle(lineWidth: 3, lineCap: .round))
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
