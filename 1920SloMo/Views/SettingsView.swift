import AVFoundation
import Photos
import SwiftUI
import UIKit

enum SettingsDestination: Hashable, Identifiable {
    case general
    case recordingLimit

    var id: Self { self }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let capabilityReport: String
    let interpolationAvailable: Bool
    let destination: SettingsDestination?

    @State private var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    @State private var isRecordingLimitHighlighted = false
    @State private var settingsOpenFailed = false

    @AppStorage("saveOriginal") private var saveOriginal = true
    @AppStorage("keepScreenAwake") private var keepScreenAwake = true
    @AppStorage("removesFourSecondRecordingLimit") private var removesFourSecondRecordingLimit = false
    @AppStorage("hideUI") private var hideUI = false

    var body: some View {
        NavigationStack {
            ZStack {
                ResponsiveAppBackground()
                ScrollViewReader { proxy in
                    Form {
                        if hasMissingPermissions {
                            PermissionWarningsSection(
                                cameraGranted: cameraAuthorizationStatus == .authorized,
                                microphoneGranted: microphoneAuthorizationStatus == .authorized,
                                photoLibraryGranted: photoAuthorizationStatus == .authorized || photoAuthorizationStatus == .limited,
                                openSettings: openAppSettings
                            )
                        }
                        Section("Saving") {
                            Toggle("Save Original Recording (Before Interpolation)", isOn: $saveOriginal)
                            Text("The interpolated slow-motion video is always saved to Photos. Turn this on to also save the untouched recording from before interpolation.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Section("Capture Defaults") {
                            Toggle("Keep Screen Awake While Recording and Processing", isOn: $keepScreenAwake)
                            Text("It is recommended this setting stay on. If the phone sleeps or is locked during processing, the video will fail.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Toggle("Hide UI", isOn: $hideUI)
                            Text("Hide everything on screen except for settings, record, and controls, when the controls menu is hidden.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Toggle("Remove 4-Second Recording Limit", isOn: $removesFourSecondRecordingLimit)
                                .id(SettingsDestination.recordingLimit)
                                .listRowBackground(
                                    Color(uiColor: .secondarySystemGroupedBackground)
                                        .overlay(
                                            Color.yellow.opacity(
                                                isRecordingLimitHighlighted ? 0.28 : 0
                                            )
                                        )
                                )
                            if removesFourSecondRecordingLimit {
                                Text("Long recordings consume a lot of storage, can make your iPhone hot, and may be slow to process on older iPhone models.")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
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
                        Section("About") {
                            NavigationLink {
                                PrivacyPolicyView()
                            } label: {
                                Label("Privacy Policy", systemImage: "hand.raised")
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .task(id: destination) {
                        await emphasizeDestination(using: proxy)
                    }
                }
            }
            .navigationTitle("1920SloMo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close Settings")
                }
            }
        }
        .task {
            refreshPermissionStatuses()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshPermissionStatuses()
            }
        }
        .alert("Unable to Open Settings", isPresented: $settingsOpenFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Settings could not be opened. You can open the Settings app manually and select Extreme Slo‑Mo.")
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

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            settingsOpenFailed = true
            return
        }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                settingsOpenFailed = true
            }
        }
    }

    private func emphasizeDestination(using proxy: ScrollViewProxy) async {
        guard destination == .recordingLimit else { return }
        // Let the sheet and Form complete their first layout before scrolling and
        // highlighting the destination row.
        try? await Task.sleep(for: .milliseconds(180))
        withAnimation(.easeInOut(duration: 0.2)) {
            isRecordingLimitHighlighted = true
        }
        withAnimation(.snappy) {
            proxy.scrollTo(SettingsDestination.recordingLimit, anchor: .center)
        }
        try? await Task.sleep(for: .seconds(1.4))
        withAnimation(.easeInOut(duration: 0.25)) {
            isRecordingLimitHighlighted = false
        }
    }
}

private struct PermissionWarningsSection: View {
    let cameraGranted: Bool
    let microphoneGranted: Bool
    let photoLibraryGranted: Bool
    let openSettings: () -> Void

    var body: some View {
        Section {
            if !cameraGranted {
                PermissionWarning(
                    title: "Camera Access Required",
                    message: "Enable Camera access to preview and record video.",
                    openSettings: openSettings
                )
            }
            if !microphoneGranted {
                PermissionWarning(
                    title: "Microphone Access Required",
                    message: "Enable Microphone access to record audio.",
                    openSettings: openSettings
                )
            }
            if !photoLibraryGranted {
                PermissionWarning(
                    title: "Photos Access Required",
                    message: "Enable Photos access to save recordings.",
                    openSettings: openSettings
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
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            Button("Open Settings", action: openSettings)
                .accessibilityHint("Opens this app’s permission settings in the Settings app.")
        }
    }
}
