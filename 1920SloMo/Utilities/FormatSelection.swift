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

    static func supportedShutters(for format: AVCaptureDevice.Format, at fps: Int) -> [ShutterChoice] {
        let minimum = format.minExposureDuration.seconds
        let maximum = min(format.maxExposureDuration.seconds, 1 / Double(fps))
        let values = [240, 500, 1000, 2000, 4000, 8000]
        return [.auto] + values.compactMap { value in
            let seconds = 1 / Double(value)
            return (seconds >= minimum && seconds <= maximum) ? .denominator(value) : nil
        }
    }

    private static func score(_ option: CameraFormatOption) -> Int {
        let is1080 = option.dimensions.width == 1920 && option.dimensions.height == 1080
        return option.fps * 1_000_000 + (is1080 ? 500_000 : 0) + Int(option.dimensions.width)
    }
}
