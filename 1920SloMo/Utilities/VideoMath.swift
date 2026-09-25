import Foundation

enum VideoMath {
    static func equivalentFPS(capturedFPS: Int, multiplier: Int) -> Int {
        capturedFPS * max(multiplier, 1)
    }

    static func slowMotionFactor(capturedFPS: Int, multiplier: Int, playbackFPS: Int) -> Double {
        Double(equivalentFPS(capturedFPS: capturedFPS, multiplier: multiplier)) / Double(playbackFPS)
    }

    static func outputFilename(date: Date = .now, capturedFPS: Int, equivalentFPS: Int) -> String {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .replacingOccurrences(of: ":", with: "-")
        return "ExtremeSloMo_\(stamp)_\(time)_\(capturedFPS)to\(equivalentFPS).mov"
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
