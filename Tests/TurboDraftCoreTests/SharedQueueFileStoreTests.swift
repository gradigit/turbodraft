import Foundation
import TurboDraftCore
import TurboDraftProtocol
import XCTest

final class SharedQueueFileStoreTests: XCTestCase {
  private var tempURLs: [URL] = []

  override func tearDown() {
    for url in tempURLs {
      try? FileManager.default.removeItem(at: url)
    }
    tempURLs.removeAll()
    super.tearDown()
  }

  func testLoadSupportsJSONObjectsAndPlainLegacyLines() throws {
    let url = temporaryFileURL()
    let text = """
    {\"id\":\"abc\",\"prompt\":\"hello\\nworld\",\"added_us\":123,\"source\":\"pager\"}
    legacy line
    """
    try text.write(to: url, atomically: true, encoding: .utf8)

    let snapshot = try SharedQueueFileStore.load(from: url)
    XCTAssertTrue(snapshot.fileExists)
    XCTAssertEqual(snapshot.items.count, 2)
    XCTAssertEqual(snapshot.items[0].persistedID, "abc")
    XCTAssertEqual(snapshot.items[0].prompt, "hello\nworld")
    XCTAssertEqual(snapshot.items[0].jsonFields?["source"], .string("pager"))
    XCTAssertEqual(snapshot.items[1].encoding, .plainText)
    XCTAssertEqual(snapshot.items[1].prompt, "legacy line")
  }

  func testWritePreservesUnknownJSONFieldsOnRoundTrip() throws {
    let url = temporaryFileURL()
    let items = [
      SharedQueueItem(
        localID: "id:abc",
        persistedID: "abc",
        prompt: "updated",
        addedUs: 55,
        encoding: .jsonObject,
        jsonFields: [
          "id": .string("abc"),
          "prompt": .string("old"),
          "added_us": .int(55),
          "source": .string("pager"),
          "nested": .object(["x": .int(1)]),
        ]
      ),
    ]

    _ = try SharedQueueFileStore.write(items, to: url)
    let snapshot = try SharedQueueFileStore.load(from: url)
    XCTAssertEqual(snapshot.items.count, 1)
    XCTAssertEqual(snapshot.items[0].prompt, "updated")
    XCTAssertEqual(snapshot.items[0].jsonFields?["source"], .string("pager"))
    XCTAssertEqual(snapshot.items[0].jsonFields?["nested"], .object(["x": .int(1)]))
  }

  func testWriteDeletesFileWhenItemsEmpty() throws {
    let url = temporaryFileURL()
    try "hello\n".write(to: url, atomically: true, encoding: .utf8)
    let snapshot = try SharedQueueFileStore.write([], to: url)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertFalse(snapshot.fileExists)
    XCTAssertNil(snapshot.fingerprint)
  }

  func testPlainSingleLineRoundTripsAsPlainText() throws {
    let url = temporaryFileURL()
    let items = [
      SharedQueueItem(
        localID: "plain:test",
        persistedID: nil,
        prompt: "plain prompt",
        addedUs: nil,
        encoding: .plainText,
        jsonFields: nil
      ),
    ]

    _ = try SharedQueueFileStore.write(items, to: url)
    let text = try String(contentsOf: url, encoding: .utf8)
    XCTAssertEqual(text, "plain prompt\n")
  }

  func testWriteRejectsFingerprintConflict() throws {
    let url = temporaryFileURL()
    try """
    {"id":"abc","prompt":"disk version","added_us":1}
    """.write(to: url, atomically: true, encoding: .utf8)

    let snapshot = try SharedQueueFileStore.load(from: url)
    try """
    {"id":"abc","prompt":"newer disk version","added_us":2}
    """.write(to: url, atomically: true, encoding: .utf8)

    let items = [
      SharedQueueItem(
        localID: "id:abc",
        persistedID: "abc",
        prompt: "local stale edit",
        addedUs: 1,
        encoding: .jsonObject,
        jsonFields: [
          "id": .string("abc"),
          "prompt": .string("disk version"),
          "added_us": .int(1),
        ]
      ),
    ]

    XCTAssertThrowsError(
      try SharedQueueFileStore.write(
        items,
        to: url,
        expectedFingerprint: snapshot.fingerprint,
        enforceFingerprint: true
      )
    ) { error in
      let currentFingerprint = (try? SharedQueueFileStore.load(from: url))?.fingerprint
      XCTAssertEqual(
        error as? SharedQueueFileStoreError,
        SharedQueueFileStoreError.conflict(
          expected: snapshot.fingerprint,
          actual: currentFingerprint
        )
      )
    }
  }

  private func temporaryFileURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("turbodraft-shared-queue-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tempURLs.append(dir)
    return dir.appendingPathComponent("queue.queue")
  }
}
