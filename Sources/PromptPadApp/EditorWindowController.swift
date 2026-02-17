import AppKit
import Foundation
import PromptPadAgent
import PromptPadConfig
import PromptPadCore

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
  private static let frameAutosaveName = NSWindow.FrameAutosaveName("PromptPadMainWindowFrame")
  private let session: EditorSession
  private var config: PromptPadConfig
  private let editorVC: EditorViewController
  private var didBecomeActiveObserver: NSObjectProtocol?
  var onClosed: (() -> Void)?
  var onBecameMain: (() -> Void)?

  init(session: EditorSession, config: PromptPadConfig) {
    self.session = session
    self.config = config
    self.editorVC = EditorViewController(session: session, config: config)
    self.editorVC.preferredContentSize = NSSize(width: 760, height: 720)

    let window = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 760, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "PromptPad"
    window.animationBehavior = .none
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.collectionBehavior.insert(.fullScreenAllowsTiling)
    window.contentMinSize = NSSize(width: 420, height: 260)
    Self.applyTheme(config.theme, to: window)
    window.isReleasedWhenClosed = false
    window.contentViewController = editorVC
    window.initialFirstResponder = editorVC.preferredResponderView
    let restored = window.setFrameUsingName(Self.frameAutosaveName)
    window.setFrameAutosaveName(Self.frameAutosaveName)
    if !restored {
      window.setContentSize(editorVC.preferredContentSize)
    }

    super.init(window: window)
    window.delegate = self

    didBecomeActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: NSApp,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.editorVC.focusEditor()
      }
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    if let token = didBecomeActiveObserver {
      NotificationCenter.default.removeObserver(token)
    }
  }

  func windowWillClose(_ notification: Notification) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.editorVC.flushAutosaveNow(reason: "window_close")
      await self.session.markClosed()
      self.onClosed?()
    }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    editorVC.focusEditor()
  }

  func windowDidBecomeMain(_ notification: Notification) {
    editorVC.focusEditor()
    onBecameMain?()
  }

  func setAgentConfig(_ agent: PromptPadConfig.Agent) {
    editorVC.setAgentConfig(agent)
  }

  func setThemeMode(_ theme: PromptPadConfig.ThemeMode) {
    guard let window else { return }
    Self.applyTheme(theme, to: window)
  }

  func setEditorMode(_ mode: PromptPadConfig.EditorMode) {
    config.editorMode = mode
  }

  func runPromptEngineer() {
    editorVC.runPromptEngineer()
  }

  func focusExistingSessionWindow() {
    if !NSApp.isActive {
      NSApp.activate(ignoringOtherApps: true)
    }
    window?.makeKeyAndOrderFront(nil)
    editorVC.focusEditor()
  }

  func restorePreviousBuffer() {
    editorVC.restorePreviousBuffer()
  }

  var typingLatencySamples: [Double] {
    editorVC.typingLatencySamples
  }

  func flushAutosaveNow(reason: String = "forced_flush") async {
    await editorVC.flushAutosaveNow(reason: reason)
  }

  @discardableResult
  func openPath(_ path: String, line: Int?, column: Int?) async throws -> SessionInfo {
    let url = URL(fileURLWithPath: path)
    let info = try await session.open(fileURL: url)
    editorVC.applySessionInfo(info, moveCursorLine: line, column: column)
    window?.orderFrontRegardless()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    editorVC.focusEditor()
    if config.editorMode == .reliable {
      _ = await editorVC.waitUntilEditorReady(timeoutMs: 350)
    }
    return info
  }

  private static func applyTheme(_ mode: PromptPadConfig.ThemeMode, to window: NSWindow) {
    switch mode {
    case .system:
      window.appearance = nil
    case .light:
      window.appearance = NSAppearance(named: .aqua)
    case .dark:
      window.appearance = NSAppearance(named: .darkAqua)
    }
  }
}
