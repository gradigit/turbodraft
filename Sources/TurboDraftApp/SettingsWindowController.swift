import AppKit
import TurboDraftConfig

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
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
      contentRect: NSRect(x: 240, y: 240, width: 560, height: 640),
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
}
