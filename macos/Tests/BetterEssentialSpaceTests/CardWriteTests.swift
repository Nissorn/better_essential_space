import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

/// CardDocument surgery + Record.applying (issue 10): text edits mutate only the
/// three editable places, unknown keys survive, unchanged topics keep their bytes.
final class CardWriteTests: XCTestCase {
    // MARK: Helpers

    private func fixtureRecords() throws -> [Record] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "CardListRedacted", withExtension: "json", subdirectory: "Fixtures")
        )
        let envelope = try JSONDecoder().decode(LegacyEnvelope<CardListPage>.self, from: Data(contentsOf: url))
        return try envelope.data!.pageData.map { try Record(card: $0) }
    }

    private func payloadJSON(_ object: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func decoded(_ rawJSON: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rawJSON.utf8)) as? [String: Any])
    }

    private func analysisEntries(_ rawJSON: String) throws -> [[String: Any]] {
        try XCTUnwrap(try decoded(rawJSON)["card_analysis"] as? [[String: Any]])
    }

    /// Card-shaped raw document for tests that need shapes the fixture lacks
    /// (`detailed_summary` sources, unknown sibling keys).
    private func syntheticRawJSON(topicMetadata: String, extraSibling: Bool = false) throws -> String {
        var cards: [String: Any] = [
            "card_id": "c1", "title": "Title", "summary": NSNull(),
            "type": "RECORDING", "create_time": 1, "update_time": 2,
        ]
        if extraSibling { cards["future_field"] = ["deep": true] }
        var payload: [String: Any] = [
            "cards": cards,
            "card_resources": [],
            "card_analysis": [[
                "card_analysis_id": "a1",
                "raw_type": "MEETING_MAIN_TOPIC",
                "metadata": topicMetadata,
                "unknown_analysis_field": 7,
            ]],
            "brand_new_payload_key": "keep me",
        ]
        if extraSibling { payload["another_sibling"] = 42 }
        return try payloadJSON(payload)
    }

    // MARK: cards.title / cards.summary

    func testTitleAndSummaryEditsRewriteOnlyThoseKeys() throws {
        let record = try XCTUnwrap(fixtureRecords().first)
        let edited = try record.applying(
            .init(title: "New Title", summary: "New summary"),
            now: Date(epochMilliseconds: 9_000_000_000_000)
        )

        XCTAssertEqual(edited.title, "New Title")
        XCTAssertEqual(edited.summary, "New summary")
        XCTAssertEqual(edited.updatedAt, Date(epochMilliseconds: 9_000_000_000_000))

        let cards = try XCTUnwrap(try decoded(edited.clientRequestResponse)["cards"] as? [String: Any])
        XCTAssertEqual(cards["title"] as? String, "New Title")
        XCTAssertEqual(cards["summary"] as? String, "New summary")
        // Everything the edit did not touch is still there.
        XCTAssertEqual(cards["card_id"] as? String, record.id)
        XCTAssertEqual(cards["create_time"] as? Int64, 1_700_000_000_001)
        XCTAssertFalse(try analysisEntries(edited.clientRequestResponse).isEmpty)
    }

    func testEmptyEditLeavesDocumentBytesAndDerivationsUnchanged() throws {
        let record = try XCTUnwrap(fixtureRecords().first)
        let edited = try record.applying(.init())
        XCTAssertEqual(edited.clientRequestResponse, record.clientRequestResponse)
        XCTAssertEqual(edited.title, record.title)
        XCTAssertEqual(edited.mainTopics, record.mainTopics)
        XCTAssertEqual(edited.files, record.files)
        XCTAssertEqual(edited.audioFile, record.audioFile)
    }

    // MARK: Topic metadata surgery

    func testTopicEditsRewriteTitleAndContentKeys() throws {
        let record = try XCTUnwrap(fixtureRecords().first { $0.mainTopics.count == 2 })
        let topics = record.mainTopics
        let untouchedBytes = try analysisEntries(record.clientRequestResponse)
            .first { ($0["card_analysis_id"] as? String) == topics[1].id }?["metadata"] as? String

        let edited = try record.applying(
            .init(mainTopics: [
                MainTopic(id: topics[0].id, title: "Topic One Edited", content: "Rewritten content."),
                topics[1], // untouched topic
            ])
        )

        let entries = try analysisEntries(edited.clientRequestResponse)
        let first = try XCTUnwrap(entries.first { ($0["card_analysis_id"] as? String) == topics[0].id })
        let second = try XCTUnwrap(entries.first { ($0["card_analysis_id"] as? String) == topics[1].id })

        let firstMetadata = try decoded(try XCTUnwrap(first["metadata"] as? String))
        XCTAssertEqual(firstMetadata["title"] as? String, "Topic One Edited")
        XCTAssertEqual(firstMetadata["content"] as? String, "Rewritten content.")
        // The untouched topic keeps its metadata bytes exactly.
        XCTAssertEqual(second["metadata"] as? String, untouchedBytes)

        XCTAssertEqual(edited.mainTopics.first?.title, "Topic One Edited")
        XCTAssertEqual(edited.mainTopics.first?.content, "Rewritten content.")
        XCTAssertEqual(edited.mainTopics.last, topics[1])
    }

    func testDetailedSummaryIsTheWriteBackKeyWhenItWasTheSource() throws {
        let raw = try syntheticRawJSON(
            topicMetadata: #"{"title":"T","detailed_summary":"long form","content":"short"}"#
        )
        let document = try CardDocument(rawJSON: raw).applying(
            .init(mainTopics: [MainTopic(id: "a1", title: "T", content: "edited long form")])
        )
        let metadata = try decoded(try XCTUnwrap(
            try analysisEntries(document.rawJSON).first?["metadata"] as? String
        ))
        XCTAssertEqual(metadata["detailed_summary"] as? String, "edited long form")
        XCTAssertEqual(metadata["content"] as? String, "short", "the non-source key is untouched")
    }

    func testContentKeyIsAddedWhenNeitherExisted() throws {
        let raw = try syntheticRawJSON(topicMetadata: #"{"title":"T"}"#)
        let document = try CardDocument(rawJSON: raw).applying(
            .init(mainTopics: [MainTopic(id: "a1", title: "T", content: "new body")])
        )
        let metadata = try decoded(try XCTUnwrap(
            try analysisEntries(document.rawJSON).first?["metadata"] as? String
        ))
        XCTAssertEqual(metadata["content"] as? String, "new body")
        XCTAssertEqual(metadata["title"] as? String, "T")
    }

    func testClearingContentBlanksEveryContentBearingKey() throws {
        let raw = try syntheticRawJSON(topicMetadata: #"{"title":"T","content":"old"}"#)
        let document = try CardDocument(rawJSON: raw).applying(
            .init(mainTopics: [MainTopic(id: "a1", title: "T", content: nil)])
        )
        let metadata = try decoded(try XCTUnwrap(
            try analysisEntries(document.rawJSON).first?["metadata"] as? String
        ))
        XCTAssertEqual(metadata["content"] as? String, "")
        XCTAssertNil(metadata["detailed_summary"], "keys that never existed are not added")
    }

    func testPlainStringMetadataBecomesTheNewTitleString() throws {
        // Fixture card 3: metadata is a bare string carrying the topic title.
        let record = try XCTUnwrap(fixtureRecords().first { $0.id.hasSuffix("3") })
        let topic = try XCTUnwrap(record.mainTopics.first)
        let edited = try record.applying(
            .init(mainTopics: [MainTopic(id: topic.id, title: "Renamed plain topic", content: nil)])
        )

        let entry = try XCTUnwrap(
            try analysisEntries(edited.clientRequestResponse)
                .first { ($0["card_analysis_id"] as? String) == topic.id }
        )
        XCTAssertEqual(entry["metadata"] as? String, "Renamed plain topic")
        XCTAssertEqual(edited.mainTopics.first?.title, "Renamed plain topic")
        XCTAssertNil(edited.mainTopics.first?.content)
    }

    func testPlainStringTopicGainsContentAsJSON() throws {
        let raw = try syntheticRawJSON(topicMetadata: "Plain title")
        let document = try CardDocument(rawJSON: raw).applying(
            .init(mainTopics: [MainTopic(id: "a1", title: "Plain title", content: "now with body")])
        )
        let metadata = try decoded(try XCTUnwrap(
            try analysisEntries(document.rawJSON).first?["metadata"] as? String
        ))
        XCTAssertEqual(metadata["title"] as? String, "Plain title")
        XCTAssertEqual(metadata["content"] as? String, "now with body")
    }

    func testNoOpTopicEditIsByteIdentical() throws {
        let record = try XCTUnwrap(fixtureRecords().first)
        let edited = try record.applying(.init(mainTopics: record.mainTopics))
        XCTAssertEqual(edited.clientRequestResponse, record.clientRequestResponse)
    }

    func testUnresolvableTopicThrowsInvalidResponse() throws {
        let raw = try syntheticRawJSON(topicMetadata: #"{"title":"T","content":"c"}"#)
        XCTAssertThrowsError(
            try CardDocument(rawJSON: raw).applying(
                .init(mainTopics: [
                    MainTopic(id: "a1", title: "T", content: "c"),
                    MainTopic(id: "gone-id", title: "X", content: nil),
                ])
            )
        ) { error in
            XCTAssertEqual(error as? ESError, .invalidResponse("topic gone-id has no matching card_analysis entry"))
        }
    }

    func testEmotionalSummaryMetadataIsNeverTouchedByTopicEdits() throws {
        let record = try XCTUnwrap(fixtureRecords().first)
        let before = try analysisEntries(record.clientRequestResponse)
            .first { ($0["raw_type"] as? String) == "MEETING_EMOTIONAL_SUMMARY" }?["metadata"] as? String
        let edited = try record.applying(
            .init(mainTopics: [MainTopic(id: record.mainTopics[0].id, title: "New", content: nil)])
        )
        let after = try analysisEntries(edited.clientRequestResponse)
            .first { ($0["raw_type"] as? String) == "MEETING_EMOTIONAL_SUMMARY" }?["metadata"] as? String
        XCTAssertEqual(after, before)
    }

    // MARK: Unknown-key preservation

    func testUnknownKeysSurviveAnEditRoundTrip() throws {
        let raw = try syntheticRawJSON(topicMetadata: #"{"title":"T","content":"c"}"#, extraSibling: true)
        let edited = try CardDocument(rawJSON: raw).applying(
            .init(title: "Edited", mainTopics: [MainTopic(id: "a1", title: "T2", content: "c2")])
        )

        let payload = try decoded(edited.rawJSON)
        XCTAssertEqual(payload["brand_new_payload_key"] as? String, "keep me")
        XCTAssertEqual(payload["another_sibling"] as? Int, 42)

        let cards = try XCTUnwrap(payload["cards"] as? [String: Any])
        XCTAssertEqual((cards["future_field"] as? [String: Any])?["deep"] as? Bool, true)

        let entry = try XCTUnwrap(try analysisEntries(edited.rawJSON).first)
        XCTAssertEqual(entry["unknown_analysis_field"] as? Int, 7)

        // The edited Record re-decodes through the same init as a fresh decode.
        let record = try Record(
            card: Card(
                cardId: "c1",
                clientRequestResponse: edited.rawJSON,
                files: nil,
                clientCreateTime: nil,
                clientUpdateTime: nil,
                clientVersion: nil
            )
        )
        XCTAssertEqual(record.title, "Edited")
        XCTAssertEqual(record.mainTopics.first?.title, "T2")
    }

    func testUnparseableDocumentThrows() {
        XCTAssertThrowsError(
            try CardDocument(rawJSON: "not json at all").applying(.init(title: "x"))
        ) { error in
            guard case ESError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    func testRecordingSizeBytesSumsRecordingMetadata() throws {
        let records = try fixtureRecords()
        // Fixture card 1: one RECORDING of 1234567 bytes; card 3: 42 bytes.
        XCTAssertEqual(CardDocument.recordingSizeBytes(of: records[0].clientRequestResponse), 1_234_567)
        XCTAssertEqual(CardDocument.recordingSizeBytes(of: records[2].clientRequestResponse), 42)
        XCTAssertEqual(CardDocument.recordingSizeBytes(of: "{}"), 0)
    }

    // MARK: Write envelope (notes/04; vectors cross-checked against openssl)

    /// Key "0123456789abcdef0123456789abcdef": openssl enc -aes-256-ecb -K
    /// 3031323334353637383961626364656630313233343536373839616263646566.
    private static let vectorKeyB64 = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
    private static let vectorKey: Data = Data(base64Encoded: vectorKeyB64)!

    func testAES256ECBSealMatchesOpensslVectors() throws {
        XCTAssertEqual(try AES256ECB.seal("BES-test-device", key: Self.vectorKey), "5m/174rjC5yeSWq8CL1fMw==")
        XCTAssertEqual(try AES256ECB.seal("9747378", key: Self.vectorKey), "ba9GDF32c8OUmffFfhFU0A==")
    }

    func testEnvelopeSealsDevicePayloadAndPerCardSize() throws {
        let (privateKey, publicKey) = try Self.makeRSAKeyPair()
        let envelope = try WriteEnvelope.make(deviceId: "BES-test-device", claimKey: publicKey, aesKey: Self.vectorKey)

        XCTAssertEqual(envelope.devicePayload, "5m/174rjC5yeSWq8CL1fMw==")
        XCTAssertEqual(try envelope.sealed("9747378"), "ba9GDF32c8OUmffFfhFU0A==")

        // cipherKey unwraps with the private half back to the base64 key STRING.
        let cipherData = try XCTUnwrap(Data(base64Encoded: envelope.cipherKey))
        let unwrapped = try XCTUnwrap(
            SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, cipherData as CFData, nil) as Data?
        )
        XCTAssertEqual(String(data: unwrapped, encoding: .utf8), Self.vectorKeyB64)
    }

    func testEnvelopeRejectsWrongKeyLength() throws {
        let (_, publicKey) = try Self.makeRSAKeyPair()
        XCTAssertThrowsError(
            try WriteEnvelope.make(deviceId: "d", claimKey: publicKey, aesKey: Data(repeating: 1, count: 16))
        ) { error in
            guard case ESError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    private static func makeRSAKeyPair() throws -> (SecKey, SecKey) {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        return (privateKey, publicKey)
    }

    // MARK: claimKey (disk-only secret, issue 10)

    func testClaimKeyMissingOrEmptyFileThrowsMissingClaimKey() throws {
        let directory = try temporarySecretsDirectory()
        let path = directory.appendingPathComponent(RuntimeSecrets.claimKeyFilename).path

        XCTAssertThrowsError(try RuntimeSecrets.claimKey(directory: directory)) { error in
            XCTAssertEqual(error as? ESError, .missingClaimKey(path))
        }

        try Data("  \n".utf8).write(to: directory.appendingPathComponent(RuntimeSecrets.claimKeyFilename))
        XCTAssertThrowsError(try RuntimeSecrets.claimKey(directory: directory)) { error in
            XCTAssertEqual(error as? ESError, .missingClaimKey(path))
        }
    }

    func testClaimKeyUndecodableOrNotRSAThrowsInvalidClaimKey() throws {
        let directory = try temporarySecretsDirectory()
        let fileURL = directory.appendingPathComponent(RuntimeSecrets.claimKeyFilename)

        try Data("this is not base64 !!".utf8).write(to: fileURL)
        XCTAssertThrowsError(try RuntimeSecrets.claimKey(directory: directory)) { error in
            XCTAssertEqual(error as? ESError, .invalidClaimKey(fileURL.path))
        }

        // Valid base64, but not RSA key material.
        try Data(repeating: 7, count: 64).base64EncodedString().write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RuntimeSecrets.claimKey(directory: directory)) { error in
            XCTAssertEqual(error as? ESError, .invalidClaimKey(fileURL.path))
        }
    }

    func testClaimKeyLoadsSingleLineAndPEMWrappedFiles() throws {
        let directory = try temporarySecretsDirectory()
        let fileURL = directory.appendingPathComponent(RuntimeSecrets.claimKeyFilename)
        let (_, publicKey) = try Self.makeRSAKeyPair()
        let external = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)

        // Single-line base64 (the frida-dump shape).
        try external.base64EncodedString().write(to: fileURL, atomically: true, encoding: .utf8)
        let singleLine = try RuntimeSecrets.claimKey(directory: directory)
        XCTAssertEqual(try XCTUnwrap(SecKeyCopyExternalRepresentation(singleLine, nil) as Data?), external)

        // PEM armor + 64-column wrapping tolerated.
        let base64 = external.base64EncodedString()
        let wrapped = stride(from: 0, to: base64.count, by: 64).map {
            String(base64[base64.index(base64.startIndex, offsetBy: $0)...])
        }
        let pem = (["-----BEGIN PUBLIC KEY-----"] + wrapped + ["-----END PUBLIC KEY-----"])
            .joined(separator: "\n") + "\n"
        try Data(pem.utf8).write(to: fileURL)
        let pemWrapped = try RuntimeSecrets.claimKey(directory: directory)
        XCTAssertEqual(try XCTUnwrap(SecKeyCopyExternalRepresentation(pemWrapped, nil) as Data?), external)
    }

    private func temporarySecretsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claim-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
