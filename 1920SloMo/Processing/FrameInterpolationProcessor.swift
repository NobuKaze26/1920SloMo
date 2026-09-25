import AVFoundation
import CoreImage
import CoreVideo
import OSLog
#if !targetEnvironment(simulator)
import VideoToolbox
#endif

/// Streams captured and VideoToolbox-interpolated frames into a hardware-encoded movie.
final class FrameInterpolationProcessor: @unchecked Sendable {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let logger = Logger(subsystem: "ExtremeSloMo", category: "Processing")

#if targetEnvironment(simulator)
    static let isAppleInterpolationAvailable = false
#else
    static var isAppleInterpolationAvailable: Bool {
        if #available(iOS 26.0, *) { true } else { false }
    }
#endif

    func process(
        sourceURL: URL,
        capturedFPS: Int,
        multiplier: Int,
        playbackFPS: Int,
        aspectRatio: CaptureAspectRatio,
        quality: InterpolationQuality,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard [1, 2, 4, 8].contains(multiplier) else {
            throw CameraError.interpolationUnsupported
        }
        if multiplier > 1, !Self.isAppleInterpolationAvailable {
            throw CameraError.interpolationUnsupported
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CameraError.processingFailed("The source has no video track.")
        }
        let sourceSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw CameraError.processingFailed("Unable to create the video reader.")
        }
        reader.add(readerOutput)

        let outputHeight = Int(sourceSize.height.rounded()) & ~1
        let sourceWidth = Int(sourceSize.width.rounded()) & ~1
        let outputWidth = aspectRatio == .standard ? Int(Double(outputHeight) * 4 / 3) & ~1 : sourceWidth
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "processed-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(12_000_000, outputWidth * outputHeight * 8),
                    AVVideoExpectedSourceFrameRateKey: playbackFPS,
                    AVVideoMaxKeyFrameIntervalKey: playbackFPS
                ]
            ]
        )
        input.expectsMediaDataInRealTime = false
        // Preserve the source movie's display orientation in the processed movie.
        input.transform = preferredTransform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(input) else {
            throw CameraError.processingFailed("Unable to configure the HEVC writer.")
        }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw CameraError.processingFailed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "Unable to start processing.")
        }
        writer.startSession(atSourceTime: .zero)

        var frameIndex: Int64 = 0
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(playbackFPS))
        let expectedFrames = max(1, Int(duration.seconds * Double(capturedFPS)) * multiplier)
        var currentSample = readerOutput.copyNextSampleBuffer()

#if !targetEnvironment(simulator)
        var frameProcessor: VTFrameProcessor?
        var interpolationPool: CVPixelBufferPool?
        if multiplier > 1 {
            guard #available(iOS 26.0, *) else { throw CameraError.interpolationUnsupported }
            let processor = VTFrameProcessor()
            let priority: VTFrameRateConversionConfiguration.QualityPrioritization =
                quality == .quality ? .quality : .normal
            guard let configuration = VTFrameRateConversionConfiguration(
                frameWidth: sourceWidth,
                frameHeight: outputHeight,
                usePrecomputedFlow: false,
                qualityPrioritization: priority,
                revision: .revision1
            ), VTFrameRateConversionConfiguration.isSupported else {
                throw CameraError.interpolationUnsupported
            }
            try processor.startSession(configuration: configuration)
            frameProcessor = processor
            interpolationPool = try makePixelBufferPool(width: sourceWidth, height: outputHeight)
        }
        defer { frameProcessor?.endSession() }
#endif

        while let sample = currentSample,
              let source = CMSampleBufferGetImageBuffer(sample) {
            try Task.checkCancellation()
            try await append(
                source,
                at: CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex)),
                to: adaptor,
                input: input,
                outputWidth: outputWidth,
                outputHeight: outputHeight
            )
            frameIndex += 1

