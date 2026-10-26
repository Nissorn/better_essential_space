import Foundation

/// Owns downloaded Record audio under Application Support/BetterEssentialSpace/audio/.
/// File name = SHA256(gcsKey).m4a — server-controlled gcsKeys are content-addressed
/// by hash, never used as paths, so there is no sanitization logic to get wrong.
/// The bytes are an MP4/M4A container whatever the `.aac` gcsKey suffix claims
/// (live-verified, notes/04); the extension is fixed and AVPlayer is
/// extension-agnostic. Files arrive by atomic move, so the only disk states are
/// "fully downloaded" or absent — an interrupted download leaves nothing behind.
public struct AudioStore: Sendable {
    public let directory: URL

    public init(directory: URL = AudioStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterEssentialSpace", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
    }

    /// nil until the file has fully landed (stat on the final name).
    public func existingURL(forGcsKey gcsKey: String) -> URL? {
        let url = fileURL(forGcsKey: gcsKey)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Moves a fully downloaded temp file to its final hash name. The final
    /// name only ever holds a complete file: `moveItem`/`replaceItemAt` are
    /// atomic renames, so an interrupted download (which never reaches this
    /// call) leaves nothing at the final name. Re-storing the same key
    /// replaces the previous complete file in one step.
    @discardableResult
    public func store(fileAt tempURL: URL, gcsKey: String) throws -> URL {
        let destination = fileURL(forGcsKey: gcsKey)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destination)
        }
        return destination
    }

    /// Sign-out hygiene, mirroring `RecordCache.remove`: gcsKeys are
    /// account-scoped server-side, so wiping keeps accounts from reading each
    /// other's audio. Re-download is always one signed URL away.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileURL(forGcsKey gcsKey: String) -> URL {
        directory.appendingPathComponent(AuthSigning.sha256Hex(Data(gcsKey.utf8)) + ".m4a")
    }
}
