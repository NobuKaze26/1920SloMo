@preconcurrency import AVFoundation
import Observation
import OSLog
import UIKit

@MainActor
@Observable
final class CameraManager {
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "ExtremeSloMo.camera.session", qos: .userInitiated)
    @ObservationIgnored private let movieOutput = AVCaptureMovieFileOutput()
    @ObservationIgnored private let delegateProxy = RecordingDelegate()
    @ObservationIgnored private var activeDevice: AVCaptureDevice?
    @ObservationIgnored private var discoveredDevices: [AVCaptureDevice] = []

    private(set) var previewDevice: AVCaptureDevice?
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    private(set) var lenses: [LensOption] = []
    private(set) var formats: [CameraFormatOption] = []
    private(set) var shutters: [ShutterChoice] = [.auto]
    private(set) var isConfigured = false
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var currentISO: Float = 0
    private(set) var errorMessage: String?
    private(set) var completedSourceURL: URL?
    private(set) var thermalState = ProcessInfo.processInfo.thermalState

    var selectedLensID = ""
    var selectedFPS = 60
    var selectedShutter: ShutterChoice = .auto
    var manualISO = false
    var requestedISO: Float = 100
    var recordAudio = true
    var resolutionLabel = "—"
    var capabilityReport = "Camera not configured"
    var adjustableAperture = false
    var apertureStops: [Float] = []
    var selectedAperture: Float?

    private let logger = Logger(subsystem: "ExtremeSloMo", category: "Camera")

    init() {
        delegateProxy.completion = { [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                self.timerTask?.cancel()
                if let error {
                    self.errorMessage = CameraError.recordingFailed(error.localizedDescription).localizedDescription
                } else {
                    self.completedSourceURL = url
                }
            }
        }
    }

    func prepare() async {
        let cameraGranted = await requestCameraAccess()
        guard cameraGranted else {
            errorMessage = CameraError.permissionDenied.localizedDescription
            return
        }
        if recordAudio { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        discoverLenses()
        guard let first = lenses.first else {
            errorMessage = CameraError.cameraUnavailable.localizedDescription
            return
        }
        selectedLensID = first.id
        await configure(device: first.device, zoomFactor: first.zoomFactor)
    }

    func selectLens(_ lens: LensOption) async {
        guard !isRecording else { return }
        selectedLensID = lens.id
        await configure(device: lens.device, zoomFactor: lens.zoomFactor)
    }

    func selectFPS(_ fps: Int) async {
        guard let option = formats.first(where: { $0.fps == fps }), let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = option.format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            selectedFPS = fps
            resolutionLabel = option.resolutionLabel
            shutters = FormatSelection.supportedShutters(for: option.format, at: fps)
            if !shutters.contains(selectedShutter) { selectedShutter = .auto }
            updateCapabilityReport(device: device, option: option)
            await applyExposure()
        } catch {
            errorMessage = CameraError.configurationFailed(error.localizedDescription).localizedDescription
        }
    }

    func applyExposure() async {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if let duration = selectedShutter.duration {
                guard duration.seconds >= device.activeFormat.minExposureDuration.seconds,
                      duration.seconds <= device.activeFormat.maxExposureDuration.seconds else {
                    throw CameraError.unsupportedExposure
                }
                let iso: Float
                if manualISO {
                    iso = min(max(requestedISO, device.activeFormat.minISO), device.activeFormat.maxISO)
                } else {
                    iso = min(max(device.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
                }
                if #available(iOS 26.0, *),
                   device.activeFormat.supportsExposureModeCustom(
                    lensAperture: AVCaptureDevice.currentLensAperture,
                    duration: duration,
                    iso: manualISO ? iso : AVCaptureDevice.autoISO
                   ) {
                    await device.setExposureModeCustom(
                        lensAperture: AVCaptureDevice.currentLensAperture,
                        duration: duration,
                        iso: manualISO ? iso : AVCaptureDevice.autoISO
                    )
                } else {
                    await device.setExposureModeCustom(duration: duration, iso: iso)
                }
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            currentISO = device.iso
        } catch {
            errorMessage = CameraError.unsupportedExposure.localizedDescription
        }
    }

    func setISO(_ value: Float) async {
        requestedISO = value
        manualISO = true
        await applyExposure()
    }

    func setAperture(_ value: Float?) async {
        guard #available(iOS 26.0, *), let device = activeDevice else { return }
        let aperture = value ?? AVCaptureDevice.autoLensAperture
        let format = device.activeFormat
        guard format.supportsExposureModeCustom(
            lensAperture: aperture,
            duration: AVCaptureDevice.autoExposureDuration,
            iso: AVCaptureDevice.autoISO
        ) else {
            errorMessage = CameraError.unsupportedExposure.localizedDescription
            return
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            await device.setExposureModeCustom(
                lensAperture: aperture,
                duration: AVCaptureDevice.autoExposureDuration,
                iso: AVCaptureDevice.autoISO
            )
            selectedAperture = value
        } catch {
            errorMessage = CameraError.configurationFailed(error.localizedDescription).localizedDescription
        }
    }

    func focus(at point: CGPoint) {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            logger.error("Focus configuration failed: \(error.localizedDescription)")
        }
    }

    func startRecording() async {
        guard isConfigured, !isRecording else { return }
        thermalState = ProcessInfo.processInfo.thermalState
        guard thermalState != .critical else {
            errorMessage = "The iPhone is too hot to begin another recording."
            return
        }
        do {
            let values = try URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if (values.volumeAvailableCapacityForImportantUsage ?? 0) < 500_000_000 {
                throw CameraError.insufficientStorage
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appending(path: "capture-\(UUID().uuidString).mov")
        completedSourceURL = nil
        elapsed = 0
        updateOrientation()
        movieOutput.startRecording(to: url, recordingDelegate: delegateProxy)
        isRecording = true
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.1))
                guard let self else { return }
                self.elapsed = self.movieOutput.recordedDuration.seconds
                self.currentISO = self.activeDevice?.iso ?? 0
            }
        }
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    func consumeCompletedURL() -> URL? {
        defer { completedSourceURL = nil }
        return completedSourceURL
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    private func discoverLenses() {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera
        ]
        discoveredDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .back
        ).devices
        guard let wideCamera = discoveredDevices.first(where: { $0.deviceType == .builtInWideAngleCamera }) else {
            lenses = []
            return
        }
        let ultraWideCamera = discoveredDevices.first(where: { $0.deviceType == .builtInUltraWideCamera })
        rebuildZoomOptions(wideCamera: wideCamera, ultraWideCamera: ultraWideCamera, maxZoom: wideCamera.activeFormat.videoMaxZoomFactor)
    }

    private func rebuildZoomOptions(
        wideCamera: AVCaptureDevice,
        ultraWideCamera: AVCaptureDevice?,
        maxZoom: CGFloat
    ) {
        var options: [LensOption] = []
        if let ultraWideCamera {
            options.append(
                LensOption(
                    id: "\(ultraWideCamera.uniqueID)-0.5",
                    name: "0.5×",
                    deviceType: ultraWideCamera.deviceType,
                    device: ultraWideCamera,
                    zoomFactor: 1
                )
            )
        }

        let supportedMaxZoom = ultraWideCamera == nil ? min(maxZoom, 2) : maxZoom
        for zoom in [1, 2, 4, 8] where supportedMaxZoom >= CGFloat(zoom) {
            options.append(
                LensOption(
                    id: "\(wideCamera.uniqueID)-\(zoom)",
                    name: "\(zoom)×",
                    deviceType: wideCamera.deviceType,
                    device: wideCamera,
                    zoomFactor: CGFloat(zoom)
                )
            )
        }
        lenses = options
    }

    private func configure(device: AVCaptureDevice, zoomFactor: CGFloat = 1) async {
        let options = FormatSelection.options(for: device)
        guard let best = FormatSelection.bestOption(in: options, preferredFPS: selectedFPS) else {
            errorMessage = CameraError.unsupportedFrameRate.localizedDescription
            return
        }

        session.stopRunning()
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        do {
            let videoInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(videoInput), session.canAddOutput(movieOutput) else {
                throw CameraError.configurationFailed("Unable to attach camera input or movie output.")
            }
            session.addInput(videoInput)
            if recordAudio,
               let microphone = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: microphone),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
            }
            session.addOutput(movieOutput)
            session.commitConfiguration()
            activeDevice = device
            previewDevice = device
            formats = options
            isConfigured = true
            try device.lockForConfiguration()
            device.activeFormat = best.format
            let duration = CMTime(value: 1, timescale: CMTimeScale(best.fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.videoZoomFactor = min(max(zoomFactor, 1), device.activeFormat.videoMaxZoomFactor)
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
            selectedFPS = best.fps
            resolutionLabel = best.resolutionLabel
            shutters = FormatSelection.supportedShutters(for: best.format, at: best.fps)
            rebuildZoomOptions(
                wideCamera: discoveredDevices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? device,
                ultraWideCamera: discoveredDevices.first(where: { $0.deviceType == .builtInUltraWideCamera }),
                maxZoom: device.activeFormat.videoMaxZoomFactor
            )
            inspectAperture(device)
            updateCapabilityReport(device: device, option: best)
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
            }
        } catch {
            session.commitConfiguration()
            errorMessage = CameraError.configurationFailed(error.localizedDescription).localizedDescription
        }
    }

    private func inspectAperture(_ device: AVCaptureDevice) {
        adjustableAperture = false
        apertureStops = []
        selectedAperture = nil
        if #available(iOS 26.0, *) {
            let format = device.activeFormat
            let stops = format.recommendedLensApertureStops
            adjustableAperture = !stops.isEmpty && format.minLensAperture != format.maxLensAperture
            apertureStops = stops
            selectedAperture = adjustableAperture ? device.lensAperture : nil
        }
    }

    private func updateOrientation() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        let angle: CGFloat
        switch UIDevice.current.orientation {
        case .landscapeLeft: angle = 0
        case .landscapeRight: angle = 180
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }

    private func updateCapabilityReport(device: AVCaptureDevice, option: CameraFormatOption) {
        let rangeText = option.format.videoSupportedFrameRateRanges
            .map { "\(Int($0.minFrameRate))–\(Int($0.maxFrameRate))" }
            .joined(separator: ", ")
        capabilityReport = """
        Current camera: \(device.localizedName)
        Active format: \(option.resolutionLabel) • \(option.fps) FPS
        Resolution: \(option.dimensions.width) × \(option.dimensions.height)
        Supported FPS ranges: \(rangeText)
        Exposure: \(option.format.minExposureDuration.seconds.formatted())–\(option.format.maxExposureDuration.seconds.formatted()) s
        ISO: \(option.format.minISO.formatted())–\(option.format.maxISO.formatted())
        Lens aperture: f/\(device.lensAperture.formatted())
        Adjustable aperture: \(adjustableAperture ? "Yes" : "No")
        Available lenses: \(lenses.map(\.name).joined(separator: ", "))
        Codec: HEVC where supported
        """
    }
}

private final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    var completion: ((URL, Error?) -> Void)?

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        completion?(outputFileURL, error)
    }
}
