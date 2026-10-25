import AVFoundation
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.layoutDirection) private var layoutDirection
    @Bindable var camera: CameraManager

    @AppStorage("saveOriginal") private var saveOriginal = true
    @AppStorage("audioRecording") private var audioRecording = true
    @AppStorage("keepScreenAwake") private var keepScreenAwake = true
    @AppStorage("removesFourSecondRecordingLimit") private var removesFourSecondRecordingLimit = false
    @AppStorage("hideUI") private var hideUI = false

    @State private var interpolation: InterpolationMultiplier =
        FrameInterpolationProcessor.isAppleInterpolationAvailable ? .eight : .off
    @State private var playbackFPS: PlaybackFPS = .thirty
    @State private var aspectRatio: CaptureAspectRatio = .widescreen
    @State private var quality: InterpolationQuality = .quality
    @State private var controlsExpanded = false
    @State private var showingInstructions = false
    @State private var showingNoVideoAlert = false
    @State private var isProcessing = false
    @State private var processingProgress = 0.0
    @State private var processingTask: Task<Void, Never>?
    @State private var result: RecordingResult?
    @State private var showingReview = false
    @State private var showingStoragePicker = false
    @State private var storageDestination = StorageDestinationManager()
    @State private var alertMessage: String?
    @State private var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    @State private var settingsDestination: SettingsDestination?
    @State private var hingeInsets = HingeInsets.zero

    private let interpolationAvailable = FrameInterpolationProcessor.isAppleInterpolationAvailable

    var body: some View {
        ZStack {
            ResponsiveAppBackground()
            // Full-bleed, non-interactive probe; must not share the padded overlay's bounds.
            HingeProbe(insets: $hingeInsets)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            GeometryReader { proxy in
                CameraPreview(
                    session: camera.session,
                    device: camera.previewDevice,
                    stabilizationRevision: camera.stabilizationRevision,
                    usesGravityRotation: hingeInsets.isFoldable,
                    stabilizationStatusChanged: camera.updatePreviewStabilizationStatus,
                    focus: camera.focus
                )
                .aspectRatio(viewfinderAspectRatio(for: proxy.size), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .ignoresSafeArea()

            if cameraAuthorizationStatus != .authorized {
                CameraPermissionMessage(openSettings: openAppSettings)
            }

            VStack(spacing: isCompactHeight ? 6 : 12) {
                CameraHeader(
                    resolution: camera.resolutionLabel,
                    realFPS: camera.selectedFPS,
                    equivalentFPS: equivalentFPS,
                    externalDriveAvailable: storageDestination.isExternalDriveAvailable,
                    hasMissingPermissions: hasMissingPermissions,
                    hidesNonessentialUI: hidesNonessentialUI,
                    settings: {
                        settingsDestination = .general
                    },
                    showPermissionWarnings: {
                        settingsDestination = .general
                    },
                    chooseStorage: showStoragePicker
                )
                Spacer(minLength: hingeInsets.gap > 0 ? hingeInsets.gap : nil)
                if camera.isRecording && !hidesNonessentialUI {
                    Text("REC • \(camera.selectedFPS) FPS  \(VideoMath.timecode(camera.elapsed))")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular.tint(.red), in: Capsule())
                        .padding(.leading, balancingPadding(.leading))
                        .padding(.trailing, balancingPadding(.trailing))
                }
                if !hidesNonessentialUI {
                    LensSelector(lenses: camera.lenses, selectedID: camera.selectedLensID) { lens in
                        Task { await camera.selectLens(lens) }
                    }
                    .padding(.leading, balancingPadding(.leading))
                    .padding(.trailing, balancingPadding(.trailing))
                    .offset(y: verticalSizeClass == .compact ? -3 : 0)
                }
                if controlsExpanded {
                    Group {
                        if verticalSizeClass == .compact {
                            ScrollView {
                                cameraControls
                            }
                            .scrollIndicators(.visible)
                            .frame(maxHeight: 184)
                        } else {
                            cameraControls
                        }
                    }
                    .padding(.leading, balancingPadding(.leading))
                    .padding(.trailing, balancingPadding(.trailing))
                }
                CaptureFooter(
                    isRecording: camera.isRecording,
                    controlsExpanded: controlsExpanded,
                    hidesNonessentialUI: hidesNonessentialUI,
                    summary: summary,
                    recordingLimitLabel: removesFourSecondRecordingLimit ? "No Limit" : "4 Sec",
                    showRecordingLimitSettings: {
                        settingsDestination = .recordingLimit
                    },
                    toggleControls: { withAnimation(.snappy) { controlsExpanded.toggle() } },
                    record: {
                        Task {
                            if camera.isRecording { camera.stopRecording() }
                            else { await camera.startRecording() }
                        }
                    },
                    showInstructions: { withAnimation(.snappy) { showingInstructions = true } },
                    review: {
                        if result == nil {
                            showingNoVideoAlert = true
                        } else {
                            showingReview = true
                        }
                    }
                )
                .offset(y: isCompactHeight ? 3 : 0)
                .padding(.leading, balancingPadding(.leading))
                .padding(.trailing, balancingPadding(.trailing))
            }
            .padding(.horizontal, isCompactHeight ? 8 : 16)
            .padding(.vertical, isCompactHeight ? 4 : 16)
            // Zero on devices without a fold; otherwise keeps controls off the crease.
            .padding(.leading, layoutDirection == .leftToRight ? hingeInsets.left : hingeInsets.right)
            .padding(.trailing, layoutDirection == .leftToRight ? hingeInsets.right : hingeInsets.left)

            if isProcessing {
                ProcessingOverlay(
                    progress: processingProgress,
                    cancel: { processingTask?.cancel() }
                )
            }
            if showingStoragePicker {
                StorageOpeningOverlay()
            }
            if showingInstructions {
                InstructionsOverlay(sideInsets: (hingeInsets.safeLeft, hingeInsets.safeRight)) {
                    withAnimation(.snappy) { showingInstructions = false }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .task {
            if !interpolationAvailable {
                interpolation = .off
            }
            camera.recordAudio = audioRecording
            camera.limitsRecordingDuration = !removesFourSecondRecordingLimit
            camera.setCaptureAspectRatio(aspectRatio)
            await camera.prepare()
            _ = await PhotoLibraryManager.requestAddOnlyAuthorization()
            refreshCameraAuthorizationStatus()
            storageDestination.refreshAvailability()
        }
        .onChange(of: hingeInsets.isFoldable, initial: true) { _, isFoldable in
            camera.isFoldableDisplay = isFoldable
        }
        .onChange(of: camera.completedSourceURL) { _, newURL in
            guard let newURL else { return }
            beginProcessing(
                sourceURL: newURL,
                cameraMetadata: camera.consumeCompletedCaptureMetadata()
            )
        }
        .onChange(of: removesFourSecondRecordingLimit) { _, removesLimit in
            camera.limitsRecordingDuration = !removesLimit
        }
        .onChange(of: aspectRatio) { _, newRatio in
            camera.setCaptureAspectRatio(newRatio)
        }
        .onChange(of: camera.isRecording) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: isProcessing) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: keepScreenAwake) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // A Files picker can be interrupted by a storage disconnect without
                // delivering its completion handler. Clear its presentation state here.
                showingStoragePicker = false
                refreshCameraAuthorizationStatus()
                if cameraAuthorizationStatus == .authorized && !camera.isConfigured {
                    Task { await camera.prepare() }
                } else {
                    camera.resume()
                }
                storageDestination.refreshAvailability()
            case .background:
                processingTask?.cancel()
                camera.suspend()
                storageDestination.suspend()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: storageDestination.statusMessage) { _, message in
            if let message {
                alertMessage = message
                storageDestination.clearStatusMessage()
            }
        }
        .onChange(of: showingStoragePicker) { _, isPresented in
            if isPresented {
                camera.pausePreview()
            } else if scenePhase == .active {
                camera.resume()
            }
        }
        .fileImporter(
            isPresented: $showingStoragePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { selection in
            showingStoragePicker = false
            switch selection {
            case .success(let urls):
                if let url = urls.first {
                    storageDestination.selectDestination(url)
                }
            case .failure(let error):
                alertMessage = "Could not choose external storage: \(error.localizedDescription)"
            }
        }
        .sheet(item: $settingsDestination) { destination in
            SettingsView(
                capabilityReport: camera.capabilityReport,
                interpolationAvailable: interpolationAvailable,
                destination: destination == .recordingLimit ? destination : nil
            )
        }
        .sheet(isPresented: $showingReview) {
            if let result {
                RecordingReviewView(
                    result: result,
                    dismiss: { showingReview = false }
                )
            }
        }
        .alert("Extreme Slo‑Mo", isPresented: Binding(
            get: { alertMessage != nil || camera.errorMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") { alertMessage = nil }
            if hasMissingPermissions {
                Button("Open Settings", action: openAppSettings)
            }
        } message: {
            Text(alertMessage ?? camera.errorMessage ?? "")
        }
        .alert("No Video Yet", isPresented: $showingNoVideoAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Record a video first to preview it in slow motion.")
        }
        .preferredColorScheme(.dark)
    }

    private var hidesNonessentialUI: Bool {
        hideUI && !controlsExpanded
    }

    private var cameraControls: some View {
        CameraControlsView(
            camera: camera,
            interpolation: $interpolation,
            playbackFPS: $playbackFPS,
            aspectRatio: $aspectRatio,
            quality: $quality,
            interpolationAvailable: interpolationAvailable,
            interpolationUnavailableTapped: {
                alertMessage = "Your iPhone model does not support Interpolation. Please use this app on a supported iPhone model to use Interpolation features."
            }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Foldables only: pads the side with the smaller safe-area inset so the lower
    /// controls are centered on the whole display. Always 0 on conventional iPhones.
    private func balancingPadding(_ edge: Edge.Set) -> CGFloat {
        let imbalance = hingeInsets.safeAreaImbalance
        // Never shift further than the bottom row can move without overflowing the safe area
        // (which would push the whole overlay, including the header, off-screen).
        let usableWidth = hingeInsets.viewWidth - hingeInsets.safeLeft - hingeInsets.safeRight
            - 2 * (isCompactHeight ? 8 : 16)
        let slack = max(0, usableWidth - Self.bottomRowMinimumWidth)
        let shift = min(abs(imbalance), slack)
        let leftPadding = imbalance > 0 ? shift : 0
        let rightPadding = imbalance < 0 ? shift : 0
        let isLeading = edge == .leading
        let isLeft = isLeading == (layoutDirection == .leftToRight)
        return isLeft ? leftPadding : rightPadding
    }

    /// Smallest width the bottom control row can compress to (with margin).
    private static let bottomRowMinimumWidth: CGFloat = 330

    private var isCompactHeight: Bool {
        verticalSizeClass == .compact
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
            && (camera.isRecording || isProcessing)
    }

    private func refreshCameraAuthorizationStatus() {
        cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    private var hasMissingPermissions: Bool {
        cameraAuthorizationStatus != .authorized
            || microphoneAuthorizationStatus != .authorized
            || (photoAuthorizationStatus != .authorized && photoAuthorizationStatus != .limited)
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            alertMessage = "Settings could not be opened. Open the Settings app manually and select Extreme Slo‑Mo."
            return
        }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                alertMessage = "Settings could not be opened. Open the Settings app manually and select Extreme Slo‑Mo."
            }
        }
    }

    private func showStoragePicker() {
        if showingStoragePicker {
            showingStoragePicker = false
            Task { @MainActor in
                await Task.yield()
                showingStoragePicker = true
            }
        } else {
            showingStoragePicker = true
        }
    }

    private var equivalentFPS: Int {
        VideoMath.equivalentFPS(capturedFPS: camera.selectedFPS, multiplier: interpolation.rawValue)
    }

    private func viewfinderAspectRatio(for size: CGSize) -> CGFloat {
        let captureRatio: CGFloat = aspectRatio == .standard ? 4 / 3 : 16 / 9
        return size.width > size.height ? captureRatio : 1 / captureRatio
    }

    private var summary: String {
        let slow = VideoMath.slowMotionFactor(
            capturedFPS: camera.selectedFPS,
            multiplier: interpolation.rawValue,
            playbackFPS: playbackFPS.rawValue
        )
        return "\(camera.selectedFPS) real → \(equivalentFPS) equivalent • \(slow.formatted(.number.precision(.fractionLength(0...1))))× slow"
    }

    private func beginProcessing(sourceURL: URL, cameraMetadata: CameraMetadataSnapshot?) {
        isProcessing = true
        processingProgress = 0
        let captured = camera.selectedFPS
        let chosenInterpolation = interpolationAvailable ? interpolation.rawValue : 1
        let chosenPlaybackFPS = playbackFPS.rawValue
        let chosenAspectRatio = aspectRatio
        let chosenQuality = quality
        let shouldSaveOriginal = saveOriginal
        processingTask = Task {
            do {
                let originalDuration = try await AVURLAsset(url: sourceURL).load(.duration).seconds
                let processor = FrameInterpolationProcessor()
                let rawOutputURL = try await processor.process(
                    sourceURL: sourceURL,
                    capturedFPS: captured,
                    multiplier: chosenInterpolation,
                    playbackFPS: chosenPlaybackFPS,
                    aspectRatio: chosenAspectRatio,
                    quality: chosenQuality
                ) { progress in
                    Task { @MainActor in processingProgress = progress }
                }
                let processedContext = VideoMetadataContext(
                    nativeCaptureFPS: captured,
                    interpolationMultiplier: chosenInterpolation,
                    outputFPS: chosenPlaybackFPS,
                    processingMode: chosenQuality.rawValue,
                    interpolationMethod: chosenInterpolation > 1
                        ? "Apple VideoToolbox frame-rate conversion (revision 1)"
                        : "No interpolation",
                    camera: cameraMetadata
                )
                let outputURL = await VideoMetadataWriter.embedMetadata(
                    in: rawOutputURL,
                    context: processedContext,
                    originalDuration: originalDuration,
                    filenamePrefix: "1920slomo"
                )
                let originalContext = VideoMetadataContext(
                    nativeCaptureFPS: captured,
                    interpolationMultiplier: 1,
                    outputFPS: captured,
                    processingMode: "Original capture",
                    interpolationMethod: "No interpolation",
                    camera: cameraMetadata
                )
                let normalizedOriginalURL = try await processor.normalizeOriginal(
                    sourceURL: sourceURL,
                    capturedFPS: captured,
                    aspectRatio: chosenAspectRatio
                )
                let originalURL = await VideoMetadataWriter.embedMetadata(
                    in: normalizedOriginalURL,
                    context: originalContext,
                    originalDuration: originalDuration,
                    filenamePrefix: "original"
                )
                let displayAspectRatio = try await displayAspectRatio(of: outputURL)
                let equivalent = captured * chosenInterpolation
                let saveDestinationName = try await storageDestination.saveVideos(
                    processedURL: outputURL,
                    originalURL: shouldSaveOriginal ? originalURL : nil,
                    capturedFPS: captured,
                    equivalentFPS: equivalent
                )
                let completed = RecordingResult(
                    originalURL: originalURL,
                    processedURL: outputURL,
                    capturedFPS: captured,
                    equivalentFPS: equivalent,
                    playbackFPS: chosenPlaybackFPS,
                    displayAspectRatio: displayAspectRatio,
                    saveDestinationName: saveDestinationName
                )
                result = completed
                showingReview = true
            } catch is CancellationError {
                alertMessage = "Processing was cancelled. The original recording remains available for this session."
            } catch {
                alertMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }

    private func displayAspectRatio(of sourceURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CameraError.processingFailed("The source has no video track.")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayedSize = size.applying(transform)
        return Double(abs(displayedSize.width / displayedSize.height))
    }
}

private struct CameraPermissionMessage: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Label {
                Text("Camera access is required to preview and record video.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            } icon: {
                Image(systemName: "camera.fill")
            }
            .accessibilityElement(children: .combine)

            Button("Open Settings", action: openSettings)
                .buttonStyle(.glassProminent)
                .accessibilityHint("Opens this app’s camera permission settings in the Settings app.")
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: 320)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct CameraHeader: View {
    let resolution: String
    let realFPS: Int
    let equivalentFPS: Int
    let externalDriveAvailable: Bool
    let hasMissingPermissions: Bool
    let hidesNonessentialUI: Bool
    let settings: () -> Void
    let showPermissionWarnings: () -> Void
    let chooseStorage: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Button(action: settings) {
                    Image(systemName: "gearshape.fill")
                        .frame(width: 42, height: 42)
                }
                .accessibilityLabel("Settings")
                .glassEffect(.regular.interactive(), in: Circle())

                if hasMissingPermissions {
                    Button(action: showPermissionWarnings) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .frame(width: 42, height: 42)
                    }
                    .accessibilityLabel("Permissions required")
                    .accessibilityHint("Opens Settings to review missing app permissions.")
                    .glassEffect(.regular.interactive(), in: Circle())
                }
            }
            Spacer()
            if !hidesNonessentialUI {
                VStack(spacing: 2) {
                    Text("\(resolution) • \(realFPS) FPS")
                        .font(.subheadline.weight(.semibold))
                    Text("REAL CAPTURE")
                        .font(.caption2.weight(.bold))
                    if equivalentFPS != realFPS {
                        Text("\(equivalentFPS) FPS equivalent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                Spacer()
                Button(action: chooseStorage) {
                    ZStack {
                        Image(systemName: "externaldrive.fill")
                        if !externalDriveAvailable {
                            Capsule()
                                .fill(.white)
                                .frame(width: 34, height: 3)
                                .rotationEffect(.degrees(-45))
                        }
                    }
                    .frame(width: 42, height: 42)
                }
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel(
                    externalDriveAvailable
                        ? "External storage selected. Choose another storage folder."
                        : "External storage unavailable. Choose a storage folder."
                )
            }
        }
        .foregroundStyle(.white)
    }
}

private struct LensSelector: View {
    let lenses: [LensOption]
    let selectedID: String
    let select: (LensOption) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(lenses) { lens in
                    Button(lens.name) { select(lens) }
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 38)
                        .foregroundStyle(lens.id == selectedID ? .yellow : .white)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .accessibilityLabel("\(lens.name) camera")
                }
            }
        }
    }
}

