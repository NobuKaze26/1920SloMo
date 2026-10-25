import Photos

enum PhotoLibraryManager {
    static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .notDetermined else { return status }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    static func saveVideo(at url: URL) async throws {
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            throw CameraError.permissionDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }
}
