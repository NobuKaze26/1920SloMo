import AVFoundation
import SwiftUI

struct CameraControlsView: View {
    @Bindable var camera: CameraManager
    @Binding var interpolation: InterpolationMultiplier
    @Binding var playbackFPS: PlaybackFPS
    @Binding var aspectRatio: CaptureAspectRatio
    @Binding var quality: InterpolationQuality
    let interpolationAvailable: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                controlMenu("Real FPS", value: "\(camera.selectedFPS)") {
                    ForEach(camera.formats) { option in
                        Button("\(option.resolutionLabel) • \(option.fps) FPS") {
                            Task { await camera.selectFPS(option.fps) }
                        }
                    }
                }
                controlMenu("Interpolation", value: interpolation.label) {
                    ForEach(InterpolationMultiplier.allCases) { item in
                        Button(item.label) { interpolation = item }
                            .disabled(item != .off && !interpolationAvailable)
                    }
                }
                controlMenu("Playback", value: "\(playbackFPS.rawValue)") {
                    ForEach(PlaybackFPS.allCases) { item in
                        Button("\(item.rawValue) FPS") { playbackFPS = item }
                    }
                }
            }
            HStack {
                controlMenu("Shutter", value: camera.selectedShutter.label) {
                    ForEach(camera.shutters) { shutter in
                        Button(shutter.label) {
                            camera.selectedShutter = shutter
                            Task { await camera.applyExposure() }
                        }
                    }
                }
                controlMenu("Ratio", value: aspectRatio.rawValue) {
                    ForEach(CaptureAspectRatio.allCases) { ratio in
                        Button(ratio.rawValue) { aspectRatio = ratio }
                    }
                }
                controlMenu("Quality", value: quality.rawValue) {
                    ForEach(InterpolationQuality.allCases) { item in
                        Button(item.rawValue) { quality = item }
                    }
                }
            }
            if camera.manualISO, let format = camera.formats.first(where: { $0.fps == camera.selectedFPS })?.format {
                VStack(alignment: .leading) {
                    Text("ISO \(Int(camera.requestedISO))")
                        .font(.caption)
                    Slider(
                        value: Binding(
                            get: { Double(camera.requestedISO) },
                            set: { value in Task { await camera.setISO(Float(value)) } }
                        ),
                        in: Double(format.minISO)...Double(format.maxISO)
                    )
                }
            }
            Toggle("Manual ISO", isOn: $camera.manualISO)
                .font(.caption)
            if camera.adjustableAperture {
                HStack {
                    Label("Aperture", systemImage: "camera.aperture")
                        .font(.caption)
                    Spacer()
                    Picker(
                        "Aperture",
                        selection: Binding(
                            get: { camera.selectedAperture },
                            set: { value in Task { await camera.setAperture(value) } }
                        )
                    ) {
                        Text("Auto").tag(Float?.none)
                        ForEach(camera.apertureStops, id: \.self) { stop in
                            Text("f/\(stop.formatted())").tag(Float?.some(stop))
                        }
                    }
                    .labelsHidden()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Aperture")
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    private func controlMenu<Content: View>(
        _ title: LocalizedStringKey,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            VStack(spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}
