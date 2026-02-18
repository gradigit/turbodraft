import Foundation
import TurboDraftCore
import XCTest

final class WatcherSyncTests: XCTestCase {
  func testFileWatcherAppliesExternalDiskChange() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let fileURL = dir.appendingPathComponent("prompt.md")
    try Data("one".utf8).write(to: fileURL, options: [.atomic])

    let session = EditorSession()
    _ = try await session.open(fileURL: fileURL)

    let watcher = try DirectoryWatcher(fileURL: fileURL)
    let exp = expectation(description: "applied")

    watcher.start {
      Task {
        _ = try? await session.applyExternalDiskChange()
        let info = await session.currentInfo()
        if info?.content == "two" {
          exp.fulfill()
        }
      }
    }

    try Data("two".utf8).write(to: fileURL, options: [.atomic])
    await fulfillment(of: [exp], timeout: 2.0)
    watcher.stop()
  }
}
