import AppKit
import TurboDraftConfig

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
  private let defaultContentSize = NSSize(width: 560, height: 640)
  private let settingsViewController: SettingsViewController
  var onClose: (() -> Void)?

  init(
    config: TurboDraftConfig,
    colorThemes: [EditorColorTheme],
    modelPresets: [String],
    fontPresets: [(title: String, family: String)],
    applyAction: @escaping (SettingsAction) -> TurboDraftConfig
  ) {
    settingsViewController = SettingsViewController(
      config: config,
      colorThemes: colorThemes,
      modelPresets: modelPresets,
      fontPresets: fontPresets,
      applyAction: applyAction
    )

    let window = NSWindow(
      contentRect: NSRect(x: 240, y: 240, width: defaultContentSize.width, height: defaultContentSize.height),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Settings"
    window.animationBehavior = .none
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 520, height: 520)
    window.contentViewController = settingsViewController
    window.setFrameAutosaveName("TurboDraftSettingsWindowFrame")
    super.init(window: window)
    window.delegate = self
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    normalizeWindowFrameIfNeeded()
  }

  func refresh(
    config: TurboDraftConfig,
    colorThemes: [EditorColorTheme],
    modelPresets: [String],
    fontPresets: [(title: String, family: String)]
  ) {
    settingsViewController.refresh(
      config: config,
      colorThemes: colorThemes,
      modelPresets: modelPresets,
      fontPresets: fontPresets
    )
  }

  func windowWillClose(_ notification: Notification) {
    onClose?()
  }

  private func normalizeWindowFrameIfNeeded() {
    guard let window else { return }
    let minContentSize = window.contentMinSize
    let currentContentRect = window.contentRect(forFrameRect: window.frame)
    guard currentContentRect.width < minContentSize.width || currentContentRect.height < minContentSize.height else {
      return
    }

    let targetContentRect = NSRect(
      x: currentContentRect.origin.x,
      y: currentContentRect.origin.y,
      width: max(defaultContentSize.width, minContentSize.width),
      height: max(defaultContentSize.height, minContentSize.height)
    )
    window.setFrame(window.frameRect(forContentRect: targetContentRect), display: false)
    window.center()
  }
}
