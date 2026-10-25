@preconcurrency import AVFoundation
import OSLog
import UIKit

enum VideoMetadataWriter {
    private static let namespace = "com.apwdt.1920slomo"
    private static let website = "https://apwdt.com"
    private static let logger = Logger(subsystem: "ExtremeSloMo", category: "Metadata")

    static func embedMetadata(
        in sourceURL: URL,
        context: VideoMetadataContext,
        originalDuration: Double,
        filenamePrefix: String
    ) async -> URL {
        do {
            let asset = AVURLAsset(url: sourceURL)
            let finalDuration = try await asset.load(.duration).seconds
            let metadata = makeMetadata(context: context, originalDuration: originalDuration, finalDuration: finalDuration)
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                logger.error("Pass-through metadata export is unavailable; retaining the valid source movie.")
                return sourceURL
            }
            let outputURL = FileManager.default.temporaryDirectory
                .appending(path: "\(filenamePrefix)-\(UUID().uuidString).mov")
            exporter.metadata = metadata
            try await exporter.export(to: outputURL, as: .mov)
            try await verifyMetadata(at: outputURL)
            logger.info("Embedded and verified \(metadata.count) metadata items in \(outputURL.lastPathComponent, privacy: .public)")
            return outputURL
        } catch {
            logger.error("Metadata export failed; retaining the valid source movie: \(error.localizedDescription, privacy: .public)")
            return sourceURL
        }
    }

    private static func makeMetadata(
        context: VideoMetadataContext,
        originalDuration: Double,
        finalDuration: Double
    ) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = [
            standard(.quickTimeMetadataSoftware, "1920SloMo \(shortAppVersion)"),
            standard(.quickTimeMetadataProducer, "Created with 1920SloMo"),
            standard(.quickTimeMetadataAuthor, "Recorded with 1920SloMo"),
            standard(.quickTimeUserDataURLLink, website),
            custom("nativeCaptureFPS", context.nativeCaptureFPS),
            custom("interpolationMultiplier", "\(context.interpolationMultiplier)x"),
            custom("equivalentFPS", context.equivalentFPS),
            custom("outputFPS", context.outputFPS),
            custom("slowMotionFactor", context.slowMotionFactor),
            custom("processingMode", context.processingMode),
            custom("interpolationMethod", context.interpolationMethod),
            custom("originalRecordingDurationSeconds", originalDuration),
            custom("finalVideoDurationSeconds", finalDuration),
            custom("appVersion", appVersion),
            custom("operatingSystem", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"),
            custom("website", website)
        ]

        if let camera = context.camera {
            append(camera.manufacturer, identifier: .quickTimeMetadataMake, to: &items)
            append(camera.deviceModel, identifier: .quickTimeMetadataModel, to: &items)
            append(camera.cameraIdentifier, identifier: .quickTimeMetadataCameraIdentifier, to: &items)
            append(camera.lensModel, identifier: .quickTimeMetadataCameraLensModel, to: &items)
            append(camera.aperture.map { String(format: "F%.2f", $0) }, identifier: .quickTimeMetadataCameraLensIrisFNumber, to: &items)
            append(camera.exposureDuration.map { String(format: "%.9f", $0) }, identifier: .quickTimeMetadataCameraShutterSpeedTime, to: &items)
            if let duration = camera.exposureDuration {
                append(String(format: "%.2fdeg", duration * Double(context.nativeCaptureFPS) * 360), identifier: .quickTimeMetadataCameraShutterSpeedAngle, to: &items)
            }
            append(camera.iso.map { String(format: "%.0f", $0) }, identifier: .quickTimeMetadataCameraISOSensitivity, to: &items)
            append(camera.whiteBalanceTemperature.map { String(format: "%.0fK", $0) }, identifier: .quickTimeMetadataCameraWhiteBalance, to: &items)
        }
        return items
    }

    private static func standard(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static func custom(_ name: String, _ value: Any) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: "mdta/\(namespace).\(name)")
        item.value = String(describing: value) as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static func append(_ value: String?, identifier: AVMetadataIdentifier, to items: inout [AVMetadataItem]) {
        guard let value, !value.isEmpty else { return }
        items.append(standard(identifier, value))
    }

    private static func verifyMetadata(at url: URL) async throws {
        let metadata = try await AVURLAsset(url: url).load(.metadata)
        let customNames = [
            "nativeCaptureFPS", "interpolationMultiplier", "equivalentFPS", "outputFPS",
            "slowMotionFactor", "processingMode", "interpolationMethod",
            "originalRecordingDurationSeconds", "finalVideoDurationSeconds", "appVersion",
            "operatingSystem", "website"
        ]
        var expectedCustomKeys = Set<String>()
        for name in customNames {
            expectedCustomKeys.insert("\(namespace).\(name)")
        }
        var retainedCustomKeys = Set<String>()
        var retainedStandardIdentifiers = Set<AVMetadataIdentifier>()
        for item in metadata {
            if let identifier = item.identifier {
                retainedStandardIdentifiers.insert(identifier)
                let rawIdentifier = identifier.rawValue
                if rawIdentifier.hasPrefix("mdta/") {
                    let customKey = String(rawIdentifier.dropFirst("mdta/".count))
                    if expectedCustomKeys.contains(customKey) {
                        retainedCustomKeys.insert(customKey)
                    }
                }
            }
            if let key = item.key as? String, expectedCustomKeys.contains(key) {
                retainedCustomKeys.insert(key)
            } else if let key = item.key as? NSString {
                let stringKey = String(key)
                if expectedCustomKeys.contains(stringKey) {
                    retainedCustomKeys.insert(stringKey)
                }
            }
        }
        let requiredStandardIdentifiers: Set<AVMetadataIdentifier> = [
            .quickTimeMetadataSoftware,
            .quickTimeMetadataProducer,
            .quickTimeMetadataAuthor,
            .quickTimeUserDataURLLink
        ]
        let standardCount = requiredStandardIdentifiers.intersection(retainedStandardIdentifiers).count
        logger.info(
            "Metadata verification: custom=\(retainedCustomKeys.count)/\(expectedCustomKeys.count), standard=\(standardCount)/\(requiredStandardIdentifiers.count)"
        )
        guard retainedCustomKeys == expectedCustomKeys else {
            let missing = expectedCustomKeys.subtracting(retainedCustomKeys).sorted().joined(separator: ", ")
            throw CameraError.processingFailed("The exported movie did not retain custom metadata: \(missing)")
        }
    }

    private static var shortAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private static var appVersion: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build, !build.isEmpty else { return shortAppVersion }
        return "\(shortAppVersion) (\(build))"
    }
}
