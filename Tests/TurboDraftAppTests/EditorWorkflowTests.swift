import AppKit
import TurboDraftAgent
import TurboDraftConfig
import TurboDraftCore
import XCTest
@testable import TurboDraftApp

@MainActor
final class EditorWorkflowTests: XCTestCase {
  private struct StaticDraftAdapter: AgentAdapting {
    let value: String
    func draft(prompt: String, instruction: String, images: [URL], cwd: String?) async throws -> String {
      _ = prompt
      _ = instruction
      _ = images
      _ = cwd
      return value
    }
  }

  private final class MockSidebarChatAdapter: AgentAdapting, AgentSidebarChatAdapting, @unchecked Sendable {
    var lastMessage: String = ""
    var lastDraft: String = ""
    var lastImages: [URL] = []
    let reply: String

    init(reply: String) {
      self.reply = reply
    }

    func draft(prompt: String, instruction: String, images: [URL], cwd: String?) async throws -> String {
      prompt + instruction + images.description + (cwd ?? "")
    }

    func chat(message: String, draft: String, images: [URL], cwd: String?) async throws -> String {
      lastMessage = message
      lastDraft = draft
      lastImages = images
      _ = cwd
      return reply
    }
  }

  private final class MockStreamingSidebarChatAdapter: AgentAdapting, AgentSidebarStreamingChatAdapting, @unchecked Sendable {
    let finalReply: String
    let firstDelta: String
    let secondDelta: String

    init(finalReply: String, firstDelta: String, secondDelta: String) {
      self.finalReply = finalReply
      self.firstDelta = firstDelta
      self.secondDelta = secondDelta
    }

    func draft(prompt: String, instruction: String, images: [URL], cwd: String?) async throws -> String {
      prompt + instruction + images.description + (cwd ?? "")
    }

    func chat(message: String, draft: String, images: [URL], cwd: String?) async throws -> String {
      _ = message
      _ = draft
      _ = images
      _ = cwd
      return finalReply
    }

    func chat(
      message: String,
      draft: String,
      images: [URL],
      cwd: String?,
      onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
      _ = message
      _ = draft
      _ = images
      _ = cwd
      onDelta(firstDelta)
      try? await Task.sleep(nanoseconds: 60_000_000)
      onDelta(secondDelta)
      try? await Task.sleep(nanoseconds: 60_000_000)
      return finalReply
    }
  }

  private var tempURLs: [URL] = []
  private var windows: [NSWindow] = []
  private var controllers: [EditorViewController] = []

  override func tearDown() {
    for controller in controllers {
      controller.prepareForIdlePool()
    }
    controllers.removeAll()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    for w in windows { w.close() }
    windows.removeAll()
    let fm = FileManager.default
    for url in tempURLs {
      try? fm.removeItem(at: url)
    }
    tempURLs.removeAll()
    super.tearDown()
  }

