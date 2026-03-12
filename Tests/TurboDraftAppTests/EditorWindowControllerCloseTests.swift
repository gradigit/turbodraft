import AppKit
import Foundation
import TurboDraftConfig
import TurboDraftCore
import XCTest
@testable import TurboDraftApp

@MainActor
final class EditorWindowControllerCloseTests: XCTestCase {
  private var tempURLs: [URL] = []
  private var windows: [NSWindow] = []

  override func tearDown() {
    for window in windows {
      if window.isVisible {
        window.close()
      } else {
        window.orderOut(nil)
        window.contentViewController = nil
      }
    }
    windows.removeAll()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    for url in tempURLs {
      try? FileManager.default.removeItem(at: url)
    }
    tempURLs.removeAll()
    super.tearDown()
  }

  func testWaitResolvesOnlyAfterWindowIsHidden() async throws {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("turbodraft-close-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let fileURL = dir.appendingPathComponent("draft.md")
    try "draft".write(to: fileURL, atomically: true, encoding: .utf8)
    tempURLs.append(dir)

    let session = EditorSession()
    let info = try await session.open(fileURL: fileURL, cwd: nil)
    let wc = EditorWindowController(session: session, config: TurboDraftConfig())
    if let window = wc.window {
      windows.append(window)
    }
    await wc.presentSession(info, line: nil, column: nil)

    async let waitResult: Bool = session.waitUntilClosed(timeoutMs: 1_500)
    let startedAt = Date()
    wc.requestSessionClose()
    let closed = await waitResult
    let elapsedMs = Date().timeIntervalSince(startedAt) * 1_000
    let visibleAtResolution = wc.window?.isVisible ?? true

    XCTAssertTrue(closed)
    XCTAssertFalse(visibleAtResolution)
    XCTAssertLessThan(elapsedMs, 1_000, "session.wait should resolve promptly after close request")
  }

  func testWaitResolvesBeforeSlowCleanupFinishes() async throws {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("turbodraft-close-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let fileURL = dir.appendingPathComponent("draft.md")
    try "draft".write(to: fileURL, atomically: true, encoding: .utf8)
    tempURLs.append(dir)

    let session = EditorSession()
    let info = try await session.open(fileURL: fileURL, cwd: nil)
    let wc = EditorWindowController(session: session, config: TurboDraftConfig())
    if let window = wc.window {
      windows.append(window)
    }
    await wc.presentSession(info, line: nil, column: nil)

    let cleanupFinished = expectation(description: "cleanup finished")
    wc.onClosed = {
      Thread.sleep(forTimeInterval: 1.2)
      cleanupFinished.fulfill()
    }

    async let waitResult: Bool = session.waitUntilClosed(timeoutMs: 1_500)
    let startedAt = Date()
    wc.requestSessionClose()
    let closed = await waitResult
    let elapsedMs = Date().timeIntervalSince(startedAt) * 1_000

    XCTAssertTrue(closed)
    XCTAssertLessThan(elapsedMs, 400, "session.wait should not be blocked on slow cleanup")
    await fulfillment(of: [cleanupFinished], timeout: 2.5)
  }
}
