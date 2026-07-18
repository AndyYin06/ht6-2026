import RoomPlan
import SwiftUI
import UIKit

struct RoomCaptureViewController: UIViewControllerRepresentable {
    let onCaptured: (Result<CapturedRoomArtifact, Error>) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> RoomCaptureViewControllerWrapper {
        RoomCaptureViewControllerWrapper(
            onCaptured: onCaptured,
            onCancel: onCancel
        )
    }

    func updateUIViewController(
        _ uiViewController: RoomCaptureViewControllerWrapper,
        context: Context
    ) {
    }
}

final class RoomCaptureViewControllerWrapper: UIViewController, @MainActor RoomCaptureSessionDelegate {
    private let onCaptured: (Result<CapturedRoomArtifact, Error>) -> Void
    private let onCancel: () -> Void
    private var captureView: RoomCaptureView!
    private var finishButton: UIButton!
    private var cancelButton: UIButton!
    private var isScanning = false
    private var isFinishing = false

    init(
        onCaptured: @escaping (Result<CapturedRoomArtifact, Error>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onCaptured = onCaptured
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        captureView = RoomCaptureView(frame: .zero)
        captureView.translatesAutoresizingMaskIntoConstraints = false
        captureView.captureSession.delegate = self
        view.addSubview(captureView)

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Finish Scan"
        configuration.image = UIImage(systemName: "checkmark")
        configuration.imagePadding = 8
        configuration.cornerStyle = .capsule

        finishButton = UIButton(configuration: configuration)
        finishButton.translatesAutoresizingMaskIntoConstraints = false
        finishButton.addTarget(self, action: #selector(finishScan), for: .touchUpInside)
        view.addSubview(finishButton)

        var cancelConfiguration = UIButton.Configuration.filled()
        cancelConfiguration.title = "Cancel"
        cancelConfiguration.image = UIImage(systemName: "xmark")
        cancelConfiguration.imagePadding = 8
        cancelConfiguration.cornerStyle = .capsule

        cancelButton = UIButton(configuration: cancelConfiguration)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            captureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            captureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            captureView.topAnchor.constraint(equalTo: view.topAnchor),
            captureView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            finishButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -20
            ),
            finishButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 16
            ),
            cancelButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 20
            ),
            cancelButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 16
            ),
        ])

        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanningIfNeeded()
    }

    @objc private func finishScan() {
        guard isScanning, !isFinishing else { return }
        isFinishing = true
        finishButton.isEnabled = false
        finishButton.configuration?.title = "Finishing"
        finishButton.configuration?.showsActivityIndicator = true
        stopScanningIfNeeded()
    }

    @objc private func cancelScan() {
        guard !isFinishing else { return }
        stopScanningIfNeeded()
        onCancel()
    }

    private func stopScanningIfNeeded() {
        guard isScanning else { return }
        isScanning = false
        captureView.captureSession.stop()
    }

    func captureSession(
        _ session: RoomCaptureSession,
        didEndWith data: CapturedRoomData,
        error: Error?
    ) {
        guard isFinishing else { return }
        if let error {
            onCaptured(.failure(error))
            return
        }

        Task {
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects])
                    .capturedRoom(from: data)
                let artifact = try CapturedRoomArtifactProcessor().process(room)
                onCaptured(.success(artifact))
            } catch {
                onCaptured(.failure(error))
            }
        }
    }
}
