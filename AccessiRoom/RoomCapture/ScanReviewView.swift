import QuickLook
import SwiftUI

struct ScanReviewView: View {
    let candidate: CapturedRoomArtifact
    let canRescan: Bool
    let onAccept: () -> Void
    let onRescan: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            RoomPreviewController(fileURL: candidate.usdzURL)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                reviewHeader
                Spacer()
                reviewActions
            }
            .padding()
        }
        .background(Color.black)
    }

    private var reviewHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            Button(action: onCancel) {
                Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(.borderedProminent)

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Scan Review")
                    .font(.headline)
                Text("Is this capture adequate to keep as evidence?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var reviewActions: some View {
        HStack(spacing: 12) {
            ShareLink(items: [candidate.jsonURL, candidate.usdzURL]) {
                Label("Share Capture", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)

            if canRescan {
                Button(action: onRescan) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            Button(action: onAccept) {
                Label("Accept Capture", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct RoomPreviewController: UIViewControllerRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: QLPreviewController,
        context: Context
    ) {
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let fileURL: URL

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            fileURL as NSURL
        }
    }
}
