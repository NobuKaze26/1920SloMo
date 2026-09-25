import SwiftUI
import UniformTypeIdentifiers

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.quickTimeMovie] }
    let sourceURL: URL?

    init(sourceURL: URL? = nil) { self.sourceURL = sourceURL }
    init(configuration: ReadConfiguration) throws { sourceURL = nil }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let sourceURL else { throw CocoaError(.fileNoSuchFile) }
        return try FileWrapper(url: sourceURL, options: .immediate)
    }
}
