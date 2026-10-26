import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

/// Offline snapshot round-trip (issue 09): Records + Collections persist to a
/// JSON file and load back byte-equal.
final class RecordCacheTests: XCTestCase {
    private func fixtureRecord() throws -> Record {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "CardListRedacted", withExtension: "json", subdirectory: "Fixtures")
        )
        let envelope = try JSONDecoder().decode(LegacyEnvelope<CardListPage>.self, from: Data(contentsOf: url))
        return try XCTUnwrap(try envelope.data?.pageData.map { try Record(card: $0) }.first)
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("record-cache-\(UUID().uuidString).json")
    }

    func testRoundTripPreservesRecordsAndCollections() throws {
        let record = try fixtureRecord()
        let collection = CollectionSummary(
            collectionId: "70000000-0000-4000-8000-00000000000a",
            name: "Synthetic Collection",
            count: 1,
            clientCreateTime: 1,
            clientUpdateTime: 2
        )
        let snapshot = CachedSnapshot(
            accountUUID: "u-1",
            savedAt: Date(timeIntervalSince1970: 1_700_000_000.25),
            records: [record],
            collections: [collection]
        )
        let url = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try RecordCache.save(snapshot, to: url)
        XCTAssertEqual(RecordCache.load(from: url), snapshot)
    }

    func testMissingAndCorruptFilesAreJustNoCache() throws {
        let missing = temporaryCacheURL()
        XCTAssertNil(RecordCache.load(from: missing))

        let corrupt = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: corrupt) }
        try Data("not json".utf8).write(to: corrupt)
        XCTAssertNil(RecordCache.load(from: corrupt))
    }

    /// One-time cache bump: `clientRequestResponse` became non-optional, so a
    /// snapshot written before the field existed fails to decode — which the
    /// loader treats as "no cache". The next launch re-fetches from the network.
    func testSnapshotWithoutClientRequestResponseIsNoCache() throws {
        let oldRecordJSON = """
        {"id":"c1","title":"t","summary":null,"createdAt":700000000000,"updatedAt":700000000000,
         "transcript":null,"audioDurationMS":null,"audioSizeBytes":null,"audioGcsKey":"k",
         "mainTopics":[],"emotionalSummary":null,"speakers":[],"collectionIds":[]}
        """
        let snapshotJSON = """
        {"accountUUID":"u-1","savedAt":700000000000,"records":[\(oldRecordJSON)],"collections":[]}
        """
        let url = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(snapshotJSON.utf8).write(to: url)

        XCTAssertNil(RecordCache.load(from: url))
    }
}
