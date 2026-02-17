import PromptPadCore
import XCTest

final class DebouncerTests: XCTestCase {
  func testDebouncerCoalesces() async throws {
    let d = AsyncDebouncer()
    let exp = expectation(description: "called once")
    exp.expectedFulfillmentCount = 1

    d.schedule(delayMs: 50) { exp.fulfill() }
    d.schedule(delayMs: 50) { exp.fulfill() }

    await fulfillment(of: [exp], timeout: 1.0)
  }
}

