import RoomPlan
import SwiftUI

struct ContentView: View {
    @StateObject private var roomStore = AcceptedRoomStore()
    @StateObject private var profileStore = MobilityProfileStore()
    @State private var presentedExperience: PresentedExperience?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.indigo.opacity(0.22), Color.blue.opacity(0.08), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 64, weight: .medium))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    Text("AccessiRoom")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))

                    Text("Confirm one Room Occupant’s mobility needs, then continue with a room or capture a new one.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }

                Spacer()

                VStack(spacing: 14) {
                    profileCard

                    if profileStore.isConfirmed, roomStore.acceptedRoom != nil {
                        Button {
                            presentedExperience = .acceptedRoom
                        } label: {
                            Label("Continue Room", systemImage: "arrow.right.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.extraLarge)
                    }

                    if profileStore.isConfirmed {
                        Button {
                            presentedExperience = .scan
                        } label: {
                            Label(
                                roomStore.acceptedRoom == nil ? "Scan a Room" : "Scan a New Room",
                                systemImage: "viewfinder"
                            )
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.extraLarge)
                        .disabled(!RoomCaptureSession.isSupported)

                        Button {
                            presentedExperience = .demo
                        } label: {
                            Label("Use Demo Room", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.extraLarge)
                    }

                    if !RoomCaptureSession.isSupported {
                        Text("Live scanning requires a supported LiDAR-equipped iPad. The demo room is available on this device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 460)

                Spacer()
            }
            .padding(32)
        }
        .fullScreenCover(item: $presentedExperience) { experience in
            switch experience {
            case .profileReview:
                MobilityProfileFlowView(store: profileStore) {
                    presentedExperience = nil
                }

            case .profileEdit:
                MobilityProfileFlowView(store: profileStore, beginEditing: true) {
                    presentedExperience = nil
                }

            case .scan:
                LiveRoomCaptureFlow(
                    store: roomStore,
                    onClose: { presentedExperience = nil },
                    onAccepted: { presentedExperience = .acceptedRoom }
                )

            case .demo:
                DemoRoomView(
                    store: roomStore,
                    onClose: { presentedExperience = nil },
                    onAccepted: { presentedExperience = .acceptedRoom }
                )

            case .acceptedRoom:
                if roomStore.acceptedRoom != nil, let profile = profileStore.profile {
                    RoomSetupReviewView(store: roomStore, profile: profile) {
                        presentedExperience = nil
                    }
                }
            }
        }
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: profileStore.isConfirmed ? "checkmark.seal.fill" : "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(profileStore.isConfirmed ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profileStore.profile?.occupantName.isEmpty == false
                         ? profileStore.profile?.occupantName ?? "Mobility Profile"
                         : "Mobility Profile")
                        .font(.headline)
                    Text(profileStore.isConfirmed ? "Confirmed by the Operator" : "Confirmation required before room capture")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if profileStore.profile != nil {
                    Button("Edit") {
                        presentedExperience = .profileEdit
                    }
                }
            }

            if !profileStore.isConfirmed {
                Button {
                    presentedExperience = .profileReview
                } label: {
                    Text(profileStore.profile == nil ? "Create Mobility Profile" : "Review and Confirm Profile")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private enum PresentedExperience: String, Identifiable {
    case profileReview
    case profileEdit
    case scan
    case demo
    case acceptedRoom

    var id: String { rawValue }
}

private struct LiveRoomCaptureFlow: View {
    @ObservedObject var store: AcceptedRoomStore
    let onClose: () -> Void
    let onAccepted: () -> Void

    @State private var candidate: CapturedRoomArtifact?
    @State private var errorMessage: String?
    @State private var errorOccurredWhileAccepting = false
    @State private var captureID = UUID()

    private let processor = CapturedRoomArtifactProcessor()

    var body: some View {
        Group {
            if let candidate {
                ScanReviewView(
                    candidate: candidate,
                    canRescan: true,
                    onAccept: acceptCandidate,
                    onRescan: rescan,
                    onCancel: cancelReview
                )
            } else {
                RoomCaptureViewController(
                    onCaptured: handleCapture,
                    onCancel: onClose
                )
                .id(captureID)
                .ignoresSafeArea()
            }
        }
        .alert(
            errorOccurredWhileAccepting ? "Unable to Accept Room" : "Room Capture Failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("Try Again") {
                if candidate != nil {
                    acceptCandidate()
                } else {
                    captureID = UUID()
                }
            }
            Button("Cancel", role: .cancel, action: onClose)
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private func handleCapture(_ result: Result<CapturedRoomArtifact, Error>) {
        switch result {
        case .success(let artifact):
            candidate = artifact
        case .failure(let error):
            errorOccurredWhileAccepting = false
            errorMessage = error.localizedDescription
        }
    }

    private func acceptCandidate() {
        guard let candidate else { return }
        do {
            try store.accept(candidate)
            processor.discard(candidate)
            onAccepted()
        } catch {
            errorOccurredWhileAccepting = true
            errorMessage = error.localizedDescription
        }
    }

    private func rescan() {
        guard let candidate else { return }
        processor.discard(candidate)
        self.candidate = nil
        captureID = UUID()
    }

    private func cancelReview() {
        if let candidate {
            processor.discard(candidate)
        }
        onClose()
    }
}
