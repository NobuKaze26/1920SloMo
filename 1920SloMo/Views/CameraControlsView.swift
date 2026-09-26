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
                .onChange(of: camera.manualISO) { _, _ in
                    Task { await camera.applyExposure() }
                }
            HStack {
                Label("Aperture", systemImage: "camera.aperture")
                    .font(.caption)
                Spacer()
                Menu {
                    Button("Auto") {
                        Task { await camera.setAperture(nil) }
                    }
                    ForEach(camera.apertureStops, id: \.self) { stop in
                        Button("f/\(stop.formatted())") {
                            Task { await camera.setAperture(stop) }
                        }
                    }
                } label: {
                    Text(apertureLabel)
                        .font(.caption.weight(.semibold))
                }
                .disabled(!camera.adjustableAperture)
            }
            .opacity(camera.adjustableAperture ? 1 : 0.55)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                camera.adjustableAperture
                    ? "Aperture"
                    : "Aperture is fixed for the active lens and format"
            )
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    private var apertureLabel: String {
        guard let aperture = camera.selectedAperture else { return "Auto" }
        return "f/\(aperture.formatted())"
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
