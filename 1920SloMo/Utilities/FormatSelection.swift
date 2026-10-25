import AVFoundation

enum FormatSelection {
    static func options(for device: AVCaptureDevice) -> [CameraFormatOption] {
        var best: [String: CameraFormatOption] = [:]
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width >= 1280 else { continue }
            for rate in format.videoSupportedFrameRateRanges {
                let maximum = Int(rate.maxFrameRate.rounded(.down))
                for fps in [60, 120, 240].filter({ $0 <= maximum && Double($0) >= rate.minFrameRate }) {
                    let id = "\(dimensions.width)x\(dimensions.height)-\(fps)"
                    let candidate = CameraFormatOption(id: id, dimensions: dimensions, fps: fps, format: format)
                    if let existing = best["\(fps)"] {
                        let candidateScore = score(candidate)
                        if candidateScore > score(existing) { best["\(fps)"] = candidate }
                    } else {
                        best["\(fps)"] = candidate
                    }
                }
            }
        }
        return best.values.sorted { $0.fps > $1.fps }
    }

    static func bestOption(in options: [CameraFormatOption], preferredFPS: Int? = nil) -> CameraFormatOption? {
        if let preferredFPS, let exact = options.first(where: { $0.fps == preferredFPS }) { return exact }
        return options.max { score($0) < score($1) }
    }

    static func shutterRange(for format: AVCaptureDevice.Format, at fps: Int) -> ShutterDurationRange? {
        let fastest = format.minExposureDuration.seconds
        let slowest = min(format.maxExposureDuration.seconds, 1 / Double(fps))
        guard fastest.isFinite, slowest.isFinite, fastest > 0, fastest <= slowest else { return nil }
        return ShutterDurationRange(fastest: fastest, slowest: slowest)
    }

    static let shutterChoices: [ShutterChoice] = [
        .auto,
        .denominator(240),
        .denominator(500),
        .denominator(1_000),
        .denominator(2_000),
        .denominator(4_000),
        .denominator(8_000)
    ]

    static func isSupported(_ shutter: ShutterChoice, in range: ShutterDurationRange?) -> Bool {
        guard let duration = shutter.duration?.seconds else { return true }
        guard let range else { return false }
        let tolerance = max(duration * 0.000_1, 0.000_000_001)
        return duration >= range.fastest - tolerance && duration <= range.slowest + tolerance
    }

    private static func score(_ option: CameraFormatOption) -> Int {
        let is1080 = option.dimensions.width == 1920 && option.dimensions.height == 1080
        return option.fps * 1_000_000 + (is1080 ? 500_000 : 0) + Int(option.dimensions.width)
    }
}
