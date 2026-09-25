import SwiftUI

struct SettingsView: View {
    let capabilityReport: String
    let interpolationAvailable: Bool

    @AppStorage("saveOriginal") private var saveOriginal = true
    @AppStorage("audioRecording") private var audioRecording = true
    @AppStorage("keepScreenAwake") private var keepScreenAwake = true
    @AppStorage("defaultPlaybackFPS") private var playbackFPS = 30
    @AppStorage("defaultAspectRatio") private var aspectRatio = CaptureAspectRatio.widescreen.rawValue
    @AppStorage("interpolationQuality") private var quality = InterpolationQuality.quality.rawValue

    var body: some View {
        NavigationStack {
            Form {
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
            .navigationTitle("Extreme Slo‑Mo")
        }
    }
}
