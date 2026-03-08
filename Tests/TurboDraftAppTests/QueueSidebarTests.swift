import AppKit
import TurboDraftConfig
import TurboDraftCore
import XCTest
@testable import TurboDraftApp

@MainActor
final class AQueueSidebarTests: XCTestCase {
  private var tempURLs: [URL] = []
  private var controllers: [EditorViewController] = []

  override func tearDown() {
    for controller in controllers {
      controller.prepareForIdlePool()
    }
    controllers.removeAll()
    RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    for url in tempURLs {
      try? FileManager.default.removeItem(at: url)
    }
    tempURLs.removeAll()
    super.tearDown()
  }

  func testQueueAttachmentOpensSidebarAndLoadsAttachedItems() async throws {
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: """
      {"id":"one","prompt":"first prompt","added_us":1}
      {"id":"two","prompt":"second prompt","added_us":2}
      """
    )

    XCTAssertEqual(bundle.controller._testingExternalQueueAttachment()?.source, "claude-pager")
    XCTAssertFalse(bundle.controller._testingIsQueueSidebarVisible())

    bundle.controller._testingOpenQueuePanel()

    XCTAssertTrue(bundle.controller._testingIsQueueSidebarVisible())
    XCTAssertEqual(bundle.controller._testingQueueItemCount(), 2)
    XCTAssertEqual(bundle.controller._testingQueueSelectedRow(), 0)
    XCTAssertEqual(bundle.controller._testingQueueSelectedPrompt(), "first prompt")
    XCTAssertEqual(bundle.controller._testingQueueEditorText(), "first prompt")
  }

  func testQueueSelectionEditAndSavePersistsToDisk() async throws {
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: """
      {"id":"one","prompt":"first prompt","added_us":1}
      {"id":"two","prompt":"second prompt","added_us":2,"priority":"high"}
      """
    )

    bundle.controller._testingOpenQueuePanel()
    bundle.controller._testingQueueSelectRow(1)

    XCTAssertEqual(bundle.controller._testingQueueSelectedRow(), 1)
    XCTAssertEqual(bundle.controller._testingQueueSelectedPrompt(), "second prompt")
    XCTAssertEqual(bundle.controller._testingQueueEditorText(), "second prompt")

    bundle.controller._testingSetQueueEditorText("updated second prompt")
    bundle.controller._testingSaveQueue()
    await waitUntil({ bundle.controller._testingQueueStatusText().contains("Saved 2 queued prompts") })

    let queueText = try String(contentsOf: bundle.queueURL, encoding: .utf8)
    XCTAssertTrue(queueText.contains("\"prompt\":\"updated second prompt\""))
    XCTAssertTrue(queueText.contains("\"priority\":\"high\""))
    XCTAssertTrue(bundle.controller._testingQueueStatusText().contains("Saved 2 queued prompts"))
    XCTAssertEqual(bundle.controller._testingQueueSelectedRow(), 1)
    XCTAssertEqual(bundle.controller._testingQueueSelectedPrompt(), "updated second prompt")
  }

  func testQueueWatcherReloadsQueueWhenLocalStateIsClean() async throws {
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: """
      {"id":"one","prompt":"watch me","added_us":1}
      """
    )

    bundle.controller._testingOpenQueuePanel()

    try """
    {"id":"one","prompt":"updated by watcher","added_us":1}
    """.write(to: bundle.queueURL, atomically: true, encoding: .utf8)

    await waitUntil({ bundle.controller._testingQueueSelectedPrompt() == "updated by watcher" })

    XCTAssertEqual(bundle.controller._testingQueueItemCount(), 1)
    XCTAssertEqual(bundle.controller._testingQueueSelectedPrompt(), "updated by watcher")
    XCTAssertEqual(bundle.controller._testingQueueEditorText(), "updated by watcher")
    XCTAssertTrue(bundle.controller._testingQueueStatusText().contains("Loaded 1 queued prompt"))
  }

  func testQueueDeleteLastItemAndSaveRemovesSharedQueueFile() async throws {
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: """
      {"id":"one","prompt":"only prompt","added_us":1}
      """
    )

    bundle.controller._testingOpenQueuePanel()
    XCTAssertEqual(bundle.controller._testingQueueItemCount(), 1)

    bundle.controller._testingDeleteQueueSelection()

    XCTAssertEqual(bundle.controller._testingQueueItemCount(), 0)
    XCTAssertTrue(bundle.controller._testingQueueStatusText().contains("Queue cleared locally"))

    bundle.controller._testingSaveQueue()
    await waitUntil({ bundle.controller._testingQueueStatusText().contains("file removed") })

    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.queueURL.path))
    XCTAssertTrue(bundle.controller._testingQueueStatusText().contains("file removed"))
  }

  func testQueueConflictSafeSaveDoesNotOverwriteExternalDiskChanges() async throws {
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: """
      {"id":"one","prompt":"first prompt","added_us":1}
      """
    )

    bundle.controller._testingOpenQueuePanel()
    bundle.controller._testingSetQueueEditorText("local draft change")

    try """
    {"id":"one","prompt":"external disk change","added_us":1}
    """.write(to: bundle.queueURL, atomically: true, encoding: .utf8)

    bundle.controller._testingSaveQueue()
    await waitUntil({ bundle.controller._testingQueueStatusText().contains("Reload before saving") })

    let queueText = try String(contentsOf: bundle.queueURL, encoding: .utf8)
    XCTAssertTrue(queueText.contains("external disk change"))
    XCTAssertFalse(queueText.contains("local draft change"))
    XCTAssertEqual(bundle.controller._testingQueueEditorText(), "local draft change")
    XCTAssertTrue(bundle.controller._testingQueueStatusText().contains("Reload before saving"))
  }

  func testUnsupportedQueueFormatDisablesQueueSidebar() async throws {
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: """
      {"id":"one","prompt":"first prompt","added_us":1}
      """
    )

    bundle.controller.setExternalQueueAttachment(
      ExternalQueueAttachment(
        source: "claude-pager",
        queuePath: bundle.queueURL.path,
        queueKey: "session",
        queueFormatVersion: 99
      )
    )

    bundle.controller._testingOpenQueuePanel()

    XCTAssertFalse(bundle.controller._testingIsQueueSidebarVisible())
    XCTAssertEqual(bundle.controller._testingQueueItemCount(), 0)
    XCTAssertTrue(bundle.controller._testingQueueStatusText().contains("Unsupported shared queue format"))
  }

  private func waitUntil(
    _ condition: @escaping () -> Bool,
    timeoutMs: Int = 1500,
    pollMs: UInt64 = 20
  ) async {
    let iterations = max(1, timeoutMs / Int(pollMs))
    for _ in 0..<iterations {
      if condition() { return }
      try? await Task.sleep(nanoseconds: pollMs * 1_000_000)
    }
  }

  private func makeControllerBundle(
    initialText: String,
    queueText: String
  ) async throws -> (controller: EditorViewController, queueURL: URL) {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("turbodraft-queue-sidebar-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tempURLs.append(dir)

    let fileURL = dir.appendingPathComponent("draft.md")
    let queueURL = dir.appendingPathComponent("session.queue")
    try initialText.write(to: fileURL, atomically: true, encoding: .utf8)
    try queueText.write(to: queueURL, atomically: true, encoding: .utf8)

    let session = EditorSession()
    let info = try await session.open(fileURL: fileURL, cwd: nil)
    let controller = EditorViewController(session: session, config: TurboDraftConfig())
    controller.loadViewIfNeeded()
    controller.applySessionInfo(info, moveCursorLine: nil, column: nil)
    controller.setExternalQueueAttachment(
      ExternalQueueAttachment(
        source: "claude-pager",
        queuePath: queueURL.path,
        queueKey: "session",
        queueFormatVersion: 1
      )
    )
    let expectedCount = queueText
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .count
    await waitUntil(
      { controller._testingQueueItemCount() == expectedCount },
      timeoutMs: 1500
    )

    controllers.append(controller)
    return (controller, queueURL)
  }
}
