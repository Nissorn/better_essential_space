import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

/// AudioStore (issue 09): hash-addressed files, atomic writes, idempotent
/// re-stores, and full wipe for sign-out.
final class AudioStoreTests: XCTestCase {
    private var directory: URL!
    private var store: AudioStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-store-\(UUID().uuidString)", isDirectory: true)
        store = AudioStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func expectedFileName(for gcsKey: String) -> String {
        AuthSigning.sha256Hex(Data(gcsKey.utf8)) + ".m4a"
    }

    func testNothingExistsUntilStored() {
        XCTAssertNil(store.existingURL(forGcsKey: "audioRequest/x/c1/r1.aac"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testStoreWritesHashNamedFileAndReadsItBack() throws {
        let gcsKey = "audioRequest/md5/cardId/resId.aac"
        let bytes = Data("m4a-container-bytes".utf8)
        let url = try store.store(bytes, gcsKey: gcsKey)

        XCTAssertEqual(url.lastPathComponent, expectedFileName(for: gcsKey))
        XCTAssertEqual(url.pathExtension, "m4a")
        XCTAssertEqual(store.existingURL(forGcsKey: gcsKey), url)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testStoreIsIdempotentAndLastWriteWins() throws {
        let gcsKey = "audioRequest/md5/cardId/resId.aac"
        let first = try store.store(Data("one".utf8), gcsKey: gcsKey)
        let second = try store.store(Data("one".utf8), gcsKey: gcsKey)
        XCTAssertEqual(first, second, "re-storing the same bytes is a no-op rewrite of the same file")

        try store.store(Data("two".utf8), gcsKey: gcsKey)
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
    }

    func testFailedWriteLeavesNoPartialFileAndKeepsPreviousBytes() throws {
        let gcsKey = "audioRequest/md5/cardId/resId.aac"
        let good = try store.store(Data("complete".utf8), gcsKey: gcsKey)

        // A store whose directory path is occupied by a plain file cannot write.
        let blockedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-store-blocked-\(UUID().uuidString)")
        try Data("i am a file".utf8).write(to: blockedDirectory)
        defer { try? FileManager.default.removeItem(at: blockedDirectory) }
        let blocked = AudioStore(directory: blockedDirectory)

        XCTAssertThrowsError(try blocked.store(Data("partial".utf8), gcsKey: gcsKey))
        XCTAssertNil(blocked.existingURL(forGcsKey: gcsKey), "a failed write leaves nothing behind")
        XCTAssertEqual(try Data(contentsOf: good), Data("complete".utf8), "the earlier complete file is untouched")
    }

    func testKeysWithDifferentNamesNeverCollide() throws {
        try store.store(Data("a".utf8), gcsKey: "audioRequest/one")
        try store.store(Data("b".utf8), gcsKey: "audioRequest/two")
        XCTAssertEqual(try String(decoding: Data(contentsOf: store.existingURL(forGcsKey: "audioRequest/one")!), as: UTF8.self), "a")
        XCTAssertEqual(try String(decoding: Data(contentsOf: store.existingURL(forGcsKey: "audioRequest/two")!), as: UTF8.self), "b")
    }

    func testRemoveAllDeletesEveryDownload() throws {
        try store.store(Data("a".utf8), gcsKey: "k1")
        try store.store(Data("b".utf8), gcsKey: "k2")
        store.removeAll()
        XCTAssertNil(store.existingURL(forGcsKey: "k1"))
        XCTAssertNil(store.existingURL(forGcsKey: "k2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
