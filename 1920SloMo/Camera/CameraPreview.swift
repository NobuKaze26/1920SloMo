import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    let focus: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.configureOrientation(for: device)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.layer.masksToBounds = true
        uiView.configureOrientation(for: device)
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

    func configureOrientation(for device: AVCaptureDevice?) {
        guard let device else { return }
        if rotationDeviceID != device.uniqueID {
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                device: device,
                previewLayer: previewLayer
            )
            rotationDeviceID = device.uniqueID
        }
        applyPreviewRotation()
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
        guard let coordinator = rotationCoordinator,
              let interfaceOrientation = window?.windowScene?.effectiveGeometry.interfaceOrientation,
              let videoOrientation = videoOrientation(for: interfaceOrientation) else {
            return
        }

        let angle = coordinator.videoRotationAngleRelative(toDeviceOrientation: videoOrientation)
        guard let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(angle) else {
            return
        }
        connection.videoRotationAngle = angle
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
