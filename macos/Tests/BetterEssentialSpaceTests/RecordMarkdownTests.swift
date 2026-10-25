import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

/// RecordMarkdown formatting against the redacted fixture (synthetic values).
final class RecordMarkdownTests: XCTestCase {
    private func fixtureRecords() throws -> [Record] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "CardListRedacted", withExtension: "json", subdirectory: "Fixtures")
        )
        let envelope = try JSONDecoder().decode(LegacyEnvelope<CardListPage>.self, from: Data(contentsOf: url))
        return try envelope.data!.pageData.map { try Record(card: $0) }
    }

    func testDocumentContainsEverySection() throws {
        let record = try XCTUnwrap(fixtureRecords().first { $0.id == "10000000-0000-4000-8000-000000000001" })
        let markdown = RecordMarkdown.document(for: record, collectionNames: ["Ray Summit"])

        XCTAssertTrue(markdown.hasPrefix("# Synthetic Record One\n"))
        XCTAssertTrue(markdown.contains("- **Date:**"))
        XCTAssertTrue(markdown.contains("- **Duration:**"))
        XCTAssertTrue(markdown.contains("- **Size:**"))
        XCTAssertTrue(markdown.contains("- **Collections:** Ray Summit"))
        XCTAssertTrue(markdown.contains("- **Speakers:** Speaker 1"))
        XCTAssertTrue(markdown.contains("> Synthetic one-line tone summary."))
        XCTAssertTrue(markdown.contains("## Summary"))
        XCTAssertTrue(markdown.contains("## Main topics"))
        XCTAssertTrue(markdown.contains("1. **Synthetic Topic One**"))
        XCTAssertTrue(markdown.contains("2. **Synthetic Topic Two**"))
        XCTAssertTrue(markdown.contains("## Transcript"))
        XCTAssertTrue(markdown.contains("Synthetic transcript one."))
    }

    func testCombinedJoinsRecordsWithRules() throws {
        let records = try fixtureRecords()
        let markdown = RecordMarkdown.combined(records: records)

        XCTAssertTrue(markdown.hasPrefix("# Essential Space Records"))
        XCTAssertTrue(markdown.contains("# Synthetic Record One"))
        XCTAssertTrue(markdown.contains("# Synthetic Record Two"))
        XCTAssertTrue(markdown.contains("\n---\n"))
    }

    func testFileNameSanitizesPathCharacters() throws {
        let card = try JSONDecoder().decode(
            Card.self,
            from: Data(
                #"{"cardId":"c-x","client_request_response":"{\"cards\":{\"card_id\":\"c-x\",\"title\":\"Road/Plan: Ideas\",\"summary\":null,\"type\":\"RECORDING\",\"create_time\":1700000000000,\"update_time\":1700000000001},\"card_resources\":[]}","clientCreateTime":1700000000000,"clientUpdateTime":1700000000001}"#
                    .utf8
            )
        )
        let record = try Record(card: card)
        let name = RecordMarkdown.fileName(for: record)
        XCTAssertTrue(name.hasSuffix(" Road-Plan- Ideas.md"), name)
        XCTAssertTrue(name.hasPrefix("20"), name)
    }
}
