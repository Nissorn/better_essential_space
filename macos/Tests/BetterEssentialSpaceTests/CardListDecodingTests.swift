import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

/// Card-list decoding against the REDACTED fixture (same shape as
/// `secrets/fixtures/card_list_sample.json`, fully synthetic values).
final class CardListDecodingTests: XCTestCase {
    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "CardListRedacted", withExtension: "json", subdirectory: "Fixtures"),
            "CardListRedacted.json missing from test resources"
        )
        return try Data(contentsOf: url)
    }

    func testEnvelopeAndPageDecoding() throws {
        let envelope = try JSONDecoder().decode(LegacyEnvelope<CardListPage>.self, from: fixtureData())

        XCTAssertEqual(envelope.code, "00000")
        XCTAssertEqual(envelope.msg, "success")
        let page = try XCTUnwrap(envelope.data)
        XCTAssertEqual(page.pageNo, 1)
        XCTAssertEqual(page.pageSize, 20)
        XCTAssertEqual(page.hasNextPage, false)
        XCTAssertEqual(page.pageData.count, 3)
    }

    func testCardWireFieldsAndDoubleDecode() throws {
        let envelope = try JSONDecoder().decode(LegacyEnvelope<CardListPage>.self, from: fixtureData())
        let card = try XCTUnwrap(envelope.data?.pageData.first)

        XCTAssertEqual(card.cardId, "10000000-0000-4000-8000-000000000001")
        XCTAssertEqual(card.clientVersion, 2)
        XCTAssertEqual(card.files?.first?.region, "asia-south1")

        // Second decode: client_request_response is a JSON-encoded string.
        let payload = try JSONDecoder().decode(
            CardPayload.self,
            from: try XCTUnwrap(card.clientRequestResponse.data(using: .utf8))
        )
        XCTAssertEqual(payload.cards.cardId, card.cardId)
        XCTAssertEqual(payload.cards.title, "Synthetic Record One")
        XCTAssertEqual(payload.cards.type, "RECORDING")
        XCTAssertEqual(payload.cards.resourceMask, 1028)
        XCTAssertEqual(payload.cardResources.count, 2)

        let recording = try XCTUnwrap(payload.cardResources.first { $0.rawType == .recording })
        XCTAssertEqual(recording.mimeType, "audio/aac")
        XCTAssertEqual(recording.remoteRegion, "asia-south1")
        XCTAssertEqual(
            recording.remoteGcsKey,
            "audioRequest/db41be7278059497304a7a408a6c303d/10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-000000000001.aac"
        )
        let metadata = try JSONDecoder().decode(
            RecordingMetadata.self,
            from: try XCTUnwrap(recording.metadata?.data(using: .utf8))
        )
        XCTAssertEqual(metadata.size, 1_234_567)
        XCTAssertEqual(metadata.duration, 119_000)
        XCTAssertEqual(metadata.startTime, 1_700_000_000_000)

        let transcription = try XCTUnwrap(payload.cardResources.first { $0.rawType == .transcription })
        XCTAssertEqual(transcription.mimeType, "text/plain")
        XCTAssertEqual(transcription.metadata, nil)
        XCTAssertEqual(transcription.parentId, recording.cardResourceId)
    }

    func testRecordDomainDecoding() throws {
        let envelope = try JSONDecoder().decode(LegacyEnvelope<CardListPage>.self, from: fixtureData())
        let records = try envelope.data!.pageData.map { try Record(card: $0) }

        // Card 1: RECORDING + TRANSCRIPTION.
        let first = try XCTUnwrap(records.first { $0.id == "10000000-0000-4000-8000-000000000001" })
        XCTAssertEqual(first.title, "Synthetic Record One")
        XCTAssertEqual(first.summary, "A fully synthetic summary used only as a decoder fixture.")
        XCTAssertEqual(
            first.transcript,
            "Synthetic transcript one. This sentence is generated text with no origin in any real recording. Second sentence checks multiline handling."
        )
        XCTAssertEqual(first.audioDurationMS, 119_000)
        XCTAssertEqual(first.audioSizeBytes, 1_234_567)
        XCTAssertEqual(first.createdAt, Date(epochMilliseconds: 1_700_000_000_001))

        // Main topics, emotional summary, speakers (card_analysis / meeting_speakers).
        XCTAssertEqual(first.mainTopics.map(\.title), ["Synthetic Topic One", "Synthetic Topic Two"])
        XCTAssertEqual(first.mainTopics.first?.content, "Synthetic content for the first main topic.")
        XCTAssertEqual(first.emotionalSummary, "Synthetic one-line tone summary.")
        XCTAssertEqual(first.speakers.count, 1)
        XCTAssertEqual(first.speakers.first?.speakerId, "Speaker 1")
        XCTAssertEqual(
            first.mainTopicsText,
            "1. Synthetic Topic One\nSynthetic content for the first main topic.\n\n"
                + "2. Synthetic Topic Two\nSynthetic content for the second main topic."
        )

        // Card 2: RECORDING only — transcript must be nil, not an empty string.
        let second = try XCTUnwrap(records.first { $0.id == "10000000-0000-4000-8000-000000000002" })
        XCTAssertNil(second.transcript)
        XCTAssertEqual(second.audioDurationMS, 30_000)

        // Card 3: null summary decodes to nil; plain-string main-topic metadata
        // (fallback) still yields a topic with no content.
        let third = try XCTUnwrap(records.first { $0.id == "10000000-0000-4000-8000-000000000003" })
        XCTAssertNil(third.summary)
        XCTAssertEqual(third.transcript, "Synthetic transcript three.")
        XCTAssertEqual(third.mainTopics.map(\.title), ["Plain string topic title"])
        XCTAssertNil(third.mainTopics.first?.content)
    }

    func testUnknownInnerKeysAreIgnored() throws {
        // card_collection_cross_ref and any brand-new sibling keys are tolerated.
        let payloadJSON = """
        {"cards":{"card_id":"c1","title":"t","summary":null,"type":"RECORDING","create_time":1,"update_time":2,"resource_mask":4},
         "card_resources":[],
         "brand_new_field":{"anything":true}}
        """
        let payload = try JSONDecoder().decode(CardPayload.self, from: Data(payloadJSON.utf8))
        XCTAssertEqual(payload.cards.title, "t")
        XCTAssertTrue(payload.cardResources.isEmpty)
    }

    func testUnknownRawTypesDecodeLenientlyInsteadOfDroppingTheCard() throws {
        // A future server-side analysis or resource kind must not make Record(card:)
        // throw (the caller drops such Cards silently).
        let payloadJSON = """
        {"cards":{"card_id":"c1","title":"t","summary":null,"type":"RECORDING","create_time":1,"update_time":2,"resource_mask":4},
         "card_resources":[
            {"card_resource_id":"r1","raw_type":"IMAGE","data":""},
            {"card_resource_id":"r2","raw_type":"TRANSCRIPTION","data":"synthetic transcript"}],
         "card_analysis":[{"card_analysis_id":"a1","raw_type":"SOME_FUTURE_TYPE","metadata":"{}"}]}
        """
        let payload = try JSONDecoder().decode(CardPayload.self, from: Data(payloadJSON.utf8))
        XCTAssertEqual(payload.cardAnalysis?.first?.rawType, .unknown)
        XCTAssertEqual(payload.cardResources.first?.rawType, .unknown)
        let card = Card(
            cardId: "c1",
            clientRequestResponse: payloadJSON,
            files: nil,
            clientCreateTime: nil,
            clientUpdateTime: nil,
            clientVersion: nil
        )
        let record = try Record(card: card)
        XCTAssertEqual(record.transcript, "synthetic transcript")
        XCTAssertTrue(record.mainTopics.isEmpty)
    }
}
