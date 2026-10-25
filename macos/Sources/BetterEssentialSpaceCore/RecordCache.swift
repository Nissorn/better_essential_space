import Foundation

/// The on-disk snapshot of the last successful load: Records + Collections of
/// one Nothing Account, shown instantly on the next launch while a fresh load
/// runs in the background. Guarded by `accountUUID` so a snapshot is never
/// shown to a different signed-in account.
public struct CachedSnapshot: Codable, Equatable, Sendable {
    public var accountUUID: String?
    public var savedAt: Date
    public var records: [Record]
    public var collections: [CollectionSummary]

    public init(
        accountUUID: String?,
        savedAt: Date = Date(),
        records: [Record],
        collections: [CollectionSummary]
    ) {
        self.accountUUID = accountUUID
        self.savedAt = savedAt
        self.records = records
        self.collections = collections
    }
}

public enum RecordCache {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterEssentialSpace", isDirectory: true)
            .appendingPathComponent("records-cache.json")
    }

    public static func save(_ snapshot: CachedSnapshot, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    /// A missing, unreadable, or corrupt snapshot is simply "no cache".
    public static func load(from url: URL = defaultURL) -> CachedSnapshot? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(CachedSnapshot.self, from: data)
    }

    public static func remove(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