#if !targetEnvironment(simulator)
            let nextSample = readerOutput.copyNextSampleBuffer()
            let nextBuffer = nextSample.flatMap(CMSampleBufferGetImageBuffer)
            if multiplier > 1, let nextBuffer, let frameProcessor, let interpolationPool {
                guard #available(iOS 26.0, *) else { throw CameraError.interpolationUnsupported }
                let phases = InterpolationMultiplier.phases(for: multiplier)
                let outputBuffers = try phases.map { _ in
                    try makePixelBuffer(from: interpolationPool)
                }
                let sourceTime = CMSampleBufferGetPresentationTimeStamp(sample)
                let baseTime = sourceTime.isValid ? sourceTime : CMTime(value: frameIndex - 1, timescale: CMTimeScale(capturedFPS))
                guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: baseTime),
                      let nextFrame = VTFrameProcessorFrame(
                        buffer: nextBuffer,
                        presentationTimeStamp: CMTimeAdd(baseTime, CMTime(value: 1, timescale: CMTimeScale(capturedFPS)))
                      ) else {
                    throw CameraError.processingFailed("Unable to prepare source frames for interpolation.")
                }
                let destinationFrames = try zip(phases, outputBuffers).map { phase, buffer in
                    let offset = CMTimeMultiplyByFloat64(
                        CMTime(value: 1, timescale: CMTimeScale(capturedFPS)),
                        multiplier: Double(phase)
                    )
                    let time = CMTimeAdd(baseTime, offset)
                    guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time) else {
                        throw CameraError.processingFailed("Unable to prepare an interpolation destination.")
                    }
                    return frame
                }
                guard let parameters = VTFrameRateConversionParameters(
                    sourceFrame: sourceFrame,
                    nextFrame: nextFrame,
                    opticalFlow: nil,
                    interpolationPhase: phases,
                    submissionMode: .sequential,
                    destinationFrames: destinationFrames
                ) else {
                    throw CameraError.processingFailed("Unable to configure frame interpolation.")
                }
                try await process(parameters, with: frameProcessor)
                for buffer in outputBuffers {
                    try await append(
                        buffer,
                        at: CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex)),
                        to: adaptor,
                        input: input,
                        outputWidth: outputWidth,
                        outputHeight: outputHeight
                    )
                    frameIndex += 1
                }
            }
            currentSample = nextSample
#else
            currentSample = readerOutput.copyNextSampleBuffer()
#endif
            progress(min(0.99, Double(frameIndex) / Double(expectedFrames)))
        }

        guard reader.status == .completed else {
            throw CameraError.processingFailed(reader.error?.localizedDescription ?? "Video decoding did not complete.")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CameraError.processingFailed(writer.error?.localizedDescription ?? "Video encoding did not complete.")
        }
        progress(1)
        logger.info("Finished slow-motion export at \(capturedFPS * multiplier) FPS equivalent")
        return outputURL
    }

#if !targetEnvironment(simulator)
    @available(iOS 26.0, *)
    private func process(
        _ parameters: VTFrameRateConversionParameters,
        with processor: VTFrameProcessor
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processor.process(parameters: parameters) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func makePixelBufferPool(width: Int, height: Int) throws -> CVPixelBufferPool {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else {
            throw CameraError.processingFailed("Unable to create an interpolation buffer pool.")
        }
        return pool
    }

    private func makePixelBuffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else {
            throw CameraError.processingFailed("Unable to allocate an interpolation frame.")
        }
        return buffer
    }
#endif

    private func append(
        _ source: CVPixelBuffer,
        at time: CMTime,
        to adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        outputWidth: Int,
        outputHeight: Int
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(2))
        }
        let sourceWidth = CVPixelBufferGetWidth(source)
        if sourceWidth == outputWidth && CVPixelBufferGetHeight(source) == outputHeight {
            guard adaptor.append(source, withPresentationTime: time) else {
                throw CameraError.processingFailed("The encoder rejected a source frame.")
            }
            return
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw CameraError.processingFailed("No crop buffer pool is available.")
        }
        var cropped: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &cropped) == kCVReturnSuccess,
              let cropped else {
            throw CameraError.processingFailed("Unable to allocate a crop frame.")
        }
        let x = Swift.max(CGFloat.zero, (CGFloat(sourceWidth) - CGFloat(outputWidth)) / 2)
        let image = CIImage(cvPixelBuffer: source)
        let crop = image.cropped(to: CGRect(x: x, y: 0, width: CGFloat(outputWidth), height: CGFloat(outputHeight)))
            .transformed(by: CGAffineTransform(translationX: -x, y: 0))
        ciContext.render(crop, to: cropped)
        guard adaptor.append(cropped, withPresentationTime: time) else {
            throw CameraError.processingFailed("The encoder rejected a cropped frame.")
        }
    }
}
