import AppKit
import TurboDraftConfig
import TurboDraftCore
import XCTest
@testable import TurboDraftApp

@MainActor
final class ExternalQueueAttachmentTests: XCTestCase {
  private var tempURLs: [URL] = []
  private var windows: [NSWindow] = []
  private var controllers: [EditorViewController] = []

  override func tearDown() {
    for controller in controllers {
      controller.prepareForIdlePool()
    }
    controllers.removeAll()
    for window in windows {
      window.close()
    }
    windows.removeAll()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    for url in tempURLs {
      try? FileManager.default.removeItem(at: url)
    }
    tempURLs.removeAll()
    super.tearDown()
  }

  func testEditorViewControllerStoresExternalQueueAttachment() async throws {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("turbodraft-queue-attachment-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let fileURL = dir.appendingPathComponent("draft.md")
    try "draft".write(to: fileURL, atomically: true, encoding: .utf8)
    tempURLs.append(dir)

    let session = EditorSession()
    let info = try await session.open(fileURL: fileURL, cwd: nil)
    let vc = EditorViewController(session: session, config: TurboDraftConfig())
    vc.loadViewIfNeeded()
    vc.applySessionInfo(info, moveCursorLine: nil, column: nil)
    let attachment = ExternalQueueAttachment(
      source: "claude-pager",
      queuePath: "/Users/aaaaa/.claude/queues/example.queue",
      queueKey: "example",
      queueFormatVersion: 1
    )
    vc.setExternalQueueAttachment(attachment)
    controllers.append(vc)

    XCTAssertEqual(vc._testingExternalQueueAttachment(), attachment)
  }

  func testAttachmentRejectsRelativeQueuePath() {
    XCTAssertNil(
      ExternalQueueAttachment(
        source: "claude-pager",
        queuePath: "relative/session.queue",
        queueKey: "example",
        queueFormatVersion: 1
      )
    )
  }
}
