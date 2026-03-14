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
    await waitUntil({ bundle.controller._testingQueueItemCount() == 2 })

    XCTAssertTrue(bundle.controller._testingIsQueueSidebarVisible())
    XCTAssertEqual(bundle.controller._testingQueueItemCount(), 2)
    XCTAssertEqual(bundle.controller._testingQueueSelectedRow(), 0)
    XCTAssertEqual(bundle.controller._testingQueueSelectedPrompt(), "first prompt")
    XCTAssertEqual(bundle.controller._testingQueueEditorText(), "first prompt")
  }

  func testQueueAttachmentDefersLoadUntilQueuePanelOpens() async throws {
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: """
      {"id":"one","prompt":"first prompt","added_us":1}
      """
    )

    XCTAssertEqual(bundle.controller._testingQueueItemCount(), 0)
    XCTAssertTrue(bundle.controller._testingQueueStatusText().contains("Open Queue to load"))

    bundle.controller._testingOpenQueuePanel()
    await waitUntil({ bundle.controller._testingQueueItemCount() == 1 })

    XCTAssertEqual(bundle.controller._testingQueueSelectedPrompt(), "first prompt")
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
    await waitUntil({ bundle.controller._testingQueueItemCount() == 2 })
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
    await waitUntil({ bundle.controller._testingQueueItemCount() == 1 })

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
    await waitUntil({ bundle.controller._testingQueueItemCount() == 1 })
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
    await waitUntil({ bundle.controller._testingQueueItemCount() == 1 })
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

  func testDisabledExternalQueueIntegrationSuppressesSidebarAndLoad() async throws {
    var config = TurboDraftConfig()
    config.externalSessionQueues = .init(enabled: false, autoRevealOnAttach: false)
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: """
      {"id":"one","prompt":"first prompt","added_us":1}
      """,
      config: config
    )

    bundle.controller._testingOpenQueuePanel()

    XCTAssertFalse(bundle.controller._testingIsQueueSidebarVisible())
    XCTAssertEqual(bundle.controller._testingQueueItemCount(), 0)
    XCTAssertTrue(bundle.controller._testingQueueStatusText().contains("disabled in settings"))
  }

  func testAutoRevealOnAttachShowsQueueSidebar() async throws {
    var config = TurboDraftConfig()
    config.externalSessionQueues = .init(enabled: true, autoRevealOnAttach: true)
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: """
      {"id":"one","prompt":"first prompt","added_us":1}
      """,
      config: config
    )

    XCTAssertTrue(bundle.controller._testingIsQueueSidebarVisible())
    XCTAssertEqual(bundle.controller._testingQueueSelectedPrompt(), "first prompt")
  }

  func testLiveQueueToggleDisablesAttachedQueue() async throws {
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: """
      {"id":"one","prompt":"first prompt","added_us":1}
      """
    )

    bundle.controller._testingOpenQueuePanel()
    await waitUntil({ bundle.controller._testingQueueItemCount() == 1 })

    bundle.controller._testingSetExternalSessionQueues(.init(enabled: false, autoRevealOnAttach: false))

    XCTAssertFalse(bundle.controller._testingIsQueueSidebarVisible())
    XCTAssertEqual(bundle.controller._testingQueueItemCount(), 0)
    XCTAssertTrue(bundle.controller._testingQueueStatusText().contains("disabled in settings"))
    XCTAssertEqual(bundle.controller._testingExternalSessionQueuesConfig().enabled, false)
  }

  func testEnablingAutoRevealAfterAttachmentShowsQueueSidebar() async throws {
    var config = TurboDraftConfig()
    config.externalSessionQueues = .init(enabled: true, autoRevealOnAttach: false)
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: """
      {"id":"one","prompt":"first prompt","added_us":1}
      """,
      config: config
    )

    XCTAssertFalse(bundle.controller._testingIsQueueSidebarVisible())
    bundle.controller._testingSetExternalSessionQueues(.init(enabled: true, autoRevealOnAttach: true))
    await waitUntil({ bundle.controller._testingQueueSelectedPrompt() == "first prompt" })

    XCTAssertTrue(bundle.controller._testingIsQueueSidebarVisible())
    XCTAssertEqual(bundle.controller._testingQueueSelectedPrompt(), "first prompt")
  }

  func testQueueSettingAppliedBeforeLaterAttachment() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("turbodraft-queue-sidebar-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tempURLs.append(dir)

    let fileURL = dir.appendingPathComponent("draft.md")
    let queueURL = dir.appendingPathComponent("session.queue")
    try "draft".write(to: fileURL, atomically: true, encoding: .utf8)
    try """
    {"id":"one","prompt":"first prompt","added_us":1}
    """.write(to: queueURL, atomically: true, encoding: .utf8)

    let session = EditorSession()
    let info = try await session.open(fileURL: fileURL, cwd: nil)
    let controller = EditorViewController(session: session, config: TurboDraftConfig())
    controller.loadViewIfNeeded()
    controller.applySessionInfo(info, moveCursorLine: nil, column: nil)
    controller.setExternalSessionQueues(.init(enabled: false, autoRevealOnAttach: false))
    controller.setExternalQueueAttachment(
      ExternalQueueAttachment(
        source: "claude-pager",
        queuePath: queueURL.path,
        queueKey: "session",
        queueFormatVersion: 1
      )
    )

    controllers.append(controller)

    XCTAssertFalse(controller._testingIsQueueSidebarVisible())
    XCTAssertEqual(controller._testingQueueItemCount(), 0)
    XCTAssertTrue(controller._testingQueueStatusText().contains("disabled in settings"))
  }

  func testEscInQueueEditorClosesSidebar() async throws {
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: "",
      config: TurboDraftConfig()
    )

    bundle.controller._testingOpenQueuePanel()
    await waitUntil({ bundle.controller._testingIsQueueSidebarVisible() })
    bundle.controller._testingQueueNewItem()
    bundle.controller._testingQueueFocusEditor()

    XCTAssertTrue(bundle.controller._testingQueueEditorDoCommand(#selector(NSResponder.cancelOperation(_:))))
    XCTAssertFalse(bundle.controller._testingIsQueueSidebarVisible())
  }

  func testQueueNewButtonClickAddsItem() async throws {
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: "",
      config: TurboDraftConfig()
    )

    bundle.controller._testingOpenQueuePanel()
    await waitUntil({ bundle.controller._testingIsQueueSidebarVisible() })
    XCTAssertEqual(bundle.controller._testingQueueItemCount(), 0)

    bundle.controller._testingClickQueueNewButton()

    XCTAssertEqual(bundle.controller._testingQueueItemCount(), 1)
    XCTAssertTrue(bundle.controller._testingQueueStatusText().contains("Added empty queued prompt"))
  }

  func testQueueNewItemSeedsFromEditorSelection() async throws {
    let initialText = "Alpha section\nBeta selected text\nGamma section"
    let bundle = try await makeControllerBundle(
      initialText: initialText,
      queueText: "",
      config: TurboDraftConfig()
    )
    let ns = initialText as NSString
    let range = ns.range(of: "Beta selected text")
    XCTAssertNotEqual(range.location, NSNotFound)

    bundle.controller._testingSetSelection(range)
    bundle.controller._testingOpenQueuePanel()
    await waitUntil({ bundle.controller._testingQueueItemCount() == 0 })
    bundle.controller._testingQueueNewItem()

    XCTAssertEqual(bundle.controller._testingQueueItemCount(), 1)
    XCTAssertEqual(bundle.controller._testingQueueSelectedPrompt(), "Beta selected text")
    XCTAssertEqual(bundle.controller._testingQueueEditorText(), "Beta selected text")
    XCTAssertTrue(bundle.controller._testingQueueStatusText().contains("current selection"))
  }

  func testQueueAttachmentKeepsChatEntryVisibleAndUsesToggleTitles() async throws {
    var config = TurboDraftConfig()
    config.agent.enabled = true
    config.agent.chatPanelEnabled = true
    let bundle = try await makeControllerBundle(
      initialText: "draft",
      queueText: """
      {"id":"one","prompt":"first prompt","added_us":1}
      """,
      config: config
    )

    XCTAssertFalse(bundle.controller._testingIsChatButtonHidden())
    XCTAssertFalse(bundle.controller._testingIsQueueButtonHidden())
    XCTAssertEqual(bundle.controller._testingChatButtonTitle(), "Chat Refine")
    XCTAssertEqual(bundle.controller._testingQueueButtonTitle(), "Queue")

    bundle.controller._testingOpenDraftingChat()
    XCTAssertEqual(bundle.controller._testingChatButtonTitle(), "Hide Chat")
    XCTAssertEqual(bundle.controller._testingQueueButtonTitle(), "Queue")

    bundle.controller._testingOpenQueuePanel()
    await waitUntil({ bundle.controller._testingQueueItemCount() == 1 })
    XCTAssertFalse(bundle.controller._testingIsChatButtonHidden())
    XCTAssertEqual(bundle.controller._testingChatButtonTitle(), "Chat Refine")
    XCTAssertEqual(bundle.controller._testingQueueButtonTitle(), "Hide Queue")
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
    queueText: String,
    config: TurboDraftConfig = TurboDraftConfig(),
    attachQueueOnLoad: Bool = true
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
    let controller = EditorViewController(session: session, config: config)
    controller.loadViewIfNeeded()
    controller.applySessionInfo(info, moveCursorLine: nil, column: nil)
    if attachQueueOnLoad {
      controller.setExternalQueueAttachment(
        ExternalQueueAttachment(
          source: "claude-pager",
          queuePath: queueURL.path,
          queueKey: "session",
          queueFormatVersion: 1
        )
      )
    }
    let initialExpectedCount = (attachQueueOnLoad && config.externalSessionQueues.enabled && config.externalSessionQueues.autoRevealOnAttach) ? queueText
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .count : 0
    await waitUntil(
      { controller._testingQueueItemCount() == initialExpectedCount },
      timeoutMs: 1500
    )

    controllers.append(controller)
    return (controller, queueURL)
  }
}
