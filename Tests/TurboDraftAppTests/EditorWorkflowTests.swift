import AppKit
import TurboDraftConfig
import TurboDraftCore
import XCTest
@testable import TurboDraftApp

@MainActor
final class EditorWorkflowTests: XCTestCase {
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
  }
}
