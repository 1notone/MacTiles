import Foundation

/// Folders the App Store edition's sandbox only lets it read after you've chosen them once.
///
/// Choosing a folder in an open panel grants access for the session; a security-scoped
/// bookmark, saved in layout.json, lets the app open it again after a restart. Outside the
/// sandbox (the GitHub edition) folders are simply read by path.
@MainActor
enum FolderAccess {
    private static var opened: [String: URL] = [:]

    /// A bookmark to save alongside a folder you just chose; nil outside the sandbox.
    static func bookmark(for url: URL) -> Data? {
        guard Edition.isSandboxed else { return nil }
        return try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The Photos tile's folder, opened for reading (in the sandbox, from its bookmark).
    static func photosFolder(_ settings: AppSettings) -> String {
        path(settings.photosFolder, bookmark: settings.photosFolderBookmark)
    }

    static func path(_ path: String, bookmark: Data?) -> String {
        guard Edition.isSandboxed, let bookmark else { return path }
        if let url = opened[path] { return url.path }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return path }
        if url.startAccessingSecurityScopedResource() { opened[path] = url }
        return url.path
    }
}
