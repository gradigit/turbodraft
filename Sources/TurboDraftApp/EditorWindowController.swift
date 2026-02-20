import AppKit
import Foundation
import TurboDraftAgent
import TurboDraftConfig
import TurboDraftCore

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
  private static let frameAutosaveName = NSWindow.FrameAutosaveName("TurboDraftMainWindowFrame")
  let session: EditorSession
  private var config: TurboDraftConfig
  private let editorVC: EditorViewController
  private var didBecomeActiveObserver: NSObjectProtocol?
  var onClosed: (() -> Void)?
  var onBecameMain: (() -> Void)?

  init(session: EditorSession, config: TurboDraftConfig) {
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
    window.title = "TurboDraft"
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
        guard self.window?.isVisible == true else { return }
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

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    Task { @MainActor [weak self] in
      guard let self else { return }
      // Race flush against a 3s timeout to prevent close hang.
      await withTaskGroup(of: Void.self) { group in
        group.addTask { @MainActor [weak self] in
          guard let self else { return }
          await self.editorVC.flushAutosaveNow(reason: "window_close")
          await self.session.markClosed()
        }
        group.addTask {
          try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        _ = await group.next()
        group.cancelAll()
      }
      self.editorVC.prepareForIdlePool()
      self.window?.orderOut(nil)
      self.onClosed?()
    }
    return false
  }

  func windowWillClose(_ notification: Notification) {
    // No-op: recycling handled in windowShouldClose
  }

  func windowDidBecomeKey(_ notification: Notification) {
    editorVC.focusEditor()
  }

  func windowDidBecomeMain(_ notification: Notification) {
    editorVC.focusEditor()
    onBecameMain?()
  }

  func setAgentConfig(_ agent: TurboDraftConfig.Agent) {
    editorVC.setAgentConfig(agent)
  }

  func setThemeMode(_ theme: TurboDraftConfig.ThemeMode) {
    guard let window else { return }
    Self.applyTheme(theme, to: window)
  }

  func setEditorMode(_ mode: TurboDraftConfig.EditorMode) {
    config.editorMode = mode
  }

  func setColorTheme(_ theme: EditorColorTheme) {
    editorVC.setColorTheme(theme)
    guard let window else { return }
    if theme.id == "default" {
      // Default theme follows the ThemeMode setting — don't override.
    } else if theme.isDark {
      window.appearance = NSAppearance(named: .darkAqua)
    } else {
      window.appearance = NSAppearance(named: .aqua)
    }
  }

  func setFont(family: String, size: Int) {
    editorVC.setFont(family: family, size: size)
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

  func presentSession(_ info: SessionInfo, line: Int?, column: Int?) async {
    editorVC.applySessionInfo(info, moveCursorLine: line, column: column)
    window?.orderFrontRegardless()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    editorVC.focusEditor()
    if config.editorMode == .reliable {
      _ = await editorVC.waitUntilEditorReady(timeoutMs: 350)
    }
  }

  @discardableResult
  func openPath(_ path: String, line: Int?, column: Int?) async throws -> SessionInfo {
    let url = URL(fileURLWithPath: path)
    let info = try await session.open(fileURL: url)
    await presentSession(info, line: line, column: column)
    return info
  }

  private static func applyTheme(_ mode: TurboDraftConfig.ThemeMode, to window: NSWindow) {
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