private struct CaptureFooter: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let isRecording: Bool
    let controlsExpanded: Bool
    let hidesNonessentialUI: Bool
    let summary: String
    let recordingLimitLabel: String
    let showRecordingLimitSettings: () -> Void
    let toggleControls: () -> Void
    let record: () -> Void
    let showInstructions: () -> Void
    let review: () -> Void

    var body: some View {
        VStack(spacing: verticalSizeClass == .compact ? 6 : 12) {
            if !hidesNonessentialUI {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, verticalSizeClass == .compact ? 4 : 6)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            HStack(spacing: 8) {
                if !hidesNonessentialUI {
                    Button(action: review) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.title2)
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Review last recording")
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
                } else {
                    Color.clear
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                if !hidesNonessentialUI {
                    Button(action: showRecordingLimitSettings) {
                        Text(recordingLimitLabel)
                            .font(.caption2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .frame(width: 52, height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .accessibilityLabel("Recording limit")
                    .accessibilityValue(recordingLimitLabel)
                    .accessibilityHint("Opens the recording limit setting.")
                }
                Color.clear
                    .frame(width: 78, height: 78)
                    .accessibilityHidden(true)
                if !hidesNonessentialUI {
                    Button(action: showInstructions) {
                        Image(systemName: "info.circle.fill")
                            .font(.title2)
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Instructions")
                    .glassEffect(.regular.interactive(), in: Circle())
                }
                Spacer(minLength: 0)
                Button(action: toggleControls) {
                    Image(systemName: controlsExpanded ? "chevron.down" : "slider.horizontal.3")
                        .font(.title2)
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel(controlsExpanded ? "Hide camera controls" : "Show camera controls")
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
            }
            .overlay {
                Button(action: record) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.9), lineWidth: 5)
                        if isRecording {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(.red)
                                .frame(width: 34, height: 34)
                        } else {
                            Circle().fill(.red).padding(8)
                        }
                    }
                    .frame(width: 78, height: 78)
                }
                .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
            }
        }
        .foregroundStyle(.white)
    }
}

