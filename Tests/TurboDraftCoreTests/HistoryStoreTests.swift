import TurboDraftCore
import XCTest

final class HistoryStoreTests: XCTestCase {
  func testConsecutiveDuplicateContentIsIgnored() {
    var store = HistoryStore(maxCount: 8, maxBytes: 10_000)
    store.append(HistorySnapshot(reason: "first", content: "same"))
    store.append(HistorySnapshot(reason: "second", content: "same"))

    let items = store.all()
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items.first?.reason, "first")
  }

  func testPrunesByCountLimit() {
    var store = HistoryStore(maxCount: 2, maxBytes: 10_000)
    store.append(HistorySnapshot(reason: "one", content: "1"))
    store.append(HistorySnapshot(reason: "two", content: "2"))
    store.append(HistorySnapshot(reason: "three", content: "3"))

    let reasons = store.all().map(\.reason)
    XCTAssertEqual(reasons, ["two", "three"])
  }

  func testPrunesByByteBudgetButKeepsNewestSnapshot() {
    var store = HistoryStore(maxCount: 10, maxBytes: 10)
    store.append(HistorySnapshot(reason: "a", content: "12345"))
    store.append(HistorySnapshot(reason: "b", content: "67890"))
    store.append(HistorySnapshot(reason: "c", content: "abcdefghij"))

    let items = store.all()
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items.first?.reason, "c")
    XCTAssertEqual(items.first?.content, "abcdefghij")
  }
}