  private func makeController(initialText: String = "") async throws -> EditorViewController {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turbodraft-app-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(UUID().uuidString).md")
    try initialText.write(to: url, atomically: true, encoding: .utf8)
    tempURLs.append(url)

    let session = EditorSession()
    _ = try await session.open(fileURL: url, cwd: nil)
    let vc = EditorViewController(session: session, config: TurboDraftConfig())
    vc.loadViewIfNeeded()

    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 900, height: 640),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentViewController = vc
    window.makeKeyAndOrderFront(nil)
    vc._testingSetDocumentText(initialText, actionName: nil)
    controllers.append(vc)
    windows.append(window)
    return vc
  }

  func testFindReplaceAndImageSmoke() async throws {
    let pump: (Int) -> Void = { ms in
      RunLoop.main.run(until: Date().addingTimeInterval(Double(ms) / 1_000.0))
    }
    func waitUntil(_ condition: @escaping () -> Bool, timeoutMs: Int) async {
      let iterations = max(1, timeoutMs / 10)
      for _ in 0..<iterations {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
    }

    let vc = try await makeController(initialText: "alpha\nbeta\n")
    vc._testingShowFind(replace: false)
    let findOnlyInset = vc._testingScrollTopInset()
    vc._testingShowFind(replace: true)
    let replaceInset = vc._testingScrollTopInset()
    vc._testingHideFind()
    let hiddenInset = vc._testingScrollTopInset()

    XCTAssertGreaterThan(findOnlyInset, 0)
    XCTAssertGreaterThan(replaceInset, findOnlyInset)
    XCTAssertEqual(hiddenInset, 0, accuracy: 0.5)

    vc._testingSetDocumentText("asdasd asd asd")
    vc._testingShowFind(replace: false)
    vc._testingSetFindQuery("asd")
    vc._testingFindNext()
    let first = vc._testingActiveFindRange()
    XCTAssertNotNil(first)
    XCTAssertEqual(vc._testingAllFindRangeCount(), 4)

    vc._testingFocusFindField()
    vc._testingFindNext()
    let second = vc._testingActiveFindRange()
    XCTAssertNotNil(second)
    XCTAssertNotEqual(first?.location, second?.location)

    let bg = vc._testingActiveHighlightBackgroundColor()
    let fg = vc._testingActiveHighlightForegroundColor()
    XCTAssertNotNil(bg)
    XCTAssertNotNil(fg)

    vc._testingSetDocumentText("alpha beta alpha ALPHA")
    vc._testingShowFind(replace: true)
    vc._testingSetFindQuery("alpha")
    vc._testingSetReplaceText("omega")
    vc._testingReplaceAll()

    XCTAssertEqual(vc._testingDocumentText(), "omega beta omega omega")
    XCTAssertEqual(vc._testingFindStatusText(), "3 replaced")

    vc._testingSetDocumentText("draft", actionName: nil)
    _ = await vc._testingApplyImprovedDraft("improved1")
    pump(12)
    vc._testingTypeText(" + edit1")
    pump(12)
    _ = await vc._testingApplyImprovedDraft("improved2")
    pump(12)
    vc._testingTypeText(" + edit2")
    pump(12)

    vc._testingUndo()
    XCTAssertEqual(vc._testingDocumentText(), "improved2")
    vc._testingUndo()
    XCTAssertEqual(vc._testingDocumentText(), "improved1 + edit1")
    vc._testingUndo()
    XCTAssertEqual(vc._testingDocumentText(), "improved1")
    vc._testingUndo()
    XCTAssertEqual(vc._testingDocumentText(), "draft")

    vc._testingRedo()
    XCTAssertEqual(vc._testingDocumentText(), "improved1")
    vc._testingRedo()
    XCTAssertEqual(vc._testingDocumentText(), "improved1 + edit1")
    vc._testingRedo()
    XCTAssertEqual(vc._testingDocumentText(), "improved2")
    vc._testingRedo()
    XCTAssertEqual(vc._testingDocumentText(), "improved2 + edit2")

    await vc._testingRestoreFromBanner()
    XCTAssertEqual(vc._testingDocumentText(), "improved1 + edit1")

    // Markdown typing behavior + undo/redo
    func assertUndoRedo(
      _ before: String,
      _ after: String,
      cursor: Int,
      operation: () -> Bool,
      file: StaticString = #filePath,
      line: UInt = #line
    ) {
      vc._testingSetDocumentText(before, actionName: nil)
      vc._testingResetUndoHistory()
      vc._testingSetSelection(NSRange(location: cursor, length: 0))
      XCTAssertTrue(operation(), file: file, line: line)
      XCTAssertEqual(vc._testingDocumentText(), after, file: file, line: line)
      vc._testingUndo()
      XCTAssertEqual(vc._testingDocumentText(), before, file: file, line: line)
      vc._testingRedo()
      XCTAssertEqual(vc._testingDocumentText(), after, file: file, line: line)
    }

    assertUndoRedo("  - item", "  - item\n  - ", cursor: 8) {
      vc._testingInsertNewline()
    }
    assertUndoRedo("  - item", "  - \n  - item", cursor: 0) {
      vc._testingInsertNewline()
    }
    assertUndoRedo("- item", "- it\n- em", cursor: 4) {
      vc._testingInsertNewline()
    }
    assertUndoRedo("- item", "- item\n", cursor: 6) {
      vc._testingInsertLineBreak()
    }
    assertUndoRedo("- item", "item", cursor: 2) {
      vc._testingDeleteBackward()
    }
    assertUndoRedo("  - item", "- item", cursor: 4) {
      vc._testingDeleteBackward()
    }

    vc._testingSetDocumentText("- one\n- two", actionName: nil)
    vc._testingResetUndoHistory()
    vc._testingSetSelection(NSRange(location: 0, length: ("- one\n- two" as NSString).length))
    XCTAssertTrue(vc._testingInsertTab())
    XCTAssertEqual(vc._testingDocumentText(), "  - one\n  - two")
    vc._testingUndo()
    XCTAssertEqual(vc._testingDocumentText(), "- one\n- two")
    vc._testingRedo()
    XCTAssertEqual(vc._testingDocumentText(), "  - one\n  - two")
    vc._testingSetSelection(NSRange(location: 0, length: ("  - one\n  - two" as NSString).length))
    XCTAssertTrue(vc._testingInsertBacktab())
    XCTAssertEqual(vc._testingDocumentText(), "- one\n- two")

    vc._testingSetDocumentText("1. one\n4. two", actionName: nil)
    vc._testingResetUndoHistory()
    vc._testingSetSelection(NSRange(location: 6, length: 0))
    XCTAssertTrue(vc._testingInsertNewline())
    XCTAssertEqual(vc._testingDocumentText(), "1. one\n2. \n3. two")

    vc._testingSetDocumentText("- [ ] todo", actionName: nil)
    vc._testingResetUndoHistory()
    vc._testingSetSelection(NSRange(location: 3, length: 0))
    XCTAssertTrue(vc._testingToggleCheckboxWithSpace())
    XCTAssertEqual(vc._testingDocumentText(), "- [x] todo")
    vc._testingUndo()
    XCTAssertEqual(vc._testingDocumentText(), "- [ ] todo")
    vc._testingRedo()
    XCTAssertEqual(vc._testingDocumentText(), "- [x] todo")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turbodraft-images", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let imageURL = dir.appendingPathComponent("\(UUID().uuidString).png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
    tempURLs.append(imageURL)

    vc._testingAttachImage(id: "deadbeef", url: imageURL)
    let resolved = vc._testingResolvePromptAndImages("""
    before [image-deadbeef]
    again [image-deadbeef]
    """)

    XCTAssertTrue(resolved.0.contains("@\(imageURL.path)"))
    XCTAssertEqual(resolved.1.count, 1)
    XCTAssertEqual(resolved.1.first, imageURL)

    vc._testingSetDocumentText("alpha", actionName: nil)
    vc._testingSetSelection(NSRange(location: 5, length: 0))
    vc._testingInsertDraftingAnnotation(type: "note")
    XCTAssertTrue(vc._testingDocumentText().contains("<!-- @td(note):  -->"))

    let withAnnotation = """
    draft text
    <!-- @td(question): confirm required API version -->
    @@ constraint: keep this under 300 words
    more text
    """
    let annoResolved = vc._testingResolvePromptAndImages(withAnnotation)
    XCTAssertTrue(annoResolved.0.contains("## Drafting Annotations"))
    XCTAssertTrue(annoResolved.0.contains("- [question] confirm required API version"))
    XCTAssertTrue(annoResolved.0.contains("- [constraint] keep this under 300 words"))
    XCTAssertTrue(annoResolved.1.isEmpty)

    XCTAssertTrue(vc._testingAppendDraftingChatNote("narrow scope to install flow only"))
    XCTAssertTrue(vc._testingDocumentText().contains("<!-- @td(question): narrow scope to install flow only -->"))

    var cfg = TurboDraftConfig()
    cfg.agent.enabled = true
    cfg.agent.chatPanelEnabled = true
    vc.setAgentConfig(cfg.agent)
    let mockChat = MockSidebarChatAdapter(reply: "Got it — I’ll keep scope tight.")
    vc._testingSetAgentAdapter(mockChat)
    vc._testingOpenDraftingChat()
    XCTAssertTrue(vc._testingIsDraftingSidebarVisible())
    let initialInputHeight = vc._testingDraftingChatInputHeight()
    vc._testingSetDocumentText("chat-base")
    vc._testingSetDraftingChatInput("can you suggest tighter wording?")
    XCTAssertTrue(vc._testingSendDraftingChatMessage())
    await waitUntil({ vc._testingDraftingChatTranscript().contains("assistant: Got it — I’ll keep scope tight.") }, timeoutMs: 1000)
    await waitUntil({ !vc._testingIsDraftingChatRunning() }, timeoutMs: 1000)
    let transcript = vc._testingDraftingChatTranscript()
    XCTAssertTrue(transcript.contains("you: can you suggest tighter wording?"))
    XCTAssertTrue(transcript.contains("assistant: Got it — I’ll keep scope tight."))
    XCTAssertEqual(vc._testingDocumentText(), "chat-base")
    XCTAssertEqual(mockChat.lastDraft, "chat-base")

    vc._testingSetDraftingChatInput("enter key submit")
    XCTAssertTrue(vc._testingSidebarDoCommand(#selector(NSResponder.insertNewline(_:))))
    await waitUntil({ vc._testingDraftingChatTranscript().contains("you: enter key submit") }, timeoutMs: 500)
    await waitUntil({
      let transcript = vc._testingDraftingChatTranscript()
      return transcript.components(separatedBy: "assistant: Got it — I’ll keep scope tight.").count >= 2
    }, timeoutMs: 1000)

    vc._testingSetDraftingChatInput("keep constraints but simplify wording")
    XCTAssertEqual(vc._testingDraftingChatInput(), "keep constraints but simplify wording")
    XCTAssertTrue(vc._testingSubmitDraftingChatNote())
    XCTAssertTrue(vc._testingDocumentText().contains("<!-- @td(note): keep constraints but simplify wording -->"))
    XCTAssertEqual(vc._testingDraftingChatInputHeight(), initialInputHeight, accuracy: 0.5)

    vc._testingSetDraftingAnnotationType("constraint")
    vc._testingSetDraftingChatInput("must keep output under 250 words")
    XCTAssertTrue(vc._testingSubmitDraftingChatNote())
    XCTAssertTrue(vc._testingDocumentText().contains("<!-- @td(constraint): must keep output under 250 words -->"))

    vc._testingSetDraftingChatInput("line1\nline2\nline3\nline4\nline5\nline6")
    XCTAssertGreaterThan(vc._testingDraftingChatInputHeight(), initialInputHeight)

    let fileURL = dir.appendingPathComponent("notes.md")
    try Data("todo".utf8).write(to: fileURL)
    tempURLs.append(fileURL)
    vc._testingQueueDraftingSidebarFileAttachment(url: fileURL)
    XCTAssertEqual(vc._testingDraftingSidebarPendingAttachmentRefs(), ["@\(fileURL.path)"])
    vc._testingSetDraftingChatInput("include this attachment")
    XCTAssertEqual(vc._testingDraftingChatInput(), "include this attachment")
    XCTAssertTrue(vc._testingSubmitDraftingChatNote())
    XCTAssertTrue(vc._testingDocumentText().contains("@\(fileURL.path)"))

    vc._testingQueueDraftingSidebarImageAttachment(id: "feedbabe", url: imageURL)
    XCTAssertEqual(vc._testingDraftingSidebarPendingAttachmentRefs(), ["[image-feedbabe]"])
    vc._testingSetDraftingChatInput("use this image")
    XCTAssertEqual(vc._testingDraftingChatInput(), "use this image")
    XCTAssertTrue(vc._testingSubmitDraftingChatNote())
    let withSidebarImage = vc._testingResolvePromptAndImages(vc._testingDocumentText())
    XCTAssertTrue(withSidebarImage.0.contains("@\(imageURL.path)"))
    XCTAssertTrue(withSidebarImage.1.contains(imageURL))

    vc._testingQueueDraftingSidebarFileAttachment(url: fileURL)
    XCTAssertFalse(vc._testingDraftingSidebarPendingAttachmentRefs().isEmpty)
    vc._testingCloseDraftingSidebar()
    XCTAssertTrue(vc._testingDraftingSidebarPendingAttachmentRefs().isEmpty)
    await waitUntil({ !vc._testingIsDraftingChatRunning() }, timeoutMs: 1000)

    vc._testingOpenDraftingChat()
    vc._testingSetDocumentText("old line 1\nold line 2", actionName: nil)
    let streamingReply = """
    Here is a cleaner rewrite:
    ```markdown
    new line 1
    new line 2
    ```
    """
    let streaming = MockStreamingSidebarChatAdapter(
      finalReply: streamingReply,
      firstDelta: "Here is ",
      secondDelta: "a cleaner rewrite:"
    )
    vc._testingSetAgentAdapter(streaming)
    vc._testingSetDraftingChatInput("stream and suggest")
    XCTAssertTrue(vc._testingSendDraftingChatMessage())
    await waitUntil({ vc._testingDraftingChatTranscript().contains("assistant: Here is ") }, timeoutMs: 400)
    await waitUntil({ vc._testingDraftingChatTranscript().contains("assistant: Here is a cleaner rewrite:") }, timeoutMs: 600)
    await waitUntil({ vc._testingHasDraftingSuggestedDraft() }, timeoutMs: 1000)
    XCTAssertTrue(vc._testingIsDraftingDiffVisible())
    XCTAssertTrue(vc._testingDraftingDiffText().contains("--- current"))
    XCTAssertTrue(vc._testingDraftingContextText().contains("## Resolved Message Sent To drafting_agent"))
    XCTAssertTrue(vc._testingDraftingContextText().contains("## Draft Snapshot Sent"))
    vc._testingApplyDraftingSuggestion()
    XCTAssertEqual(vc._testingDocumentText(), "new line 1\nnew line 2")
    await waitUntil({ !vc._testingIsDraftingChatRunning() }, timeoutMs: 1000)

    var cfgFallback = TurboDraftConfig()
    cfgFallback.agent.enabled = true
    cfgFallback.agent.chatPanelEnabled = true
    cfgFallback.agent.backend = .claude
    cfgFallback.agent.command = "claude"
    cfgFallback.agent.model = "claude-sonnet-4-6"
    vc.setAgentConfig(cfgFallback.agent)
    vc._testingSetDraftingAnnotationType("note")
    vc._testingSetAgentAdapter(StaticDraftAdapter(value: "noop"))
    vc._testingSetDocumentText("fallback-base", actionName: nil)
    vc._testingSetDraftingChatInput("fallback note path")
    XCTAssertTrue(vc._testingSendDraftingChatMessage())
    XCTAssertTrue(vc._testingDocumentText().contains("<!-- @td(note): fallback note path -->"))

    var cfgDisabled = TurboDraftConfig()
    cfgDisabled.agent.enabled = false
    cfgDisabled.agent.chatPanelEnabled = true
    vc.setAgentConfig(cfgDisabled.agent)
    vc._testingSetDraftingAnnotationType("question")
    vc._testingSetDocumentText("disabled-base", actionName: nil)
    vc._testingSetDraftingChatInput("disabled fallback note")
    XCTAssertTrue(vc._testingSidebarDoCommand(#selector(NSResponder.insertNewline(_:))))
    XCTAssertTrue(vc._testingDocumentText().contains("<!-- @td(question): disabled fallback note -->"))
  }
}
