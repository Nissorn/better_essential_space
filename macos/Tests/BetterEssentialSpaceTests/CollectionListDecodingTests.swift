import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

/// Collection list decoding — the shape captured live (notes/03 § Collections),
/// with fully synthetic values.
final class CollectionListDecodingTests: XCTestCase {
    func testDecodesCapturedEnvelope() throws {
        let json = """
        {"code":"00000","msg":"success","data":[
          {"collectionId":"70000000-0000-4000-8000-00000000000a",
           "collectionName":"Synthetic Collection",
           "count":6,
           "clientUpdateTime":1792848570546,
           "clientCreateTime":1792848570546}
        ]}
        """
        let envelope = try JSONDecoder().decode(LegacyEnvelope<[CollectionSummary]>.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.code, "00000")
        let collection = try XCTUnwrap(envelope.data?.first)
        XCTAssertEqual(collection.collectionId, "70000000-0000-4000-8000-00000000000a")
        XCTAssertEqual(collection.name, "Synthetic Collection")
        XCTAssertEqual(collection.count, 6)
        XCTAssertEqual(collection.clientCreateTime, 1_792_848_570_546)
        XCTAssertEqual(collection.clientUpdateTime, 1_792_848_570_546)
    }

    func testEveryFieldOptionalAndUnknownKeysIgnored() throws {
        let json = """
        {"code":"00000","msg":"success","data":[{"collectionId":"c1"},{"collectionName":"No ID","brand_new":true}]}
        """
        let envelope = try JSONDecoder().decode(LegacyEnvelope<[CollectionSummary]>.self, from: Data(json.utf8))
        let collections = try XCTUnwrap(envelope.data)
        XCTAssertEqual(collections.count, 2)
        XCTAssertNil(collections[0].name)
        XCTAssertEqual(collections[1].name, "No ID")
        XCTAssertNil(collections[1].collectionId)
    }
}
