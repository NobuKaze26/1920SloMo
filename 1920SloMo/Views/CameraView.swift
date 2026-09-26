import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var camera: CameraManager

    @AppStorage("saveOriginal") private var saveOriginal = true
    @AppStorage("audioRecording") private var audioRecording = true
    @AppStorage("keepScreenAwake") private var keepScreenAwake = true
    @AppStorage("removesFourSecondRecordingLimit") private var removesFourSecondRecordingLimit = false

    @State private var interpolation: InterpolationMultiplier =
        FrameInterpolationProcessor.isAppleInterpolationAvailable ? .eight : .off
    @State private var playbackFPS: PlaybackFPS = .thirty
    @State private var aspectRatio: CaptureAspectRatio = .standard
    @State private var quality: InterpolationQuality = .quality
    @State private var controlsExpanded = false
    @State private var showingSettings = false
    @State private var isProcessing = false
    @State private var processingProgress = 0.0
    @State private var processingTask: Task<Void, Never>?
    @State private var result: RecordingResult?
    @State private var showingReview = false
    @State private var showingStoragePicker = false
    @State private var storageDestination = StorageDestinationManager()
    @State private var alertMessage: String?
    @State private var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    private let interpolationAvailable = FrameInterpolationProcessor.isAppleInterpolationAvailable

    var body: some View {
        ZStack {
            ResponsiveAppBackground()
            GeometryReader { proxy in
                CameraPreview(session: camera.session, device: camera.previewDevice) { point in
                    camera.focus(at: point)
                }
                .aspectRatio(viewfinderAspectRatio(for: proxy.size), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .ignoresSafeArea()

            if cameraAuthorizationStatus != .authorized {
                CameraPermissionMessage()
            }

            VStack(spacing: 12) {
                CameraHeader(
                    resolution: camera.resolutionLabel,
                    realFPS: camera.selectedFPS,
                    equivalentFPS: equivalentFPS,
                    externalDriveAvailable: storageDestination.isExternalDriveAvailable,
                    settings: { showingSettings = true },
                    chooseStorage: showStoragePicker
                )
                Spacer()
                if camera.isRecording {
                    Text("REC • \(camera.selectedFPS) FPS  \(VideoMath.timecode(camera.elapsed))")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular.tint(.red), in: Capsule())
                }
                LensSelector(lenses: camera.lenses, selectedID: camera.selectedLensID) { lens in
                    Task { await camera.selectLens(lens) }
                }
                if controlsExpanded {
                    CameraControlsView(
                        camera: camera,
                        interpolation: $interpolation,
                        playbackFPS: $playbackFPS,
                        aspectRatio: $aspectRatio,
                        quality: $quality,
                        interpolationAvailable: interpolationAvailable
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                CaptureFooter(
                    isRecording: camera.isRecording,
                    controlsExpanded: controlsExpanded,
                    summary: summary,
                    toggleControls: { withAnimation(.snappy) { controlsExpanded.toggle() } },
                    record: {
                        Task {
                            if camera.isRecording { camera.stopRecording() }
                            else { await camera.startRecording() }
                        }
                    },
                    review: result == nil ? nil : { showingReview = true }
                )
            }
            .padding()

            if isProcessing {
                ProcessingOverlay(
                    progress: processingProgress,
                    cancel: { processingTask?.cancel() }
                )
            }
            if showingStoragePicker {
                StorageOpeningOverlay()
            }
        }
        .task {
            camera.recordAudio = audioRecording
            camera.limitsRecordingDuration = !removesFourSecondRecordingLimit
            await camera.prepare()
            refreshCameraAuthorizationStatus()
            storageDestination.refreshAvailability()
        }
        .onChange(of: camera.completedSourceURL) { _, newURL in
            guard let newURL else { return }
            beginProcessing(sourceURL: newURL)
        }
        .onChange(of: removesFourSecondRecordingLimit) { _, removesLimit in
            camera.limitsRecordingDuration = !removesLimit
        }
        .onChange(of: camera.isRecording) { _, recording in
            UIApplication.shared.isIdleTimerDisabled = recording && keepScreenAwake
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
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                capabilityReport: camera.capabilityReport,
                interpolationAvailable: interpolationAvailable
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
            if camera.errorMessage != nil {
                Button("Open Settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
            }
        } message: {
            Text(alertMessage ?? camera.errorMessage ?? "")
        }
        .preferredColorScheme(.dark)
    }

    private func refreshCameraAuthorizationStatus() {
        cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
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

    private func beginProcessing(sourceURL: URL) {
        isProcessing = true
        processingProgress = 0
        let captured = camera.selectedFPS
        let chosenInterpolation = interpolationAvailable ? interpolation.rawValue : 1
        processingTask = Task {
            do {
                let processor = FrameInterpolationProcessor()
                let outputURL = try await processor.process(
                    sourceURL: sourceURL,
                    capturedFPS: captured,
                    multiplier: chosenInterpolation,
                    playbackFPS: playbackFPS.rawValue,
                    aspectRatio: aspectRatio,
                    quality: quality
                ) { progress in
                    Task { @MainActor in processingProgress = progress }
                }
                let displayAspectRatio = try await displayAspectRatio(of: sourceURL)
                let equivalent = captured * chosenInterpolation
                let saveDestinationName = try await storageDestination.saveVideos(
                    processedURL: outputURL,
                    originalURL: saveOriginal ? sourceURL : nil,
                    capturedFPS: captured,
                    equivalentFPS: equivalent
                )
                let completed = RecordingResult(
                    originalURL: sourceURL,
                    processedURL: outputURL,
                    capturedFPS: captured,
                    equivalentFPS: equivalent,
                    playbackFPS: playbackFPS.rawValue,
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
    var body: some View {
        Label {
            Text("Camera access is required to preview and record video.")
                .font(.headline)
                .multilineTextAlignment(.center)
        } icon: {
            Image(systemName: "camera.fill")
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: 320)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
}

private struct CameraHeader: View {
    let resolution: String
    let realFPS: Int
    let equivalentFPS: Int
    let externalDriveAvailable: Bool
    let settings: () -> Void
    let chooseStorage: () -> Void

    var body: some View {
        HStack {
            Button(action: settings) {
                Image(systemName: "gearshape.fill")
                    .frame(width: 42, height: 42)
            }
            .accessibilityLabel("Settings")
            .glassEffect(.regular.interactive(), in: Circle())
            Spacer()
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
    let isRecording: Bool
    let controlsExpanded: Bool
    let summary: String
    let toggleControls: () -> Void
    let record: () -> Void
    let review: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
            HStack {
                Button(action: { review?() }) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                }
                .disabled(review == nil)
                .accessibilityLabel("Review last recording")
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
                Spacer()
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
                Spacer()
                Button(action: toggleControls) {
                    Image(systemName: controlsExpanded ? "chevron.down" : "slider.horizontal.3")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                }
                .accessibilityLabel(controlsExpanded ? "Hide camera controls" : "Show camera controls")
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .foregroundStyle(.white)
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