private struct InstructionsOverlay: View {
    /// Foldables only (zero elsewhere): keeps the card, and its close button, clear of side system bars.
    let sideInsets: (left: CGFloat, right: CGFloat)
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Button(action: dismiss) {
                    Color.black.opacity(0.58)
                        .ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close instructions")

                VStack(spacing: 0) {
                    HStack {
                        Text("Instructions")
                            .font(.title2.weight(.bold))
                        Spacer()
                        Button(action: dismiss) {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Close")
                        .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .padding()

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("1920SloMo records real video at up to 240 frames per second (fps). Interpolation estimates movement between recorded frames to create additional frames, producing up to 1920 fps equivalent slow motion—not 1920 frames captured by the camera. Interpolated videos do not include audio.")

                            Text("For the best results, record outdoors in bright, natural daylight. Keep your phone steady and focus on clearly visible people or objects moving smoothly in a predictable direction. Tap the screen to focus on your subject.")

                            Text("Avoid flashing lights, flickering LEDs, screens, dark scenes, and subjects repeatedly crossing in front of each other. These can cause flickering, warping, ghosting, or other visual artifacts. Lower interpolation levels generally produce fewer artifacts.")

                            Text("Shutter speed controls how much motion blur appears. Faster speeds make moving subjects sharper but let in less light, which can make video too dark or increase visible artifacts. Slower speeds brighten the image but add motion blur. Find a balance for your scene, and use the light button when extra lighting is needed.")

                            Text("Adjustable aperture is available only on the Main camera of iPhone 18 Pro, iPhone 18 Pro Max, and future compatible models. It controls how much light enters the camera and how much of the scene stays in focus.")

                            Text("For interpolation, Quality prioritizes visual results but takes longer to process. Performance processes faster but may introduce more artifacts. If processing is slow or fails on your device, try Performance or a lower interpolation level.")

                            Text("The default 4-second recording limit is recommended. Start with short clips to see how your iPhone handles processing before turning off the limit in Settings. Longer recordings can require significantly more storage, processing time, battery power, and generate more heat. For extended recording, USB 3 or faster external storage is recommended where supported. If your iPhone becomes noticeably hot, stop recording until it cools down.")

                            Text("The bottom-left preview button opens only the last video captured during your current app session.")

                            Text("Use the Apple Watch companion app to start and stop recording remotely.")
                        }
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    }
                }
                .foregroundStyle(.white)
                .frame(
                    width: max(0, proxy.size.width - 32 - sideInsets.left - sideInsets.right),
                    height: max(0, proxy.size.height * 0.84)
                )
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
                .contentShape(RoundedRectangle(cornerRadius: 28))
                .offset(x: (sideInsets.left - sideInsets.right) / 2)
            }
        }
        .ignoresSafeArea()
    }
}

private struct StorageOpeningOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening external storage…")
                .font(.headline)
        }
        .padding(24)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }
}

private struct ProcessingOverlay: View {
    let progress: Double
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Text("Creating slow motion…")
                .font(.headline)
            Text("Please do not lock your iPhone while processing.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Text(progress, format: .percent.precision(.fractionLength(0)))
                .font(.title2.monospacedDigit())
            Button("Cancel", role: .cancel, action: cancel)
                .buttonStyle(.glass)
        }
        .padding(24)
        .frame(maxWidth: 320)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
        .foregroundStyle(.white)
    }
}
