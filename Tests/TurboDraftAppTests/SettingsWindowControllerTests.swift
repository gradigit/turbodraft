import AppKit
import TurboDraftConfig
import XCTest
@testable import TurboDraftApp

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
  func testWindowCloseInvokesOnCloseHandler() {
    let controller = SettingsWindowController(
      config: TurboDraftConfig(),
      colorThemes: EditorColorTheme.builtInThemes,
      modelPresets: ["gpt-5.3-codex-spark"],
      fontPresets: [("System Mono", "system")]
    ) { _ in
      TurboDraftConfig()
    }

    var didClose = false
    controller.onClose = {
      didClose = true
    }

    XCTAssertTrue(controller.window?.delegate === controller)
    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
    XCTAssertTrue(didClose)
  }

  func testWindowHasVisibleContentArea() {
    let controller = SettingsWindowController(
      config: TurboDraftConfig(),
      colorThemes: EditorColorTheme.builtInThemes,
      modelPresets: ["gpt-5.3-codex-spark"],
      fontPresets: [("System Mono", "system")]
    ) { _ in
      TurboDraftConfig()
    }

    guard let window = controller.window else {
      XCTFail("Expected settings window")
      return
    }

    window.layoutIfNeeded()
    XCTAssertGreaterThan(window.contentLayoutRect.height, 400)
    let settingsVC = window.contentViewController as? SettingsViewController
    XCTAssertGreaterThan(settingsVC?._testingDocumentHeight() ?? 0, 300)
  }

  func testShowWindowNormalizesTinySavedFrame() {
    let controller = SettingsWindowController(
      config: TurboDraftConfig(),
      colorThemes: EditorColorTheme.builtInThemes,
      modelPresets: ["gpt-5.3-codex-spark"],
      fontPresets: [("System Mono", "system")]
    ) { _ in
      TurboDraftConfig()
    }

    guard let window = controller.window else {
      XCTFail("Expected settings window")
      return
    }

    window.setFrame(NSRect(x: 40, y: 40, width: 180, height: 44), display: false)
    controller.showWindow(nil)

    let contentRect = window.contentRect(forFrameRect: window.frame)
    XCTAssertGreaterThanOrEqual(contentRect.width, 520)
    XCTAssertGreaterThanOrEqual(contentRect.height, 520)
  }
}
