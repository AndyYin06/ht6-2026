import SwiftUI

struct MobilityProfileFlowView: View {
    @ObservedObject var store: MobilityProfileStore
    let beginEditing: Bool
    let onClose: () -> Void

    @State private var isEditing: Bool
    @State private var draft: MobilityProfile
    @State private var operatorConfirmed = false
    @State private var errorMessage: String?

    init(
        store: MobilityProfileStore,
        beginEditing: Bool = false,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.beginEditing = beginEditing
        self.onClose = onClose
        let shouldEdit = beginEditing || store.profile == nil
        _isEditing = State(initialValue: shouldEdit)
        _draft = State(initialValue: MobilityProfile.customDraft(from: store.profile))
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEditing {
                    editor
                } else if let profile = store.profile {
                    confirmation(profile)
                }
            }
            .navigationTitle(isEditing ? "Mobility Profile" : "Confirm Mobility Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
        .alert(
            "Unable to Save Profile",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var editor: some View {
        Form {
            Section("Room Occupant") {
                TextField("Name", text: $draft.occupantName)
                    .textContentType(.name)
                Text("This profile represents one Room Occupant. Do not include room names or destinations here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    draft = .adaDemonstrationDraft(occupantName: draft.occupantName)
                } label: {
                    Label("Use Demonstration Starting Point", systemImage: "doc.badge.plus")
                }
                Text("Optional and fully editable. It is not a recommendation for this Room Occupant and does not certify compliance or clinical appropriateness.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Optional Template")
            }

            Section("Measurements") {
                measurementField(
                    "Minimum passage width",
                    value: $draft.measurements.minimumPassageWidthCentimetres
                )
                measurementField(
                    "Turning-space diameter",
                    value: $draft.measurements.turningSpaceDiameterCentimetres
                )
                measurementField(
                    "Clear-floor-space width",
                    value: $draft.measurements.clearFloorSpaceWidthCentimetres
                )
                measurementField(
                    "Clear-floor-space depth",
                    value: $draft.measurements.clearFloorSpaceDepthCentimetres
                )
            }

            needsSection(priority: .essential, title: "Custom Essential Needs")
            needsSection(priority: .preference, title: "Custom Preferences")

            if let reference = draft.templateReference {
                templateReference(reference)
            }

            Section {
                Button("Save and Review") {
                    saveAndReview()
                }
                .frame(maxWidth: .infinity)
                .disabled(!draft.isComplete)
            } footer: {
                if store.isConfirmed {
                    Text("Saving changes invalidates the previous Operator confirmation. Unchanged profiles remain confirmed.")
                }
            }
        }
    }

    private func confirmation(_ profile: MobilityProfile) -> some View {
        Form {
            Section("Room Occupant") {
                LabeledContent("Name", value: profile.occupantName)
            }

            Section("Measurements") {
                LabeledContent("Minimum passage width", value: centimetres(profile.measurements.minimumPassageWidthCentimetres))
                LabeledContent("Turning-space diameter", value: centimetres(profile.measurements.turningSpaceDiameterCentimetres))
                LabeledContent("Clear-floor-space width", value: centimetres(profile.measurements.clearFloorSpaceWidthCentimetres))
                LabeledContent("Clear-floor-space depth", value: centimetres(profile.measurements.clearFloorSpaceDepthCentimetres))
            }

            reviewedNeeds(profile.customNeeds, priority: .essential, title: "Essential Needs")
            reviewedNeeds(profile.customNeeds, priority: .preference, title: "Preferences")

            if let reference = profile.templateReference {
                templateReference(reference)
            }

            Section {
                Toggle(isOn: $operatorConfirmed) {
                    Text("I confirm that this profile represents the Room Occupant’s known mobility needs.")
                        .fontWeight(.semibold)
                }

                Button {
                    confirm()
                } label: {
                    Label("Confirm Mobility Profile", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!operatorConfirmed)
            } footer: {
                Text("AccessiRoom does not infer needs from a diagnosis, age, or mobility-device label. You can edit this profile later; changes require a new confirmation.")
            }

            Section {
                Button("Edit Profile") {
                    draft = profile
                    operatorConfirmed = false
                    isEditing = true
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func measurementField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                Text("cm")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func needsSection(priority: MobilityNeedPriority, title: String) -> some View {
        Section {
            ForEach(Array(draft.customNeeds.enumerated()), id: \.element.id) { index, need in
                if need.priority == priority {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Need", text: $draft.customNeeds[index].title)
                        TextField("Notes (optional)", text: $draft.customNeeds[index].details, axis: .vertical)
                            .font(.subheadline)
                        Button("Remove", role: .destructive) {
                            draft.customNeeds.remove(at: index)
                        }
                        .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
            }

            Button {
                draft.customNeeds.append(
                    CustomMobilityNeed(title: "", details: "", priority: priority)
                )
            } label: {
                Label("Add \(priority == .essential ? "Essential Need" : "Preference")", systemImage: "plus")
            }
        } header: {
            Text(title)
        } footer: {
            Text(priority == .essential
                 ? "Essential Needs must be met for the arrangement to support the Room Occupant."
                 : "Preferences improve the experience but are not required.")
        }
    }

    private func reviewedNeeds(
        _ needs: [CustomMobilityNeed],
        priority: MobilityNeedPriority,
        title: String
    ) -> some View {
        Section(title) {
            let matching = needs.filter { $0.priority == priority }
            if matching.isEmpty {
                Text("None added")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matching) { need in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(need.title)
                        if !need.details.isEmpty {
                            Text(need.details)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func templateReference(_ reference: ProfileTemplateReference) -> some View {
        Section("Template Source") {
            Text(reference.name)
                .fontWeight(.semibold)
            LabeledContent("Source", value: reference.source)
            LabeledContent("Jurisdiction", value: reference.jurisdiction)
            LabeledContent("Version", value: reference.version)
            Text(reference.sections)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("Open official source", destination: reference.sourceURL)
        }
    }

    private func saveAndReview() {
        do {
            try store.save(draft)
            draft = store.profile ?? draft
            operatorConfirmed = false
            isEditing = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirm() {
        do {
            try store.confirm()
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func centimetres(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + " cm"
    }
}
