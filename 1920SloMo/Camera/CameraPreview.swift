import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    let stabilizationRevision: Int
    /// Foldable displays only: follow gravity instead of the interface orientation.
    let usesGravityRotation: Bool
    let stabilizationStatusChanged: (String) -> Void
    let focus: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.stabilizationStatusChanged = stabilizationStatusChanged
        view.configureOrientation(for: device, usesGravityRotation: usesGravityRotation)
        view.configureStabilization(for: device, revision: stabilizationRevision)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.layer.masksToBounds = true
        uiView.stabilizationStatusChanged = stabilizationStatusChanged
        uiView.configureOrientation(for: device, usesGravityRotation: usesGravityRotation)
        uiView.configureStabilization(for: device, revision: stabilizationRevision)
    }

    func makeCoordinator() -> Coordinator { Coordinator(focus: focus) }

    final class Coordinator: NSObject {
        let focus: (CGPoint) -> Void
        weak var view: PreviewView?

        init(focus: @escaping (CGPoint) -> Void) {
            self.focus = focus
        }

        @objc func didTap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            let layerPoint = recognizer.location(in: view)
            view.showFocusIndicator(at: layerPoint)
            focus(view.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint))
        }
    }
}

@MainActor
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private let focusIndicator = CAShapeLayer()
    private var hideFocusIndicatorTask: Task<Void, Never>?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationDeviceID: String?
    private var usesGravityRotation = false
    private var gravityRotationObservation: NSKeyValueObservation?
    private var stabilizationSignature = ""
    private var stabilizationObservation: NSKeyValueObservation?
    private var stabilizationFallbackTask: Task<Void, Never>?
    var stabilizationStatusChanged: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        focusIndicator.strokeColor = UIColor.systemYellow.cgColor
        focusIndicator.fillColor = UIColor.clear.cgColor
        focusIndicator.lineWidth = 2
        focusIndicator.cornerRadius = 4
        focusIndicator.isHidden = true
        layer.addSublayer(focusIndicator)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyPreviewRotation()
    }

    func configureOrientation(for device: AVCaptureDevice?, usesGravityRotation: Bool) {
        guard let device else { return }
        var needsObservation = self.usesGravityRotation != usesGravityRotation
        self.usesGravityRotation = usesGravityRotation
        if rotationDeviceID != device.uniqueID {
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                device: device,
                previewLayer: previewLayer
            )
            rotationDeviceID = device.uniqueID
            needsObservation = true
        }
        if needsObservation {
            gravityRotationObservation = nil
            if usesGravityRotation, let coordinator = rotationCoordinator {
                gravityRotationObservation = coordinator.observe(
                    \.videoRotationAngleForHorizonLevelPreview
                ) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.applyPreviewRotation() }
                }
            }
        }
        applyPreviewRotation()
    }

    func configureStabilization(for device: AVCaptureDevice?, revision: Int) {
        guard let device, let connection = previewLayer.connection else {
            stabilizationFallbackTask?.cancel()
            stabilizationObservation = nil
            stabilizationStatusChanged?("Initializing")
            return
        }
        let signature = "\(device.uniqueID)|\(revision)"
        guard signature != stabilizationSignature else { return }
        stabilizationSignature = signature
        stabilizationFallbackTask?.cancel()
        stabilizationObservation = nil

        guard connection.isVideoStabilizationSupported else {
            connection.preferredVideoStabilizationMode = .off
            stabilizationStatusChanged?("Unavailable")
            return
        }

        let candidates: [AVCaptureVideoStabilizationMode] = [
            .previewOptimized,
            .lowLatency,
            .standard
        ]
        let supportedModes = candidates.filter(device.activeFormat.isVideoStabilizationModeSupported)
        guard !supportedModes.isEmpty else {
            connection.preferredVideoStabilizationMode = .off
            stabilizationStatusChanged?("Unavailable")
            return
        }

        connection.preferredVideoStabilizationMode = supportedModes[0]
        reportStabilizationStatus(for: connection)
        stabilizationObservation = connection.observe(
            \.activeVideoStabilizationMode,
            options: [.new]
        ) { [weak self] connection, _ in
            Task { @MainActor [weak self] in
                self?.reportStabilizationStatus(for: connection)
            }
        }
        stabilizationFallbackTask = Task { @MainActor [weak self, weak connection] in
            guard let self, let connection else { return }
            for mode in supportedModes {
                guard !Task.isCancelled, self.stabilizationSignature == signature else { return }
                connection.preferredVideoStabilizationMode = mode
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                if connection.activeVideoStabilizationMode != .off {
                    break
                }
            }
            self.reportStabilizationStatus(for: connection)
        }
    }

    func showFocusIndicator(at point: CGPoint) {
        hideFocusIndicatorTask?.cancel()

        let side: CGFloat = 72
        focusIndicator.path = UIBezierPath(
            roundedRect: CGRect(
                x: point.x - side / 2,
                y: point.y - side / 2,
                width: side,
                height: side
            ),
            cornerRadius: 4
        ).cgPath
        focusIndicator.isHidden = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusIndicator.opacity = 1
        CATransaction.commit()

        hideFocusIndicatorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.2
            self.focusIndicator.add(fade, forKey: "focusFade")
            self.focusIndicator.opacity = 0
            self.focusIndicator.isHidden = true
        }
    }

    private func applyPreviewRotation() {
        guard let coordinator = rotationCoordinator else { return }

        let angle: CGFloat
        if usesGravityRotation {
            angle = coordinator.videoRotationAngleForHorizonLevelPreview
        } else {
            guard let interfaceOrientation = window?.windowScene?.effectiveGeometry.interfaceOrientation,
                  let videoOrientation = videoOrientation(for: interfaceOrientation) else {
                return
            }
            angle = coordinator.videoRotationAngleRelative(toDeviceOrientation: videoOrientation)
        }
        guard let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(angle) else {
            return
        }
        connection.videoRotationAngle = angle
    }

    private func reportStabilizationStatus(for connection: AVCaptureConnection) {
        let mode = connection.activeVideoStabilizationMode
        let status: String
        if mode == .off, previewLayer.session?.isRunning == false {
            status = "Initializing"
        } else {
            status = mode == .off ? "Off" : "Active (\(stabilizationModeName(mode)))"
        }
        stabilizationStatusChanged?(status)
    }

    private func stabilizationModeName(_ mode: AVCaptureVideoStabilizationMode) -> String {
        switch mode {
        case .off: "Off"
        case .standard: "Standard"
        case .cinematic: "Cinematic"
        case .cinematicExtended: "Cinematic Extended"
        case .auto: "Automatic"
        case .lowLatency: "Low Latency"
        case .previewOptimized: "Preview Optimized"
        case .cinematicExtendedEnhanced: "Cinematic Extended Enhanced"
        @unknown default: "Unknown"
        }
    }

    private func videoOrientation(for interfaceOrientation: UIInterfaceOrientation) -> AVCaptureVideoOrientation? {
        switch interfaceOrientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: nil
        }
    }
}
