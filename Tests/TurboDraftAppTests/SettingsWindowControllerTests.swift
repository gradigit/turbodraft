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
}
