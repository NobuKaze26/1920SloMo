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
    @ObservationIgnored private var isSuspended = false

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
    var selectedFPS = 240
    var selectedShutter: ShutterChoice = .auto
    var manualISO = false
    var requestedISO: Float = 100
    var recordAudio = true
    var limitsRecordingDuration = true
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
                if let error, !Self.isMaximumDurationReached(error) {
                    self.errorMessage = CameraError.recordingFailed(error.localizedDescription).localizedDescription
                } else if self.isSuspended {
                    try? FileManager.default.removeItem(at: url)
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
        errorMessage = nil
        if recordAudio { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        discoverLenses()
        guard let widestLens = lenses.min(by: { $0.zoomFactor < $1.zoomFactor }) else {
            errorMessage = CameraError.cameraUnavailable.localizedDescription
            return
        }
        selectedLensID = widestLens.id
        await configure(device: widestLens.device, zoomFactor: widestLens.zoomFactor)
    }

    func selectLens(_ lens: LensOption) async {
        guard !isRecording else { return }
        selectedLensID = lens.id
        if activeDevice?.uniqueID == lens.device.uniqueID {
            do {
                try lens.device.lockForConfiguration()
                lens.device.videoZoomFactor = min(
                    max(lens.zoomFactor, 1),
                    lens.device.activeFormat.videoMaxZoomFactor
                )
                lens.device.unlockForConfiguration()
            } catch {
                errorMessage = CameraError.configurationFailed(error.localizedDescription).localizedDescription
            }
            return
        }
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
            let iso = min(max(requestedISO, device.activeFormat.minISO), device.activeFormat.maxISO)

            if manualISO {
                if #available(iOS 26.0, *) {
                    let duration = selectedShutter.duration ?? AVCaptureDevice.autoExposureDuration
                    if device.activeFormat.supportsExposureModeCustom(
                        lensAperture: AVCaptureDevice.autoLensAperture,
                        duration: duration,
                        iso: iso
                    ) {
                        await device.setExposureModeCustom(
                            lensAperture: AVCaptureDevice.autoLensAperture,
                            duration: duration,
                            iso: iso
                        )
                    } else if device.isExposureModeSupported(.custom) {
                        // This format cannot use an ISO-priority combination. Lock its current
                        // shutter duration so the requested ISO still takes effect reliably.
                        await device.setExposureModeCustom(
                            duration: selectedShutter.duration ?? AVCaptureDevice.currentExposureDuration,
                            iso: iso
                        )
                    } else {
                        throw CameraError.configurationFailed(
                            "The active camera format does not support manual ISO."
                        )
                    }
                } else {
                    let duration = selectedShutter.duration ?? device.exposureDuration
                    await device.setExposureModeCustom(duration: duration, iso: iso)
                }
            } else if let duration = selectedShutter.duration {
                guard duration.seconds >= device.activeFormat.minExposureDuration.seconds,
                      duration.seconds <= device.activeFormat.maxExposureDuration.seconds else {
                    throw CameraError.unsupportedExposure
                }
                if #available(iOS 26.0, *),
                   device.activeFormat.supportsExposureModeCustom(
                    lensAperture: AVCaptureDevice.currentLensAperture,
                    duration: duration,
                    iso: AVCaptureDevice.autoISO
                   ) {
                    await device.setExposureModeCustom(
                        lensAperture: AVCaptureDevice.currentLensAperture,
                        duration: duration,
                        iso: AVCaptureDevice.autoISO
                    )
                } else {
                    await device.setExposureModeCustom(duration: duration, iso: device.iso)
                }
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            currentISO = device.iso
        } catch {
            errorMessage = manualISO
                ? "Manual ISO is not supported by the active camera format."
                : CameraError.unsupportedExposure.localizedDescription
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

    func pausePreview() {
        guard !isRecording else { return }
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func suspend() {
        isSuspended = true
        timerTask?.cancel()
        timerTask = nil
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func resume() {
        isSuspended = false
        guard isConfigured else { return }
        sessionQueue.async { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func startRecording() async {
        guard isConfigured, !isRecording, !isSuspended else { return }
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
        movieOutput.maxRecordedDuration = limitsRecordingDuration
            ? CMTime(seconds: 4, preferredTimescale: 600)
            : .invalid
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

    private static func isMaximumDurationReached(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == AVFoundationErrorDomain
            && nsError.code == AVError.Code.maximumDurationReached.rawValue
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
        let telephotoCamera = discoveredDevices.first(where: { $0.deviceType == .builtInTelephotoCamera })
        rebuildZoomOptions(
            wideCamera: wideCamera,
            ultraWideCamera: ultraWideCamera,
            telephotoCamera: telephotoCamera
        )
    }

    private func rebuildZoomOptions(
        wideCamera: AVCaptureDevice,
        ultraWideCamera: AVCaptureDevice?,
        telephotoCamera: AVCaptureDevice?
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

        for zoom in [1, 2] where wideCamera.activeFormat.videoMaxZoomFactor >= CGFloat(zoom) {
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
        if let telephotoCamera {
            options.append(
                LensOption(
                    id: "\(telephotoCamera.uniqueID)-4",
                    name: "4×",
                    deviceType: telephotoCamera.deviceType,
                    device: telephotoCamera,
                    zoomFactor: 1
                )
            )
            if telephotoCamera.activeFormat.videoMaxZoomFactor >= 2 {
                options.append(
                    LensOption(
                        id: "\(telephotoCamera.uniqueID)-8",
                        name: "8×",
                        deviceType: telephotoCamera.deviceType,
                        device: telephotoCamera,
                        zoomFactor: 2
                    )
                )
            }
        }
        lenses = options
    }

    private func configure(device: AVCaptureDevice, zoomFactor: CGFloat = 1) async {
        let options = FormatSelection.options(for: device)
        guard let best = FormatSelection.bestOption(in: options, preferredFPS: selectedFPS) else {
            errorMessage = CameraError.unsupportedFrameRate.localizedDescription
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        let previousVideoInput = session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first(where: { $0.device.hasMediaType(.video) })
        if let previousVideoInput {
            session.removeInput(previousVideoInput)
        }
        do {
            let videoInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(videoInput) else {
                if let previousVideoInput, session.canAddInput(previousVideoInput) {
                    session.addInput(previousVideoInput)
                }
                throw CameraError.configurationFailed("Unable to attach camera input.")
            }
            session.addInput(videoInput)
            if session.outputs.isEmpty {
                guard session.canAddOutput(movieOutput) else {
                    throw CameraError.configurationFailed("Unable to attach movie output.")
                }
                session.addOutput(movieOutput)
            }
            if session.inputs.count == 1, recordAudio,
               let microphone = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: microphone),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
            }
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
                telephotoCamera: discoveredDevices.first(where: { $0.deviceType == .builtInTelephotoCamera })
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
            let lensSupportsApertureControl = device.deviceType == .builtInWideAngleCamera
            adjustableAperture = lensSupportsApertureControl
                && !stops.isEmpty
                && format.minLensAperture != format.maxLensAperture
            apertureStops = stops
            selectedAperture = adjustableAperture
                ? stops.min(by: {
                    abs($0 - device.lensAperture) < abs($1 - device.lensAperture)
                })
                : nil
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
