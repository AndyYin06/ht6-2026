import SwiftUI

struct VoiceAssistantOverlay: ViewModifier {
    @EnvironmentObject private var voiceSession: VoiceSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let surface: VoiceSupportedSurface

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                voiceSurface
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .onChange(of: surface, initial: true) { _, currentSurface in
                voiceSession.enter(currentSurface)
            }
            .sheet(isPresented: $voiceSession.isDisclosurePresented) {
                VoiceSessionDisclosure()
                    .environmentObject(voiceSession)
                    .presentationDetents([.medium])
            }
    }

    @ViewBuilder
    private var voiceSurface: some View {
        if voiceSession.isExpanded {
            expandedPanel
                .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
        } else {
            compactButton
        }
    }

    private var compactButton: some View {
        HStack {
            Spacer()
            Button {
                if voiceSession.phase.isSessionActive {
                    withOptionalAnimation { voiceSession.isExpanded = true }
                } else {
                    voiceSession.requestStart()
                }
            } label: {
                Label(compactButtonTitle, systemImage: voiceSession.phase.systemImage)
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityHint(compactButtonHint)
        }
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: voiceSession.phase.systemImage)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(voiceSession.phase.title)
                        .font(.headline)
                    if let currentSurface = voiceSession.currentSurface {
                        Text(currentSurface.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Collapse", systemImage: "chevron.down") {
                    withOptionalAnimation { voiceSession.isExpanded = false }
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Collapse voice controls")

                if voiceSession.phase.isSessionActive {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) {
                        Task { await voiceSession.stop() }
                    }
                    .accessibilityLabel("Stop voice session")
                }
            }

            if let errorMessage = voiceSession.errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if voiceSession.transcript.isEmpty {
                Text(emptyTranscriptMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                transcript
            }

            if let clarification = voiceSession.clarification {
                candidatePicker(clarification)
            }

            if voiceSession.phase == .recoverableError {
                HStack {
                    Button("Try Again") {
                        voiceSession.requestStart()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Dismiss") {
                        withOptionalAnimation { voiceSession.isExpanded = false }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.secondary.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(voiceSession.transcript.suffix(4)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.speaker.title)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(entry.text)
                            .font(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: 160)
        .accessibilityLabel("Live voice transcript")
    }

    private func candidatePicker(_ clarification: RequirementClarification) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(clarification.prompt, systemImage: "questionmark.circle.fill")
                .font(.subheadline.bold())

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(clarification.candidates) { candidate in
                        Button {
                            voiceSession.chooseCandidate(candidate)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.title).font(.subheadline.bold())
                                Text(candidate.outcome.title).font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Focuses this highlighted assessment requirement")
                    }
                }
            }
            .scrollIndicators(.visible)
        }
    }

    private var compactButtonTitle: String {
        switch voiceSession.phase {
        case .inactive, .permissionRequired, .ended:
            "Start Voice"
        case .recoverableError:
            "Voice Unavailable"
        default:
            voiceSession.phase.title
        }
    }

    private var compactButtonHint: String {
        voiceSession.phase.isSessionActive
            ? "Shows the current transcript and voice session controls."
            : "Explains remote voice processing before the microphone is used."
    }

    private var emptyTranscriptMessage: String {
        switch voiceSession.phase {
        case .connecting:
            "Connecting to AccessiRoom Guide. The touch workflow remains available."
        case .listening:
            "Microphone active. Live captions will appear here."
        case .thinking:
            "Your request is being processed."
        case .speaking:
            "The agent response will remain captioned here."
        case .awaitingConfirmation:
            "Review the pending action before confirming or cancelling."
        case .executing:
            "Applying the confirmed local action."
        case .inactive, .permissionRequired, .recoverableError, .ended:
            "Voice is not active. The complete AccessiRoom workflow remains available by touch."
        }
    }

    private var statusColor: Color {
        switch voiceSession.phase {
        case .recoverableError:
            .orange
        case .listening:
            .green
        default:
            .accentColor
        }
    }

    private func withOptionalAnimation(_ action: () -> Void) {
        if reduceMotion {
            action()
        } else {
            withAnimation(.easeInOut(duration: 0.2), action)
        }
    }
}

private struct VoiceSessionDisclosure: View {
    @EnvironmentObject private var voiceSession: VoiceSession

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label("Voice processing disclosure", systemImage: "mic.badge.plus")
                    .font(.title2.bold())

                Text("When you start a voice session, microphone audio is processed remotely through ElevenLabs.")

                Text("AccessiRoom shares only the minimal structured context needed for your request, such as visible object labels and current assessment measurements. Raw RoomPlan JSON, USDZ files, and complete room geometry are not shared.")
                    .foregroundStyle(.secondary)

                Text("The live transcript is removed when the session ends. Voice is optional, and every supported action remains available by touch.")
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task { await voiceSession.startAfterDisclosure() }
                } label: {
                    Label("Start Voice Session", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Not Now", role: .cancel) {
                    voiceSession.cancelDisclosure()
                }
                .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("AccessiRoom Guide")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension View {
    func voiceAssistantOverlay(on surface: VoiceSupportedSurface) -> some View {
        modifier(VoiceAssistantOverlay(surface: surface))
    }
}
