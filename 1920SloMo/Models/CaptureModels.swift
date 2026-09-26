import AVFoundation
import Foundation

enum InterpolationMultiplier: Int, CaseIterable, Identifiable, Codable {
    case off = 1
    case two = 2
    case four = 4
    case eight = 8

    var id: Int { rawValue }
    var label: String { self == .off ? "Off" : "\(rawValue)×" }
    var phases: [Float] { Self.phases(for: rawValue) }

    static func phases(for multiplier: Int) -> [Float] {
        guard multiplier > 1 else { return [] }
        return (1..<multiplier).map { Float($0) / Float(multiplier) }
    }
}

enum PlaybackFPS: Int, CaseIterable, Identifiable, Codable {
    case thirty = 30
    case sixty = 60
    var id: Int { rawValue }
}

enum CaptureAspectRatio: String, CaseIterable, Identifiable, Codable {
    case widescreen = "16:9"
    case standard = "4:3"
    var id: String { rawValue }
}

enum InterpolationQuality: String, CaseIterable, Identifiable, Codable {
    case performance = "Performance"
    case quality = "Quality"
    var id: String { rawValue }
}

enum ShutterChoice: Identifiable, Hashable {
    case auto
    case denominator(Int)

    var id: String { label }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .denominator(let value): "1/\(value)"
        }
    }
    var duration: CMTime? {
        switch self {
        case .auto: nil
        case .denominator(let value): CMTime(value: 1, timescale: CMTimeScale(value))
        }
    }
}

struct CameraFormatOption: Identifiable, Hashable {
    let id: String
    let dimensions: CMVideoDimensions
    let fps: Int
    let format: AVCaptureDevice.Format

    var resolutionLabel: String {
        if dimensions.width == 1920 && dimensions.height == 1080 { return "1080p" }
        if dimensions.width == 3840 && dimensions.height == 2160 { return "4K" }
        return "\(dimensions.width)×\(dimensions.height)"
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct LensOption: Identifiable, Hashable {
    let id: String
    let name: String
    let deviceType: AVCaptureDevice.DeviceType
    let device: AVCaptureDevice
    let zoomFactor: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct RecordingResult: Identifiable {
    let id = UUID()
    let originalURL: URL
    let processedURL: URL
    let capturedFPS: Int
    let equivalentFPS: Int
    let playbackFPS: Int
    let displayAspectRatio: Double
    let saveDestinationName: String
}

enum CameraError: LocalizedError {
    case cameraUnavailable
    case permissionDenied
    case unsupportedFrameRate
    case unsupportedExposure
    case configurationFailed(String)
    case insufficientStorage
    case recordingFailed(String)
    case interpolationUnsupported
    case processingFailed(String)
    case photoSaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: "No rear camera is available."
        case .permissionDenied: "Camera, Microphone, or Photos access is denied. Check permissions in Settings."
        case .unsupportedFrameRate: "That real capture frame rate is not supported by this lens."
        case .unsupportedExposure: "That shutter speed is not supported by the active camera format."
        case .configurationFailed(let detail): "Camera configuration failed: \(detail)"
        case .insufficientStorage: "There is not enough free storage to begin recording."
        case .recordingFailed(let detail): "Recording failed: \(detail)"
        case .interpolationUnsupported:
#if targetEnvironment(simulator)
            "Frame interpolation requires a supported physical iPhone."
#else
            "Apple frame interpolation is unavailable on this device."
#endif
        case .processingFailed(let detail): "Video processing failed: \(detail)"
        case .photoSaveFailed(let detail): "Saving to Photos failed: \(detail)"
        }
    }
}
