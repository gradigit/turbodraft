import Foundation
import TurboDraftCore
import XCTest

final class EditorSessionWaitTests: XCTestCase {
  func testOpeningNewSessionReleasesExistingWaiters() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let first = dir.appendingPathComponent("first.md")
    let second = dir.appendingPathComponent("second.md")
    try "first".data(using: .utf8)?.write(to: first, options: [.atomic])
    try "second".data(using: .utf8)?.write(to: second, options: [.atomic])

    let session = EditorSession()
    _ = try await session.open(fileURL: first)

    async let waiter: Bool = session.waitUntilClosed(timeoutMs: 800)
    try? await Task.sleep(nanoseconds: 30_000_000)

    _ = try await session.open(fileURL: second)

    let completed = await waiter
    XCTAssertTrue(completed)
  }
}

