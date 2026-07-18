import SwiftUI

struct RoomSetupReviewView: View {
    @ObservedObject var store: AcceptedRoomStore
    let profile: MobilityProfile
    let onClose: () -> Void

    @State private var inventory: CapturedRoomInventory?
    @State private var draft: RoomSetup?
    @State private var errorMessage: String?
    @State private var showingRoomPreview = false
    @State private var showingAssessment = false

    private var room: CapturedRoomArtifact? { store.acceptedRoom }

    private var draftMatchesConfirmedSetup: Bool {
        guard let draft, let confirmed = store.roomSetup, confirmed.isConfirmed else { return false }
        return draft == confirmed
    }

    var body: some View {
        NavigationStack {
            Group {
                if let inventory, let draftBinding = Binding($draft) {
                    setupForm(inventory: inventory, draft: draftBinding)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Unable to Read Captured Room",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Preparing Room Setup Review…")
                }
            }
            .navigationTitle(draftMatchesConfirmedSetup ? "Room Setup" : "Room Setup Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark", action: onClose)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("View 3D Room", systemImage: "cube", action: { showingRoomPreview = true })
                        .disabled(room == nil)
                }
            }
        }
        .task { load() }
        .sheet(isPresented: $showingRoomPreview) {
            if let room {
                NavigationStack {
                    RoomPreviewController(fileURL: room.usdzURL)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Accepted Room")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingRoomPreview = false }
                            }
                        }
                }
            }
        }
        .fullScreenCover(isPresented: $showingAssessment) {
            AssessmentEntryView(onClose: { showingAssessment = false })
        }
        .alert("Unable to Save Setup", isPresented: Binding(
            get: { errorMessage != nil && inventory != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    @ViewBuilder
    private func setupForm(
        inventory: CapturedRoomInventory,
        draft: Binding<RoomSetup>
    ) -> some View {
        Form {
            Section {
                Label(
                    draftMatchesConfirmedSetup
                        ? "Setup confirmed. Findings and scores may now be calculated."
                        : "Confirm every room-specific assessment input before assessment becomes available.",
                    systemImage: draftMatchesConfirmedSetup
                        ? "checkmark.seal.fill"
                        : "lock.fill"
                )
                .foregroundStyle(draftMatchesConfirmedSetup ? .green : .secondary)
            }

            Section("Access Points") {
                Text("Select only doors or openings that connect this room to circulation outside it—not closets or cabinets.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(inventory.accessPointCandidates) { item in
                    SetupToggleRow(
                        item: item,
                        isOn: setBinding(for: item.id, in: draft.accessPointIDs)
                    )
                }
            }

            Section("Architectural Features") {
                Text("Keep fixed features that constrain movement or object placement.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(inventory.architecturalFeatures) { item in
                    SetupToggleRow(
                        item: item,
                        isOn: setBinding(for: item.id, in: draft.architecturalFeatureIDs)
                    )
                }
            }

            Section("Captured Objects") {
                Text("Turn off a detection only when it does not represent a real object in the room.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(inventory.objects) { item in
                    if let index = draft.wrappedValue.objects.firstIndex(where: { $0.id == item.id }) {
                        Toggle(isOn: draft.objects[index].isIncluded) {
                            ItemDescription(item: item, detail: item.confidence.map { "\($0.capitalized) confidence" })
                        }
                    }
                }
            }

            Section("Movable Objects") {
                Text("Select real objects that may be repositioned in a Proposed Arrangement.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(inventory.objects) { item in
                    if let index = draft.wrappedValue.objects.firstIndex(where: { $0.id == item.id }),
                       draft.wrappedValue.objects[index].isIncluded {
                        Toggle(isOn: draft.objects[index].isMovable) {
                            ItemDescription(item: item)
                        }
                    }
                }
            }

            Section("Required Destinations") {
                Text("Select each place or object the Room Occupant must be able to approach.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(inventory.objects) { item in
                    if let index = draft.wrappedValue.objects.firstIndex(where: { $0.id == item.id }),
                       draft.wrappedValue.objects[index].isIncluded {
                        VStack(alignment: .leading) {
                            Toggle(isOn: draft.objects[index].isRequiredDestination) {
                                ItemDescription(item: item)
                            }
                            if draft.wrappedValue.objects[index].isRequiredDestination {
                                Picker("Need", selection: draft.objects[index].destinationPriority) {
                                    ForEach(DestinationPriority.allCases) { priority in
                                        Text(priority.title).tag(priority)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }
                }
            }

            Section("Approach Zones") {
                Text("Configure the usable arrival space beside each Required Destination.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(inventory.objects) { item in
                    if let index = draft.wrappedValue.objects.firstIndex(where: { $0.id == item.id }),
                       draft.wrappedValue.objects[index].isIncluded,
                       draft.wrappedValue.objects[index].isRequiredDestination {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(item.displayName).font(.headline)
                            Picker("Arrival side", selection: draft.objects[index].approachZone.side) {
                                ForEach(ApproachSide.allCases) { side in
                                    Text(side.title).tag(side)
                                }
                            }
                            MeasurementStepper(
                                title: "Width",
                                value: draft.objects[index].approachZone.widthMetres,
                                range: 0.3...3
                            )
                            MeasurementStepper(
                                title: "Depth",
                                value: draft.objects[index].approachZone.depthMetres,
                                range: 0.3...3
                            )
                        }
                    }
                }
            }

            Section("Turning Zones") {
                Text("Add a zone only where the Room Occupant must turn. Coordinates use the captured room’s floor-plane origin.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(draft.turningZones) { $zone in
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Zone name", text: $zone.name)
                            .font(.headline)
                        MeasurementStepper(title: "Centre X", value: $zone.centreXMetres, range: -10...10)
                        MeasurementStepper(title: "Centre Z", value: $zone.centreZMetres, range: -10...10)
                        MeasurementStepper(title: "Diameter", value: $zone.diameterMetres, range: 0.5...3)
                        Button("Remove Turning Zone", systemImage: "trash", role: .destructive) {
                            draft.wrappedValue.turningZones.removeAll { $0.id == zone.id }
                        }
                    }
                }
                Button("Add Turning Zone", systemImage: "plus.circle") {
                    draft.wrappedValue.turningZones.append(TurningZoneSetup(
                        name: "Turning Zone \(draft.wrappedValue.turningZones.count + 1)",
                        centreXMetres: 0,
                        centreZMetres: 0,
                        diameterMetres: profile.measurements.turningSpaceDiameterCentimetres / 100
                    ))
                }
            }

            Section {
                if let message = draft.wrappedValue.validationMessage(inventory: inventory) {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Button {
                    confirm(draft.wrappedValue, inventory: inventory)
                } label: {
                    Label("Confirm Room Setup", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.wrappedValue.validationMessage(inventory: inventory) != nil)

                Button {
                    showingAssessment = true
                } label: {
                    Label("Continue to Assessment", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!draftMatchesConfirmedSetup)
            } footer: {
                Text("Changing and reconfirming this setup replaces the prior assessment inputs for this Accepted Room.")
            }
        }
    }

    private func load() {
        guard let room else { return }
        do {
            let loadedInventory = try CapturedRoomInventory.load(from: room.jsonURL)
            inventory = loadedInventory
            draft = store.roomSetup ?? RoomSetup.draft(
                roomID: room.id,
                inventory: loadedInventory,
                measurements: profile.measurements
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirm(_ setup: RoomSetup, inventory: CapturedRoomInventory) {
        do {
            try store.confirm(setup, inventory: inventory)
            draft = store.roomSetup
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setBinding(for id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { selected in
                if selected { set.wrappedValue.insert(id) }
                else { set.wrappedValue.remove(id) }
            }
        )
    }
}

private struct SetupToggleRow: View {
    let item: CapturedRoomInventory.Item
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { ItemDescription(item: item) }
    }
}

private struct ItemDescription: View {
    let item: CapturedRoomInventory.Item
    var detail: String?

    init(item: CapturedRoomInventory.Item, detail: String? = nil) {
        self.item = item
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.displayName)
            Text([item.dimensionsDescription, detail].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MeasurementStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        Stepper(value: $value, in: range, step: 0.05) {
            LabeledContent(title, value: value.formatted(.number.precision(.fractionLength(2))) + " m")
        }
    }
}

private struct AssessmentEntryView: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Assessment Ready",
                systemImage: "figure.roll",
                description: Text("The confirmed Mobility Profile, Accepted Room, and Room Setup are ready for deterministic findings and scores.")
            )
            .navigationTitle("Assessment")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left", action: onClose)
                }
            }
        }
    }
}
