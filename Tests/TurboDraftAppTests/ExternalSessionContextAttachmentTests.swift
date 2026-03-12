import AppKit
import TurboDraftConfig
import TurboDraftCore
import XCTest
@testable import TurboDraftApp

@MainActor
final class ExternalSessionContextAttachmentTests: XCTestCase {
  private var tempURLs: [URL] = []
  private var controllers: [EditorViewController] = []

  override func tearDown() {
    for controller in controllers {
      controller.prepareForIdlePool()
    }
    controllers.removeAll()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    for url in tempURLs {
      try? FileManager.default.removeItem(at: url)
    }
    tempURLs.removeAll()
    super.tearDown()
  }

  func testEditorViewControllerStoresAndLoadsExternalSessionContextAttachment() async throws {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("turbodraft-session-context-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let fileURL = dir.appendingPathComponent("draft.md")
    try "draft".write(to: fileURL, atomically: true, encoding: .utf8)
    let contextURL = dir.appendingPathComponent("session-context.json")
    try #"{"summary":"Current task: fix the save error","files":["Sources/App.swift"]}"#.write(
      to: contextURL,
      atomically: true,
      encoding: .utf8
    )
    tempURLs.append(dir)

    let session = EditorSession()
    let info = try await session.open(fileURL: fileURL, cwd: nil)
    let vc = EditorViewController(session: session, config: TurboDraftConfig())
    vc.loadViewIfNeeded()
    vc.applySessionInfo(info, moveCursorLine: nil, column: nil)
    let attachment = ExternalSessionContextAttachment(
      source: "claude-pager",
      contextPath: contextURL.path,
      contextFormatVersion: 1
    )
    vc.setExternalSessionContextAttachment(attachment)
    controllers.append(vc)

    let loaded = await waitForSnapshot(on: vc)
    XCTAssertEqual(vc._testingExternalSessionContextAttachment(), attachment)
    XCTAssertNotNil(loaded)
    XCTAssertTrue(loaded?.agentText.contains("Current task: fix the save error") == true)
  }

  func testAttachmentRejectsRelativeContextPath() {
    XCTAssertNil(
      ExternalSessionContextAttachment(
        source: "claude-pager",
        contextPath: "relative/context.json",
        contextFormatVersion: 1
      )
    )
  }

  private func waitForSnapshot(on controller: EditorViewController, timeoutMs: Int = 1000) async -> ExternalSessionContextSnapshot? {
    for _ in 0..<(timeoutMs / 20) {
      if let snapshot = controller._testingExternalSessionContextSnapshot() {
        return snapshot
      }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return controller._testingExternalSessionContextSnapshot()
  }
}
