import Foundation
import Observation

@MainActor
@Observable
final class StorageDestinationManager {
    private static let bookmarkKey = "externalStorageDestinationBookmark"

    private(set) var isExternalDriveAvailable = false
    private(set) var selectedDestinationName: String?
    private(set) var statusMessage: String?
    private var destinationURL: URL?
    private var isAccessingDestination = false

    init() {
        refreshAvailability(notify: false)
    }

    func selectDestination(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            stopAccessingDestination()
            destinationURL = url
            selectedDestinationName = displayName(for: url)
            isExternalDriveAvailable = accessAndVerify(url)
            if !isExternalDriveAvailable {
                stopAccessingDestination()
            }

            if isExternalDriveAvailable {
                statusMessage = "External storage selected. New recordings will save there."
            } else {
                statusMessage = "The selected storage is unavailable. Recordings will continue saving to Photos."
            }
        } catch {
            statusMessage = "Could not remember that storage location. Recordings will continue saving to Photos."
        }
    }

    func clearStatusMessage() {
        statusMessage = nil
    }

    func suspend() {
        stopAccessingDestination()
    }

    func refreshAvailability(notify: Bool = true) {
        let wasAvailable = isExternalDriveAvailable
        let url = destinationURL ?? resolveDestination()
        isExternalDriveAvailable = url.map(accessAndVerify) ?? false
        if !isExternalDriveAvailable {
            stopAccessingDestination()
        }

        guard notify, wasAvailable != isExternalDriveAvailable else { return }
        statusMessage = isExternalDriveAvailable
            ? "External storage is available. New recordings will save there."
            : "External storage was disconnected. New recordings will save to Photos."
    }

    func saveVideos(
        processedURL: URL,
        originalURL: URL?,
        capturedFPS: Int,
        equivalentFPS: Int
    ) async throws -> String {
        refreshAvailability()

        guard let destinationURL, isExternalDriveAvailable else {
            try await PhotoLibraryManager.saveVideo(at: processedURL)
            if let originalURL {
                try await PhotoLibraryManager.saveVideo(at: originalURL)
            }
            return "Photos"
        }

        do {
            let processedName = VideoMath.outputFilename(
                capturedFPS: capturedFPS,
                equivalentFPS: equivalentFPS
            )
            try copy(processedURL, to: destinationURL.appending(path: processedName))

            if let originalURL {
                let originalName = processedName.replacingOccurrences(of: ".mov", with: "_original.mov")
                try copy(originalURL, to: destinationURL.appending(path: originalName))
            }
            return selectedDestinationName ?? displayName(for: destinationURL)
        } catch {
            isExternalDriveAvailable = false
            stopAccessingDestination()
            statusMessage = "Could not save to external storage. This recording was saved to Photos instead."
            try await PhotoLibraryManager.saveVideo(at: processedURL)
            if let originalURL {
                try await PhotoLibraryManager.saveVideo(at: originalURL)
            }
            return "Photos"
        }
    }

    private func resolveDestination() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                let updatedBookmark = try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(updatedBookmark, forKey: Self.bookmarkKey)
            }
            destinationURL = url
            selectedDestinationName = displayName(for: url)
            return url
        } catch {
            return nil
        }
    }

    private func displayName(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .nameKey])
        return values?.volumeLocalizedName ?? values?.name ?? url.lastPathComponent
    }

    private func accessAndVerify(_ url: URL) -> Bool {
        if !isAccessingDestination {
            guard url.startAccessingSecurityScopedResource() else { return false }
            isAccessingDestination = true
        }

        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeIsReadOnlyKey])
            return values.isDirectory == true && values.volumeIsReadOnly != true
        } catch {
            return false
        }
    }

    private func stopAccessingDestination() {
        guard isAccessingDestination, let destinationURL else { return }
        destinationURL.stopAccessingSecurityScopedResource()
        isAccessingDestination = false
    }

    private func copy(_ sourceURL: URL, to destinationURL: URL) throws {
        guard isAccessingDestination else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let directoryURL = destinationURL.deletingLastPathComponent()
        var coordinationError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: directoryURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedDirectoryURL in
            let coordinatedDestinationURL = coordinatedDirectoryURL.appending(path: destinationURL.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: coordinatedDestinationURL.path) {
                    try FileManager.default.removeItem(at: coordinatedDestinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: coordinatedDestinationURL)
            } catch {
                copyError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }
}
