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
    @ObservationIgnored private var focusTask: Task<Void, Never>?
    @ObservationIgnored private var exposureTask: Task<Bool, Never>?
    @ObservationIgnored private var lastShutterCapabilitySignature = ""
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var pendingCaptureMetadata: CameraMetadataSnapshot?
    @ObservationIgnored private var activeFormatOption: CameraFormatOption?
    @ObservationIgnored private var requestedAspectRatio: CaptureAspectRatio = .widescreen
    @ObservationIgnored private var recordingStabilizationObservation: NSKeyValueObservation?
    @ObservationIgnored private var recordingStabilizationTask: Task<Void, Never>?
    @ObservationIgnored private var recordingRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var recordingRotationDeviceID: String?
    /// Set from the view on foldable displays only; conventional iPhones keep the original behavior.
    @ObservationIgnored var isFoldableDisplay = false
    @ObservationIgnored private var interruptionTask: Task<Void, Never>?

    private(set) var lenses: [LensOption] = []
    private(set) var formats: [CameraFormatOption] = []
    private(set) var shutters: [ShutterChoice] = [.auto]
    private(set) var shutterRange: ShutterDurationRange?
    private(set) var isConfigured = false
    private(set) var isRecording = false
    private(set) var isStartingRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var currentISO: Float = 0
    private(set) var isTorchAvailable = false
    private(set) var isTorchOn = false
    private(set) var errorMessage: String?
    private(set) var completedSourceURL: URL?
    private(set) var completedCaptureMetadata: CameraMetadataSnapshot?
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var stabilizationRevision = 0

    var selectedLensID = ""
    var selectedFPS = 240
    var selectedShutter: ShutterChoice = .auto
    var recordAudio = true
    var limitsRecordingDuration = true
    var resolutionLabel = "—"
    var capabilityReport = "Camera not configured"
    var adjustableAperture = false
    var apertureStops: [Float] = []
    var selectedAperture: Float?
    private var previewStabilizationStatus = "Initializing"
    private var recordingStabilizationStatus = "Initializing"

    private let logger = Logger(subsystem: "ExtremeSloMo", category: "Camera")

    init() {
        delegateProxy.completion = { [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                self.timerTask?.cancel()
                self.timerTask = nil
                if let error, !Self.isMaximumDurationReached(error) {
                    self.logger.error("Recording finished with error: \(error.localizedDescription, privacy: .public)")
                    self.errorMessage = CameraError.recordingFailed(error.localizedDescription).localizedDescription
                    self.completedCaptureMetadata = nil
                } else if self.isSuspended {
                    try? FileManager.default.removeItem(at: url)
                    self.completedCaptureMetadata = nil
                } else {
                    self.logger.info("Recording finished successfully: \(url.lastPathComponent, privacy: .public)")
                    self.completedSourceURL = url
                    self.completedCaptureMetadata = self.pendingCaptureMetadata
                    Task { await self.logRecordedFrameRate(at: url) }
                }
                self.pendingCaptureMetadata = nil
            }
        }
    }

    func prepare() async {
        logger.info("Camera diagnostics v2 ready.")
        observeSessionInterruptions()
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
                reevaluateStabilization()
            } catch {
                errorMessage = CameraError.configurationFailed(error.localizedDescription).localizedDescription
            }
            return
        }
        await configure(device: lens.device, zoomFactor: lens.zoomFactor)
    }

    func selectFPS(_ fps: Int) async {
        guard !isRecording else { return }
        guard let option = formats.first(where: { $0.fps == fps }), let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            let previousZoom = device.videoZoomFactor
            device.activeFormat = option.format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            applyDynamicAspectRatio(to: device)
            if isFoldableDisplay {
                // Changing the format resets zoom to 1x, which silently switched the selected lens.
                device.videoZoomFactor = min(max(previousZoom, 1), device.activeFormat.videoMaxZoomFactor)
            }
            device.unlockForConfiguration()
            lockInputFrameDurationIfSupported(duration, for: device)
            selectedFPS = fps
            resolutionLabel = option.resolutionLabel
            activeFormatOption = option
            refreshShutterCapabilities(for: device)
            reevaluateStabilization()
            await applyExposure()
        } catch {
            errorMessage = CameraError.configurationFailed(error.localizedDescription).localizedDescription
        }
    }

    func setCaptureAspectRatio(_ aspectRatio: CaptureAspectRatio) {
        requestedAspectRatio = aspectRatio
        guard !isRecording, let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            applyDynamicAspectRatio(to: device)
            device.unlockForConfiguration()
            reevaluateStabilization()
        } catch {
            errorMessage = CameraError.configurationFailed(error.localizedDescription).localizedDescription
        }
    }

    @discardableResult
    func applyExposure() async -> Bool {
        exposureTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.applyExposureConfiguration()
        }
        exposureTask = task
        return await task.value
    }

    private func applyExposureConfiguration() async -> Bool {
        guard let device = activeDevice else { return false }
        refreshShutterCapabilities(for: device)
        logger.info("Applying exposure: shutter=\(self.selectedShutter.label, privacy: .public), ISO=auto")
        do {
            if let duration = selectedShutter.duration {
                guard isShutterSupported(selectedShutter) else {
                    throw CameraError.unsupportedExposure
                }
                if #available(iOS 26.0, *),
                   device.activeFormat.supportsExposureModeCustom(
                    lensAperture: AVCaptureDevice.currentLensAperture,
                    duration: duration,
                    iso: AVCaptureDevice.autoISO
                   ) {
                    try await setCustomExposure(
                        on: device,
                        lensAperture: AVCaptureDevice.currentLensAperture,
                        duration: duration,
                        iso: AVCaptureDevice.autoISO
                    )
                } else {
                    try await setCustomExposure(on: device, duration: duration, iso: device.iso)
                }
            } else {
                if #available(iOS 26.0, *), let selectedAperture,
                   device.activeFormat.supportsExposureModeCustom(
                    lensAperture: selectedAperture,
                    duration: AVCaptureDevice.autoExposureDuration,
                    iso: AVCaptureDevice.autoISO
                   ) {
                    try await setCustomExposure(
                        on: device,
                        lensAperture: selectedAperture,
                        duration: AVCaptureDevice.autoExposureDuration,
                        iso: AVCaptureDevice.autoISO
                    )
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    try device.lockForConfiguration()
                    device.exposureMode = .continuousAutoExposure
                    device.unlockForConfiguration()
                }
            }
            currentISO = device.iso
            let appliedDuration = device.exposureDuration.seconds
            let appliedDurationDescription = appliedDuration.isFinite
                ? "\(appliedDuration)"
                : "pending auto exposure"
            let isoControlDescription: String
            if #available(iOS 26.0, *) {
                isoControlDescription = device.automaticallyAdjustsISO ? "auto" : "locked"
            } else {
                isoControlDescription = "auto requested"
            }
            logger.info(
                "Exposure applied: mode=\(String(describing: device.exposureMode), privacy: .public), duration=\(appliedDurationDescription, privacy: .public), ISO=\(device.iso, privacy: .public), ISO control=\(isoControlDescription, privacy: .public)"
            )
            reevaluateStabilization()
            return true
        } catch {
            logger.error("Exposure application failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = CameraError.unsupportedExposure.localizedDescription
            return false
        }
    }

    private func setCustomExposure(
        on device: AVCaptureDevice,
        duration: CMTime,
        iso: Float
    ) async throws {
        try device.lockForConfiguration()
        device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
        device.unlockForConfiguration()
        await waitForExposure(on: device, requestedDuration: duration)
    }

    @available(iOS 26.0, *)
    private func setCustomExposure(
        on device: AVCaptureDevice,
        lensAperture: Float,
        duration: CMTime,
        iso: Float
    ) async throws {
        try device.lockForConfiguration()
        device.setExposureModeCustom(
            lensAperture: lensAperture,
            duration: duration,
            iso: iso,
            completionHandler: nil
        )
        device.unlockForConfiguration()
        await waitForExposure(on: device, requestedDuration: duration)
    }

    private func waitForExposure(on device: AVCaptureDevice, requestedDuration: CMTime) async {
        guard requestedDuration != AVCaptureDevice.autoExposureDuration,
              requestedDuration != AVCaptureDevice.currentExposureDuration else { return }

        for _ in 0..<100 {
            guard !Task.isCancelled else { return }
            let actual = device.exposureDuration.seconds
            let tolerance = exposureDurationTolerance(for: requestedDuration.seconds)
            if device.exposureMode == .custom,
               actual.isFinite,
               abs(actual - requestedDuration.seconds) <= tolerance {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func setShutterDuration(_ seconds: Double) async {
        guard let shutter = shutters.first(where: {
            guard let duration = $0.duration?.seconds else { return false }
            return abs(duration - seconds) < 0.000_000_001 && isShutterSupported($0)
        }) else { return }
        selectedShutter = shutter
        await applyExposure()
    }

    func setAutomaticExposure() async {
        selectedShutter = .auto
        await applyExposure()
    }

    func isShutterSupported(_ shutter: ShutterChoice) -> Bool {
        FormatSelection.isSupported(shutter, in: shutterRange)
    }

    private func refreshShutterCapabilities(for device: AVCaptureDevice) {
        let range = FormatSelection.shutterRange(for: device.activeFormat, at: selectedFPS)
        shutterRange = range
        shutters = FormatSelection.shutterChoices
        logShutterCapabilities(for: device, range: range)
        guard range != nil, case .denominator = selectedShutter,
              let seconds = selectedShutter.duration?.seconds else { return }
        let supportedChoices = shutters.filter { isShutterSupported($0) && $0.duration != nil }
        selectedShutter = supportedChoices.min {
            guard let lhs = $0.duration?.seconds, let rhs = $1.duration?.seconds else { return false }
            return abs(log(lhs / seconds)) < abs(log(rhs / seconds))
        } ?? .auto
    }

    private func logShutterCapabilities(for device: AVCaptureDevice, range: ShutterDurationRange?) {
        let supportedLabels = shutters.filter(isShutterSupported).map(\.label).joined(separator: ", ")
        let signature = "\(device.uniqueID)|\(selectedFPS)|\(range?.fastest ?? 0)|\(range?.slowest ?? 0)"
        guard signature != lastShutterCapabilitySignature else { return }
        lastShutterCapabilitySignature = signature
        logger.info(
            "Shutter capabilities: camera=\(device.localizedName, privacy: .public), fps=\(self.selectedFPS), fastest=\(range?.fastest ?? 0, privacy: .public)s, slowest=\(range?.slowest ?? 0, privacy: .public)s, enabled=\(supportedLabels, privacy: .public)"
        )
    }

    func setAperture(_ value: Float?) async {
        guard #available(iOS 26.0, *), let device = activeDevice else { return }
        if selectedAperture == nil, value == nil { return }
        if let selectedAperture, let value, abs(selectedAperture - value) < 0.001 { return }

        let aperture = value ?? AVCaptureDevice.autoLensAperture
        let duration = selectedShutter.duration ?? AVCaptureDevice.autoExposureDuration
        let iso = AVCaptureDevice.autoISO
        let format = device.activeFormat
        guard format.supportsExposureModeCustom(
            lensAperture: aperture,
            duration: duration,
            iso: iso
        ) else {
            errorMessage = CameraError.unsupportedExposure.localizedDescription
            return
        }
        do {
            try await setCustomExposure(
                on: device,
                lensAperture: aperture,
                duration: duration,
                iso: iso
            )
            selectedAperture = value
            reevaluateStabilization()
        } catch {
            errorMessage = CameraError.configurationFailed(error.localizedDescription).localizedDescription
        }
    }

    func focus(at point: CGPoint) {
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            let preservesManualExposure = self.selectedShutter.duration != nil
            self.logger.info(
                "Focus requested: shutter=\(self.selectedShutter.label, privacy: .public), torch=\(self.isTorchOn), preservesManualExposure=\(preservesManualExposure)"
            )
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if !preservesManualExposure,
                       device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
            } catch {
                self.logger.error("Focus configuration failed: \(error.localizedDescription)")
                return
            }

            for _ in 0..<100 where device.isAdjustingFocus && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled else { return }
            await self.applyExposure()
            self.logger.info(
                "Focus finished: shutter=\(self.selectedShutter.label, privacy: .public), duration=\(device.exposureDuration.seconds, privacy: .public)s"
            )
        }
    }

    func setTorchEnabled(_ enabled: Bool) async {
        guard let device = activeDevice,
              device.hasTorch,
              device.isTorchModeSupported(enabled ? .on : .off) else {
            isTorchAvailable = false
            isTorchOn = false
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = enabled ? .on : .off
            device.unlockForConfiguration()
            isTorchAvailable = true
            isTorchOn = enabled
            await applyExposure()
        } catch {
            errorMessage = CameraError.configurationFailed(error.localizedDescription).localizedDescription
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
        reevaluateStabilization()
    }

    func startRecording() async {
        logger.info("Recording requested.")
        guard isConfigured, !isStartingRecording, !isRecording, !movieOutput.isRecording, !isSuspended else {
            logger.error(
                "Recording start rejected: configured=\(self.isConfigured), starting=\(self.isStartingRecording), stateRecording=\(self.isRecording), outputRecording=\(self.movieOutput.isRecording), suspended=\(self.isSuspended)"
            )
            return
        }
        isStartingRecording = true
        defer { isStartingRecording = false }
        errorMessage = nil
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
            .appending(path: "1920slomo-\(UUID().uuidString).mov")
        completedSourceURL = nil
        completedCaptureMetadata = nil
        elapsed = 0
        if let focusTask {
            await focusTask.value
        }
        if !isRequestedExposureApplied {
            guard await applyExposure() else {
                logger.error("Recording start rejected because exposure could not be restored.")
                return
            }
        }

        updateOrientation()
        pendingCaptureMetadata = captureMetadataSnapshot()
        movieOutput.maxRecordedDuration = limitsRecordingDuration
            ? CMTime(seconds: 4, preferredTimescale: 600)
            : .invalid
        movieOutput.startRecording(to: url, recordingDelegate: delegateProxy)
        logger.info("Recording started at \(url.lastPathComponent, privacy: .public)")
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

    private var isRequestedExposureApplied: Bool {
        guard let device = activeDevice else { return false }
        guard let requestedDuration = selectedShutter.duration else {
            return device.exposureMode == .continuousAutoExposure
        }
        guard device.exposureMode == .custom else { return false }
        let tolerance = exposureDurationTolerance(for: requestedDuration.seconds)
        return abs(device.exposureDuration.seconds - requestedDuration.seconds) <= tolerance
    }

    private func exposureDurationTolerance(for requestedSeconds: Double) -> Double {
        // Camera hardware represents very short exposures in discrete increments. At
        // 1/8000, the nearest duration can differ by several microseconds even after
        // AVFoundation has successfully applied the request.
        max(requestedSeconds * 0.02, 0.000_010)
    }

    func consumeCompletedURL() -> URL? {
        defer { completedSourceURL = nil }
        return completedSourceURL
    }

    func consumeCompletedCaptureMetadata() -> CameraMetadataSnapshot? {
        defer { completedCaptureMetadata = nil }
        return completedCaptureMetadata
    }

    private func captureMetadataSnapshot() -> CameraMetadataSnapshot? {
        guard let device = activeDevice else { return nil }
        let exposureDuration = device.exposureDuration.seconds
        let aperture = Double(device.lensAperture)
        let iso = Double(device.iso)
        let temperature = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature
        logger.info(
            "Recording metadata snapshot: camera=\(device.localizedName, privacy: .public), aperture=\(aperture, privacy: .public), shutter=\(exposureDuration, privacy: .public)s, ISO=\(iso, privacy: .public), WB=\(temperature, privacy: .public)K"
        )
        return CameraMetadataSnapshot(
            manufacturer: "Apple",
            // AVFoundation doesn't expose the retail iPhone name. Internal machine
            // identifiers such as "iPhone19,3" aren't suitable camera-model metadata.
            deviceModel: nil,
            cameraIdentifier: Self.cameraIdentifier(for: device.deviceType),
            lensModel: device.localizedName,
            aperture: aperture.isFinite && aperture > 0 ? aperture : nil,
            exposureDuration: exposureDuration.isFinite && exposureDuration > 0 ? exposureDuration : nil,
            iso: iso.isFinite && iso > 0 ? iso : nil,
            whiteBalanceTemperature: temperature.isFinite && temperature > 0 ? Double(temperature) : nil
        )
    }

    private static func cameraIdentifier(for type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInUltraWideCamera: "Ultra Wide"
        case .builtInWideAngleCamera: "Wide"
        case .builtInTelephotoCamera: "Telephoto"
        default: type.rawValue
        }
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
            isTorchAvailable = device.hasTorch && device.isTorchModeSupported(.on)
            if !isTorchAvailable { isTorchOn = false }
            formats = options
            isConfigured = true
            try device.lockForConfiguration()
            device.activeFormat = best.format
            let duration = CMTime(value: 1, timescale: CMTimeScale(best.fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            applyDynamicAspectRatio(to: device)
            device.videoZoomFactor = min(max(zoomFactor, 1), device.activeFormat.videoMaxZoomFactor)
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
            lockInputFrameDurationIfSupported(duration, for: device)
            selectedFPS = best.fps
            resolutionLabel = best.resolutionLabel
            activeFormatOption = best
            refreshShutterCapabilities(for: device)
            rebuildZoomOptions(
                wideCamera: discoveredDevices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? device,
                ultraWideCamera: discoveredDevices.first(where: { $0.deviceType == .builtInUltraWideCamera }),
                telephotoCamera: discoveredDevices.first(where: { $0.deviceType == .builtInTelephotoCamera })
            )
            inspectAperture(device)
            reevaluateStabilization()
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
            }
            if isTorchOn {
                await setTorchEnabled(true)
            }
            await applyExposure()
        } catch {
            session.commitConfiguration()
            errorMessage = CameraError.configurationFailed(error.localizedDescription).localizedDescription
        }
    }

    private func applyDynamicAspectRatio(to device: AVCaptureDevice) {
        guard #available(iOS 26.0, *) else { return }
        let target: AVCaptureDevice.AspectRatio = requestedAspectRatio == .standard ? .ratio4x3 : .ratio16x9
        guard device.activeFormat.supportedDynamicAspectRatios.contains(target),
              device.dynamicAspectRatio != target else {
            return
        }
        device.setDynamicAspectRatio(target)
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
        if isFoldableDisplay, let device = activeDevice {
            // Foldable displays: follow the physical orientation relative to gravity.
            if recordingRotationDeviceID != device.uniqueID {
                recordingRotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                recordingRotationDeviceID = device.uniqueID
            }
            guard let gravityAngle = recordingRotationCoordinator?.videoRotationAngleForHorizonLevelCapture else { return }
            angle = gravityAngle
        } else {
            switch UIDevice.current.orientation {
            case .landscapeLeft: angle = 0
            case .landscapeRight: angle = 180
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
        }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }

    /// Reports genuine session interruptions (for example another foreground app holding the
    /// camera in a multitasking layout). The session resumes on its own when they end, and an
    /// in-progress recording is finalized by the movie output rather than restarted here.
    private func observeSessionInterruptions() {
        guard interruptionTask == nil else { return }
        interruptionTask = Task { [weak self, session] in
            let center = NotificationCenter.default
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await note in center.notifications(named: AVCaptureSession.wasInterruptedNotification, object: session) {
                        let reasonValue = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
                        let reason = reasonValue.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
                        await self?.handleInterruption(reason)
                    }
                }
                group.addTask {
                    for await _ in center.notifications(named: AVCaptureSession.interruptionEndedNotification, object: session) {
                        await self?.handleInterruptionEnded()
                    }
                }
            }
        }
    }

    private func handleInterruption(_ reason: AVCaptureSession.InterruptionReason?) {
        logger.info("Capture session interrupted: \(reason.map { String(describing: $0) } ?? "unknown", privacy: .public)")
        if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
            errorMessage = "The camera isn't available while another app is open beside 1920SloMo. Use 1920SloMo full screen to record."
        }
    }

    private func handleInterruptionEnded() {
        logger.info("Capture session interruption ended.")
        if errorMessage?.hasPrefix("The camera isn't available while another app") == true {
            errorMessage = nil
        }
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
        Preview stabilization: \(previewStabilizationStatus)
        Recording stabilization: \(recordingStabilizationStatus)
        Available lenses: \(lenses.map(\.name).joined(separator: ", "))
        Codec: HEVC where supported
        """
    }

    func updatePreviewStabilizationStatus(_ status: String) {
        guard previewStabilizationStatus != status else { return }
        previewStabilizationStatus = status
        refreshCapabilityReport()
    }

    func reevaluateStabilization() {
        stabilizationRevision &+= 1
        configureRecordingStabilization()
        refreshCapabilityReport()
    }

    private func configureRecordingStabilization() {
        recordingStabilizationTask?.cancel()
        recordingStabilizationObservation = nil
        guard let device = activeDevice,
              let connection = movieOutput.connection(with: .video) else {
            recordingStabilizationStatus = isConfigured ? "Unavailable" : "Initializing"
            return
        }
        guard connection.isVideoStabilizationSupported else {
            connection.preferredVideoStabilizationMode = .off
            recordingStabilizationStatus = "Unavailable"
            return
        }

        let candidates: [AVCaptureVideoStabilizationMode] = selectedFPS > 60
            ? [.lowLatency, .standard]
            : [.standard, .lowLatency]
        let supportedModes = candidates.filter(device.activeFormat.isVideoStabilizationModeSupported)
        guard !supportedModes.isEmpty else {
            connection.preferredVideoStabilizationMode = .off
            recordingStabilizationStatus = "Unavailable"
            return
        }

        connection.preferredVideoStabilizationMode = supportedModes[0]
        recordingStabilizationStatus = connection.activeVideoStabilizationMode == .off && !session.isRunning
            ? "Initializing"
            : Self.stabilizationStatus(
                activeMode: connection.activeVideoStabilizationMode,
                isSupported: true
            )
        recordingStabilizationObservation = connection.observe(
            \.activeVideoStabilizationMode,
            options: [.new]
        ) { [weak self] connection, _ in
            let status = Self.stabilizationStatus(
                activeMode: connection.activeVideoStabilizationMode,
                isSupported: true
            )
            Task { @MainActor [weak self] in
                guard let self, self.recordingStabilizationStatus != status else { return }
                self.recordingStabilizationStatus = status
                self.refreshCapabilityReport()
            }
        }
        recordingStabilizationTask = Task { @MainActor [weak self, weak connection] in
            guard let self, let connection else { return }
            for mode in supportedModes {
                guard !Task.isCancelled else { return }
                connection.preferredVideoStabilizationMode = mode
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                if connection.activeVideoStabilizationMode != .off {
                    break
                }
            }
            self.recordingStabilizationStatus = Self.stabilizationStatus(
                activeMode: connection.activeVideoStabilizationMode,
                isSupported: true
            )
            self.refreshCapabilityReport()
            self.logger.info(
                "Recording stabilization requested=\(Self.stabilizationModeName(connection.preferredVideoStabilizationMode), privacy: .public), active=\(Self.stabilizationModeName(connection.activeVideoStabilizationMode), privacy: .public)"
            )
        }
    }

    private func refreshCapabilityReport() {
        guard let device = activeDevice, let option = activeFormatOption else { return }
        updateCapabilityReport(device: device, option: option)
    }

    private func lockInputFrameDurationIfSupported(
        _ duration: CMTime,
        for device: AVCaptureDevice
    ) {
        guard #available(iOS 26.0, *),
              let input = session.inputs
                .compactMap({ $0 as? AVCaptureDeviceInput })
                .first(where: { $0.device.uniqueID == device.uniqueID }),
              input.isLockedVideoFrameDurationSupported,
              device.minSupportedLockedVideoFrameDuration.isValid,
              CMTimeCompare(duration, device.minSupportedLockedVideoFrameDuration) >= 0 else {
            return
        }
        input.activeLockedVideoFrameDuration = duration
        logger.info(
            "Locked input frame rate: requested=\(1 / duration.seconds, privacy: .public) FPS, active=\(1 / input.activeLockedVideoFrameDuration.seconds, privacy: .public) FPS"
        )
    }

    private func logRecordedFrameRate(at url: URL) async {
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let nominalFrameRate = try await track.load(.nominalFrameRate)
            let minimumFrameDuration = try await track.load(.minFrameDuration)
            let minimumFrameRate = minimumFrameDuration.seconds > 0
                ? 1 / minimumFrameDuration.seconds
                : 0
            logger.info(
                "Recorded frame rate: selected=\(self.selectedFPS) FPS, nominal=\(nominalFrameRate, privacy: .public) FPS, minimum-frame-rate=\(minimumFrameRate, privacy: .public) FPS"
            )
        } catch {
            logger.error("Unable to inspect recorded frame rate: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func stabilizationStatus(
        activeMode: AVCaptureVideoStabilizationMode,
        isSupported: Bool
    ) -> String {
        guard isSupported else { return "Unavailable" }
        guard activeMode != .off else { return "Off" }
        return "Active (\(stabilizationModeName(activeMode)))"
    }

    nonisolated private static func stabilizationModeName(_ mode: AVCaptureVideoStabilizationMode) -> String {
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
