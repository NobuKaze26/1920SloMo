import AVFoundation
import SwiftUI

struct CameraControlsView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Bindable var camera: CameraManager
    @Binding var interpolation: InterpolationMultiplier
    @Binding var playbackFPS: PlaybackFPS
    @Binding var aspectRatio: CaptureAspectRatio
    @Binding var quality: InterpolationQuality
    let interpolationAvailable: Bool
    let interpolationUnavailableTapped: () -> Void

    var body: some View {
        VStack(spacing: isCompactHeight ? 8 : 14) {
            HStack {
                controlMenu("Real FPS", value: "\(camera.selectedFPS)") {
                    ForEach(camera.formats) { option in
                        Button("\(option.resolutionLabel) • \(option.fps) FPS") {
                            Task { await camera.selectFPS(option.fps) }
                        }
                    }
                }
                if interpolationAvailable {
                    controlMenu("Interpolation", value: interpolation.label) {
                        ForEach(InterpolationMultiplier.allCases) { item in
                            Button(item.label) { interpolation = item }
                        }
                    }
                } else {
                    Button(action: interpolationUnavailableTapped) {
                        controlLabel("Interpolation", value: InterpolationMultiplier.off.label)
                    }
                    .buttonStyle(.plain)
                    .opacity(0.55)
                    .accessibilityLabel("Interpolation unavailable")
                    .accessibilityValue(InterpolationMultiplier.off.label)
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
                            Task {
                                if let seconds = shutter.duration?.seconds {
                                    await camera.setShutterDuration(seconds)
                                } else {
                                    await camera.setAutomaticExposure()
                                }
                            }
                        }
                        .disabled(!camera.isShutterSupported(shutter))
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
            Toggle(
                "Light",
                isOn: Binding(
                    get: { camera.isTorchOn },
                    set: { enabled in
                        Task { await camera.setTorchEnabled(enabled) }
                    }
                )
            )
            .font(.caption)
            .disabled(!camera.isTorchAvailable)
            .opacity(camera.isTorchAvailable ? 1 : 0.55)
            .accessibilityHint(
                camera.isTorchAvailable
                    ? "Uses the camera torch while previewing and recording."
                    : "The active camera does not have an available torch."
            )
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
        .padding(isCompactHeight ? 10 : 14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    private var isCompactHeight: Bool {
        verticalSizeClass == .compact
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
            controlLabel(title, value: value)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func controlLabel(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }
}
