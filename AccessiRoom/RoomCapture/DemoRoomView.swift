import SwiftUI

struct DemoRoomView: View {
    @ObservedObject var store: AcceptedRoomStore
    let onClose: () -> Void
    let onAccepted: () -> Void

    @State private var candidate: CapturedRoomArtifact?
    @State private var errorMessage: String?
    @State private var errorOccurredWhileAccepting = false

    var body: some View {
        Group {
            if let candidate {
                ScanReviewView(
                    candidate: candidate,
                    canRescan: false,
                    onAccept: acceptCandidate,
                    onRescan: {},
                    onCancel: onClose
                )
            } else {
                ProgressView("Preparing Demo Room")
                    .task(prepareCandidate)
            }
        }
        .alert(
            errorOccurredWhileAccepting ? "Unable to Accept Room" : "Unable to Prepare Room",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("Close", action: onClose)
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private func prepareCandidate() async {
        do {
            candidate = try CapturedRoomArtifactProcessor().demoArtifact()
        } catch {
            errorOccurredWhileAccepting = false
            errorMessage = error.localizedDescription
        }
    }

    private func acceptCandidate() {
        guard let candidate else { return }
        do {
            try store.accept(candidate)
            onAccepted()
        } catch {
            errorOccurredWhileAccepting = true
            errorMessage = error.localizedDescription
        }
    }
}
