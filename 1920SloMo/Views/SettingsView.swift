import AVFoundation
import Photos
import SwiftUI

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase

    let capabilityReport: String
    let interpolationAvailable: Bool

    @State private var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)

    @AppStorage("saveOriginal") private var saveOriginal = true
    @AppStorage("audioRecording") private var audioRecording = true
    @AppStorage("keepScreenAwake") private var keepScreenAwake = true
    @AppStorage("defaultPlaybackFPS") private var playbackFPS = 30
    @AppStorage("defaultAspectRatio") private var aspectRatio = CaptureAspectRatio.standard.rawValue
    @AppStorage("interpolationQuality") private var quality = InterpolationQuality.quality.rawValue

    var body: some View {
        NavigationStack {
            ZStack {
                ResponsiveAppBackground()
                Form {
                    if hasMissingPermissions {
                        PermissionWarningsSection(
                            cameraGranted: cameraAuthorizationStatus == .authorized,
                            microphoneGranted: microphoneAuthorizationStatus == .authorized,
                            photoLibraryGranted: photoAuthorizationStatus == .authorized || photoAuthorizationStatus == .limited
                        )
                    }
                    Section("Saving") {
                        Toggle("Save Original Recording (Before Interpolation)", isOn: $saveOriginal)
                        Text("The interpolated slow-motion video is always saved to Photos. Turn this on to also save the untouched recording from before interpolation.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section("Capture Defaults") {
                        Toggle("Record Audio in Original Recording", isOn: $audioRecording)
                        Text("The interpolated slow-motion video is silent.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Toggle("Keep Screen Awake While Recording", isOn: $keepScreenAwake)
                        Picker("Playback FPS", selection: $playbackFPS) {
                            Text("30").tag(30)
                            Text("60").tag(60)
                        }
                        Picker("Aspect Ratio", selection: $aspectRatio) {
                            ForEach(CaptureAspectRatio.allCases) { ratio in
                                Text(ratio.rawValue).tag(ratio.rawValue)
                            }
                        }
                        Picker("Processing Quality", selection: $quality) {
                            ForEach(InterpolationQuality.allCases) { item in
                                Text(item.rawValue).tag(item.rawValue)
                            }
                        }
                    }
                    Section("Apple Frame Interpolation") {
                        LabeledContent("Available on iPhone", value: interpolationAvailable ? "Yes" : "No")
                        if !interpolationAvailable {
                            Text("Apple VideoToolbox frame interpolation requires iOS 26 or later and compatible hardware. The app never labels duplicated frames as interpolation.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("Camera Capabilities") {
                        Text(capabilityReport)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Extreme Slo‑Mo")
        }
        .task {
            refreshPermissionStatuses()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshPermissionStatuses()
            }
        }
    }

    private var hasMissingPermissions: Bool {
        cameraAuthorizationStatus != .authorized
            || microphoneAuthorizationStatus != .authorized
            || (photoAuthorizationStatus != .authorized && photoAuthorizationStatus != .limited)
    }

    private func refreshPermissionStatuses() {
        cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }
}

private struct PermissionWarningsSection: View {
    let cameraGranted: Bool
    let microphoneGranted: Bool
    let photoLibraryGranted: Bool

    var body: some View {
        Section {
            if !cameraGranted {
                PermissionWarning(
                    title: "Camera Access Required",
                    message: "Enable Camera access to preview and record video."
                )
            }
            if !microphoneGranted {
                PermissionWarning(
                    title: "Microphone Access Required",
                    message: "Enable Microphone access to record audio."
                )
            }
            if !photoLibraryGranted {
                PermissionWarning(
                    title: "Photos Access Required",
                    message: "Enable Photos access to save recordings."
                )
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Manage permissions in the Settings app.")
        }
    }
}

private struct PermissionWarning: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.footnote)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
        .accessibilityElement(children: .combine)
    }
}
