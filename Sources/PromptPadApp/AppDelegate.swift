import AppKit
import Foundation
import PromptPadAgent
import PromptPadConfig
import PromptPadCore
import PromptPadProtocol
import PromptPadTransport

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var allWindowControllers: [EditorWindowController] = []
  private var sessionsById: [String: EditorSession] = [:]
  private var windowsById: [String: EditorWindowController] = [:]
  private var sessionPathById: [String: String] = [:]
  private weak var focusedWindowController: EditorWindowController?

  private var socketServer: UnixDomainSocketServer?
  private var stdioServer: JSONRPCServerConnection?
  private var cfg = PromptPadConfig.load()

  private var agentEnabledMenuItem: NSMenuItem?
  private let modelPresets: [String] = [
    "gpt-5.3-codex-spark",
    "gpt-5.3-codex",
    "gpt-5.3",
    "gpt-5",
    "o3",
    "o4-mini",
  ]
  private let startHidden = CommandLine.arguments.contains("--start-hidden")
  private let terminateOnLastClose = CommandLine.arguments.contains("--terminate-on-last-close")

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = false

    if !startHidden {
      let wc = makeWindowController(session: EditorSession())
      wc.showWindow(nil)
      focusedWindowController = wc
    }
    installMenu()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppWillResignActive(_:)),
      name: NSApplication.willResignActiveNotification,
      object: NSApp
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppWillHide(_:)),
      name: NSApplication.willHideNotification,
      object: NSApp
    )

    if !CommandLine.arguments.contains("--no-socket") {
      do {
        // Ensure socket directory exists and is user-only.
        let socketURL = URL(fileURLWithPath: cfg.socketPath)
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketURL.deletingLastPathComponent().path)

        let server = try UnixDomainSocketServer(socketPath: cfg.socketPath)
        socketServer = server
        server.start { [weak self] clientFD in
          Task { @MainActor in
            self?.handleClient(fd: clientFD)
          }
        }
      } catch {
        if case UnixDomainSocketError.alreadyRunning = error {
          NSApplication.shared.terminate(nil)
          return
        }
        NSLog("Failed to start socket server: \(error)")
      }
    }

    if CommandLine.arguments.contains("--stdio") {
      startStdioServer()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    terminateOnLastClose
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if let wc = activeWindowController() {
      wc.showWindow(nil)
      wc.window?.makeKeyAndOrderFront(nil)
    } else {
      let wc = makeWindowController(session: EditorSession())
      wc.showWindow(nil)
      focusedWindowController = wc
    }
    return true
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    guard let first = filenames.first else { return }
    Task { @MainActor in
      let editorSession = EditorSession()
      let wc = makeWindowController(session: editorSession)
      do {
        let info = try await wc.openPath(first, line: nil, column: nil)
        registerSession(
          id: info.sessionId,
          path: info.fileURL.standardizedFileURL.path,
          session: editorSession,
          window: wc
        )
      } catch {
        NSLog("openFiles failed: \(error)")
      }
    }
    sender.reply(toOpenOrPrint: .success)
  }

  func applicationWillTerminate(_ notification: Notification) {
    let windows = allWindowControllers
    let sessions = Array(sessionsById.values)
    Task { @MainActor in
      for wc in windows {
        await wc.flushAutosaveNow(reason: "app_terminate")
      }
      for session in sessions {
        await session.markClosed()
      }
    }
  }

  @objc private func handleAppWillResignActive(_ note: Notification) {
    Task { @MainActor in
      await flushAllWindows(reason: "app_resign_active")
    }
  }

  @objc private func handleAppWillHide(_ note: Notification) {
    Task { @MainActor in
      await flushAllWindows(reason: "app_hide")
    }
  }

  private func flushAllWindows(reason: String) async {
    let windows = allWindowControllers
    for wc in windows {
      await wc.flushAutosaveNow(reason: reason)
    }
  }

  private func makeWindowController(session: EditorSession) -> EditorWindowController {
    let wc = EditorWindowController(session: session, config: cfg)
    wc.onClosed = { [weak self, weak wc] in
      guard let self, let wc else { return }
      self.handleWindowClosed(wc)
    }
    wc.onBecameMain = { [weak self, weak wc] in
      guard let self, let wc else { return }
      self.focusedWindowController = wc
    }
    wc.setAgentConfig(cfg.agent)
    wc.setThemeMode(cfg.theme)
    wc.setEditorMode(cfg.editorMode)
    allWindowControllers.append(wc)
    return wc
  }

  private func handleWindowClosed(_ wc: EditorWindowController) {
    allWindowControllers.removeAll { $0 === wc }
    let removedSessionIds = windowsById.compactMap { key, value in
      value === wc ? key : nil
    }
    for sessionId in removedSessionIds {
      windowsById.removeValue(forKey: sessionId)
      sessionPathById.removeValue(forKey: sessionId)
      // Keep sessionsById alive until session.wait completes and explicitly removes it.
    }
    if focusedWindowController === wc {
      focusedWindowController = nil
    }
  }

  private func registerSession(id: String, path: String, session: EditorSession, window: EditorWindowController) {
    sessionsById[id] = session
    windowsById[id] = window
    sessionPathById[id] = path
    focusedWindowController = window
  }

  private func retireSessionMappings(for session: EditorSession) {
    let staleIDs = sessionsById.compactMap { id, value in
      value === session ? id : nil
    }
    for id in staleIDs {
      sessionsById.removeValue(forKey: id)
      windowsById.removeValue(forKey: id)
      sessionPathById.removeValue(forKey: id)
    }
  }

  private func reusableSession(forPath normalizedPath: String) -> (EditorSession, EditorWindowController)? {
    for (sessionId, path) in sessionPathById where path == normalizedPath {
      guard let session = sessionsById[sessionId], let window = windowsById[sessionId] else { continue }
      return (session, window)
    }
    return nil
  }

  private func activeWindowController() -> EditorWindowController? {
    if let wc = NSApp.keyWindow?.windowController as? EditorWindowController {
      return wc
    }
    if let focusedWindowController {
      return focusedWindowController
    }
    return allWindowControllers.last
  }

  private func applyAgentConfigToAllWindows() {
    for wc in allWindowControllers {
      wc.setAgentConfig(cfg.agent)
    }
  }

  private func applyThemeToAllWindows() {
    for wc in allWindowControllers {
      wc.setThemeMode(cfg.theme)
    }
  }

  private func applyEditorModeToAllWindows() {
    for wc in allWindowControllers {
      wc.setEditorMode(cfg.editorMode)
    }
  }

  private func handleClient(fd: Int32) {
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
    let server = JSONRPCServerConnection(connection: conn) { [weak self] req in
      await self?.handleRequest(req) ?? nil
    }
    server.run()
  }

  private func startStdioServer() {
    let conn = JSONRPCConnection(readHandle: FileHandle.standardInput, writeHandle: FileHandle.standardOutput)
    let server = JSONRPCServerConnection(connection: conn) { [weak self] req in
      await self?.handleRequest(req) ?? nil
    }
    stdioServer = server
    server.run()
  }

  private func handleRequest(_ req: JSONRPCRequest) async -> JSONRPCResponse? {
    guard let id = req.id else { return nil }

    func ok(_ value: Encodable) -> JSONRPCResponse {
      let data = (try? JSONEncoder().encode(AnyEncodable(value))) ?? Data()
      let json = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
      let wrapped = JSONValue.fromJSONObject(json)
      return JSONRPCResponse(id: id, result: wrapped, error: nil)
    }

    func err(_ code: Int, _ message: String, _ data: JSONValue? = nil) -> JSONRPCResponse {
      JSONRPCResponse(id: id, result: nil, error: JSONRPCErrorObject(code: code, message: message, data: data))
    }

    switch req.method {
    case PromptPadMethod.hello:
      let caps = PromptPadCapabilities(supportsWait: true, supportsAgentDraft: cfg.agent.enabled, supportsQuit: true)
      let res = HelloResult(protocolVersion: 1, capabilities: caps, serverPid: Int(getpid()))
      return ok(res)

    case PromptPadMethod.sessionOpen:
      do {
        let params = try (req.params ?? .object([:])).decode(SessionOpenParams.self)
        let t0 = nowMs()
        let normalizedPath = URL(fileURLWithPath: params.path).standardizedFileURL.path
        let editorSession: EditorSession
        let wc: EditorWindowController
        if let reuse = reusableSession(forPath: normalizedPath) {
          editorSession = reuse.0
          wc = reuse.1
          if let current = await editorSession.currentInfo(),
             current.fileURL.standardizedFileURL.path == normalizedPath {
            wc.focusExistingSessionWindow()
            let openMs = nowMs() - t0
            appendLatencyRecord([
              "event": "app_session_open",
              "openMs": openMs,
            ])
            let out = SessionOpenResult(
              sessionId: current.sessionId,
              path: current.fileURL.path,
              content: current.content,
              revision: current.diskRevision,
              isDirty: current.isDirty
            )
            return ok(out)
          }
        } else {
          editorSession = EditorSession()
          wc = makeWindowController(session: editorSession)
        }
        let info = try await wc.openPath(params.path, line: params.line, column: params.column)
        retireSessionMappings(for: editorSession)
        registerSession(
          id: info.sessionId,
          path: info.fileURL.standardizedFileURL.path,
          session: editorSession,
          window: wc
        )

        let openMs = nowMs() - t0
        appendLatencyRecord([
          "event": "app_session_open",
          "openMs": openMs,
        ])

        let out = SessionOpenResult(
          sessionId: info.sessionId,
          path: info.fileURL.path,
          content: info.content,
          revision: info.diskRevision,
          isDirty: info.isDirty
        )
        return ok(out)
      } catch {
        return err(JSONRPCStandardErrorCode.invalidParams, "open failed: \(error)")
      }

    case PromptPadMethod.sessionReload:
      do {
        let params = try (req.params ?? .object([:])).decode(SessionReloadParams.self)
        guard let editorSession = sessionsById[params.sessionId] else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "Invalid sessionId")
        }
        _ = try? await editorSession.applyExternalDiskChange()
        guard let info = await editorSession.currentInfo() else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "No session")
        }
        return ok(SessionReloadResult(content: info.content, revision: info.diskRevision))
      } catch {
        return err(JSONRPCStandardErrorCode.invalidParams, "reload failed: \(error)")
      }

    case PromptPadMethod.sessionWaitForRevision:
      do {
        let params = try (req.params ?? .object([:])).decode(SessionWaitForRevisionParams.self)
        guard let editorSession = sessionsById[params.sessionId] else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "Invalid sessionId")
        }

        if let info = await editorSession.waitUntilRevisionChange(
          baseRevision: params.baseRevision,
          timeoutMs: params.timeoutMs
        ) {
          return ok(
            SessionWaitForRevisionResult(
              content: info.content,
              revision: info.diskRevision,
              changed: info.diskRevision != params.baseRevision
            )
          )
        }

        guard let info = await editorSession.currentInfo() else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "No session")
        }
        return ok(
          SessionWaitForRevisionResult(
            content: info.content,
            revision: info.diskRevision,
            changed: info.diskRevision != params.baseRevision
          )
        )
      } catch {
        return err(JSONRPCStandardErrorCode.invalidParams, "waitForRevision failed: \(error)")
      }

    case PromptPadMethod.sessionSave:
      do {
        let params = try (req.params ?? .object([:])).decode(SessionSaveParams.self)
        guard let editorSession = sessionsById[params.sessionId] else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "Invalid sessionId")
        }
        // Session-bound save: ignore params.path and only save current session content.
        await editorSession.updateBufferContent(params.content)
        let _ = try await editorSession.autosave(reason: "rpc_save")
        if let info = await editorSession.currentInfo() {
          return ok(SessionSaveResult(ok: true, revision: info.diskRevision))
        }
        return err(JSONRPCStandardErrorCode.invalidRequest, "No session")
      } catch {
        return err(JSONRPCStandardErrorCode.invalidParams, "save failed: \(error)")
      }

    case PromptPadMethod.sessionWait:
      do {
        let params = try (req.params ?? .object([:])).decode(SessionWaitParams.self)
        guard let editorSession = sessionsById[params.sessionId] else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "Invalid sessionId")
        }
        let closed = await editorSession.waitUntilClosed(timeoutMs: params.timeoutMs)
        if closed {
          sessionsById.removeValue(forKey: params.sessionId)
          windowsById.removeValue(forKey: params.sessionId)
          sessionPathById.removeValue(forKey: params.sessionId)
        }
        return ok(SessionWaitResult(reason: closed ? "userClosed" : "timeout"))
      } catch {
        return err(JSONRPCStandardErrorCode.invalidParams, "wait failed: \(error)")
      }

    case PromptPadMethod.appQuit:
      Task { @MainActor in
        // Give the JSON-RPC response a chance to flush before terminating.
        try? await Task.sleep(nanoseconds: 50_000_000)
        NSApplication.shared.terminate(nil)
      }
      return ok(["ok": true])

    default:
      return err(JSONRPCStandardErrorCode.methodNotFound, "Unknown method")
    }
  }

  private func installMenu() {
    let main = NSMenu()
    let appName = ProcessInfo.processInfo.processName
    func responderItem(_ title: String, _ action: Selector, _ key: String, modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = nil
      return item
    }

    // App menu
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu(title: appName)
    appItem.submenu = appMenu
    appMenu.addItem(NSMenuItem(title: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
    appMenu.addItem(.separator())
    let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    let servicesMenu = NSMenu(title: "Services")
    services.submenu = servicesMenu
    appMenu.addItem(services)
    NSApp.servicesMenu = servicesMenu
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
    appMenu.addItem(NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"))
    appMenu.items.last?.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

    // File menu
    let fileItem = NSMenuItem()
    fileItem.title = "File"
    main.addItem(fileItem)
    let fileMenu = NSMenu(title: "File")
    fileItem.submenu = fileMenu
    fileMenu.addItem(responderItem("Close Window", #selector(NSWindow.performClose(_:)), "w"))

    // Edit menu
    let editItem = NSMenuItem()
    editItem.title = "Edit"
    main.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editItem.submenu = editMenu
    editMenu.autoenablesItems = true
    editMenu.addItem(responderItem("Undo", Selector(("undo:")), "z"))
    editMenu.addItem(responderItem("Redo", Selector(("redo:")), "Z"))
    editMenu.addItem(.separator())
    editMenu.addItem(responderItem("Cut", #selector(NSText.cut(_:)), "x"))
    editMenu.addItem(responderItem("Copy", #selector(NSText.copy(_:)), "c"))
    editMenu.addItem(responderItem("Paste", #selector(NSText.paste(_:)), "v"))
    editMenu.addItem(responderItem("Select All", #selector(NSText.selectAll(_:)), "a"))

    // View menu
    let viewItem = NSMenuItem()
    viewItem.title = "View"
    main.addItem(viewItem)
    let viewMenu = NSMenu(title: "View")
    viewItem.submenu = viewMenu
    viewMenu.addItem(responderItem("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control]))

    let themeParent = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
    let themeMenu = NSMenu(title: "Theme")
    themeParent.submenu = themeMenu
    func addThemeItem(title: String, value: PromptPadConfig.ThemeMode) {
      let i = NSMenuItem(title: title, action: #selector(selectThemeMode(_:)), keyEquivalent: "")
      i.target = self
      i.representedObject = value.rawValue
      i.state = (cfg.theme == value) ? .on : .off
      i.tag = 901
      themeMenu.addItem(i)
    }
    addThemeItem(title: "System", value: .system)
    addThemeItem(title: "Light", value: .light)
    addThemeItem(title: "Dark", value: .dark)
    viewMenu.addItem(themeParent)

    let modeParent = NSMenuItem(title: "Editor Mode", action: nil, keyEquivalent: "")
    let modeMenu = NSMenu(title: "Editor Mode")
    func addModeItem(title: String, value: PromptPadConfig.EditorMode) {
      let i = NSMenuItem(title: title, action: #selector(selectEditorMode(_:)), keyEquivalent: "")
      i.target = self
      i.representedObject = value.rawValue
      i.state = (cfg.editorMode == value) ? .on : .off
      i.tag = 902
      modeMenu.addItem(i)
    }
    addModeItem(title: "Reliable", value: .reliable)
    addModeItem(title: "Ultra Fast", value: .ultraFast)
    modeParent.submenu = modeMenu
    viewMenu.addItem(modeParent)

    // Agent menu
    let agentItem = NSMenuItem()
    agentItem.title = "Agent"
    main.addItem(agentItem)
    let agentMenu = NSMenu(title: "Agent")
    agentItem.submenu = agentMenu

    let enable = NSMenuItem(title: "Enable Prompt Engineer", action: #selector(togglePromptEngineer(_:)), keyEquivalent: "")
    enable.target = self
    enable.state = cfg.agent.enabled ? .on : .off
    agentMenu.addItem(enable)
    agentEnabledMenuItem = enable

    let improve = NSMenuItem(title: "Improve Prompt", action: #selector(improvePrompt(_:)), keyEquivalent: "r")
    improve.target = self
    improve.keyEquivalentModifierMask = [.command, .shift]
    improve.isEnabled = true
    agentMenu.addItem(improve)

    let restore = NSMenuItem(title: "Restore Previous Buffer", action: #selector(restorePreviousBuffer(_:)), keyEquivalent: "")
    restore.target = self
    restore.isEnabled = true
    agentMenu.addItem(restore)

    agentMenu.addItem(.separator())

    let modelParent = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
    let modelMenu = NSMenu(title: "Model")
    for model in modelPresets {
      let item = NSMenuItem(title: model, action: #selector(selectAgentModel(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = model
      item.state = (cfg.agent.model == model) ? .on : .off
      modelMenu.addItem(item)
    }
    modelMenu.addItem(.separator())
    let customModel = NSMenuItem(title: "Custom…", action: #selector(selectCustomAgentModel(_:)), keyEquivalent: "")
    customModel.target = self
    modelMenu.addItem(customModel)
    modelParent.submenu = modelMenu
    agentMenu.addItem(modelParent)

    func addRadioSubmenu<T: RawRepresentable & CaseIterable>(
      title: String,
      current: T,
      action: Selector,
      titleFor: (T) -> String,
      isEnabled: (T) -> Bool = { _ in true }
    ) where T.RawValue == String {
      let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let sub = NSMenu(title: title)
      for v in T.allCases {
        let item = NSMenuItem(title: titleFor(v), action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = v.rawValue
        item.state = (v.rawValue == current.rawValue) ? .on : .off
        item.isEnabled = isEnabled(v)
        sub.addItem(item)
      }
      parent.submenu = sub
      agentMenu.addItem(parent)
    }

    addRadioSubmenu(
      title: "Prompt Profile",
      current: cfg.agent.promptProfile,
      action: #selector(selectPromptProfile(_:)),
      titleFor: { v in
        switch v {
        case .core: return "Core"
        case .largeOpt: return "Large (Optimized)"
        case .extended: return "Extended"
        }
      }
    )

    addRadioSubmenu(
      title: "Backend",
      current: cfg.agent.backend,
      action: #selector(selectAgentBackend(_:)),
      titleFor: { v in
        switch v {
        case .exec: return "Exec (Spawn)"
        case .appServer: return "App Server (Warm)"
        }
      }
    )

    addRadioSubmenu(
      title: "Reasoning Effort",
      current: cfg.agent.reasoningEffort,
      action: #selector(selectReasoningEffort(_:)),
      titleFor: { v in
        switch v {
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        }
      }
    )

    addRadioSubmenu(
      title: "Reasoning Summary",
      current: cfg.agent.reasoningSummary,
      action: #selector(selectReasoningSummary(_:)),
      titleFor: { v in
        switch v {
        case .auto: return "Auto"
        case .concise: return "Concise"
        case .detailed: return "Detailed"
        case .none: return "None"
        }
      }
    )

    addRadioSubmenu(
      title: "Web Search",
      current: cfg.agent.webSearch,
      action: #selector(selectWebSearchMode(_:)),
      titleFor: { v in
        switch v {
        case .disabled: return "Disabled"
        case .cached: return "Cached"
        case .live: return "Live"
        }
      }
    )

    // Window menu
    let windowItem = NSMenuItem()
    windowItem.title = "Window"
    main.addItem(windowItem)
    let windowMenu = NSMenu(title: "Window")
    windowItem.submenu = windowMenu
    windowMenu.addItem(responderItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
    windowMenu.addItem(responderItem("Zoom", #selector(NSWindow.performZoom(_:)), ""))
    windowMenu.addItem(.separator())
    windowMenu.addItem(responderItem("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
    NSApp.windowsMenu = windowMenu

    NSApp.mainMenu = main
  }

  @MainActor @objc private func togglePromptEngineer(_ sender: NSMenuItem) {
    cfg.agent.enabled.toggle()
    sender.state = cfg.agent.enabled ? .on : .off
    applyAgentConfigToAllWindows()
    try? cfg.write()
  }

  @MainActor @objc private func improvePrompt(_ sender: NSMenuItem) {
    activeWindowController()?.runPromptEngineer()
  }

  @MainActor @objc private func restorePreviousBuffer(_ sender: NSMenuItem) {
    activeWindowController()?.restorePreviousBuffer()
  }

  @MainActor @objc private func selectAgentModel(_ sender: NSMenuItem) {
    guard let model = sender.representedObject as? String else { return }
    cfg.agent.model = model
    if model.contains("spark"), cfg.agent.reasoningEffort == .minimal {
      cfg.agent.reasoningEffort = .low
    }
    sender.menu?.items.forEach {
      if $0.action == #selector(selectAgentModel(_:)) {
        $0.state = .off
      }
    }
    sender.state = .on
    applyAgentConfigToAllWindows()
    try? cfg.write()
  }

  @MainActor @objc private func selectCustomAgentModel(_ sender: NSMenuItem) {
    let alert = NSAlert()
    alert.messageText = "Set Model"
    alert.informativeText = "Enter any model id supported by your Codex CLI setup."
    alert.alertStyle = .informational
    let input = NSTextField(string: cfg.agent.model)
    input.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
    alert.accessoryView = input
    alert.addButton(withTitle: "Apply")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let model = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { return }

    cfg.agent.model = model
    if model.contains("spark"), cfg.agent.reasoningEffort == .minimal {
      cfg.agent.reasoningEffort = .low
    }
    applyAgentConfigToAllWindows()
    try? cfg.write()
    installMenu()
  }

  @MainActor @objc private func selectThemeMode(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = PromptPadConfig.ThemeMode(rawValue: raw)
    else { return }
    cfg.theme = v
    sender.menu?.items.filter { $0.tag == 901 }.forEach { $0.state = .off }
    sender.state = .on
    applyThemeToAllWindows()
    try? cfg.write()
  }

  @MainActor @objc private func selectEditorMode(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = PromptPadConfig.EditorMode(rawValue: raw)
    else { return }
    cfg.editorMode = v
    sender.menu?.items.filter { $0.tag == 902 }.forEach { $0.state = .off }
    sender.state = .on
    applyEditorModeToAllWindows()
    try? cfg.write()
  }

  @MainActor @objc private func selectPromptProfile(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = PromptPadConfig.Agent.PromptProfile(rawValue: raw)
    else { return }
    cfg.agent.promptProfile = v
    sender.menu?.items.forEach { $0.state = .off }
    sender.state = .on
    applyAgentConfigToAllWindows()
    try? cfg.write()
  }

  @MainActor @objc private func selectAgentBackend(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = PromptPadConfig.Agent.Backend(rawValue: raw)
    else { return }
    cfg.agent.backend = v
    sender.menu?.items.forEach { $0.state = .off }
    sender.state = .on
    applyAgentConfigToAllWindows()
    try? cfg.write()
  }

  @MainActor @objc private func selectReasoningEffort(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = PromptPadConfig.Agent.ReasoningEffort(rawValue: raw)
    else { return }
    cfg.agent.reasoningEffort = v
    sender.menu?.items.forEach { $0.state = .off }
    sender.state = .on
    applyAgentConfigToAllWindows()
    try? cfg.write()
  }

  @MainActor @objc private func selectReasoningSummary(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = PromptPadConfig.Agent.ReasoningSummary(rawValue: raw)
    else { return }
    cfg.agent.reasoningSummary = v
    sender.menu?.items.forEach { $0.state = .off }
    sender.state = .on
    applyAgentConfigToAllWindows()
    try? cfg.write()
  }

  @MainActor @objc private func selectWebSearchMode(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = PromptPadConfig.Agent.WebSearchMode(rawValue: raw)
    else { return }
    cfg.agent.webSearch = v
    sender.menu?.items.forEach { $0.state = .off }
    sender.state = .on
    applyAgentConfigToAllWindows()
    try? cfg.write()
  }

  private func nowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
  }

  private func appendLatencyRecord(_ payload: [String: Any]) {
    do {
      let dir = try PromptPadPaths.applicationSupportDir().appendingPathComponent("telemetry", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let file = dir.appendingPathComponent("editor-open.jsonl")
      var record = payload
      record["ts"] = ISO8601DateFormatter().string(from: Date())
      let data = try JSONSerialization.data(withJSONObject: record, options: [])
      let line = data + Data([0x0A])
      if FileManager.default.fileExists(atPath: file.path) {
        let fh = try FileHandle(forWritingTo: file)
        try fh.seekToEnd()
        try fh.write(contentsOf: line)
        try fh.close()
      } else {
        try line.write(to: file, options: [.atomic])
      }
    } catch {
      // Best-effort telemetry only.
    }
  }
}

// Helpers to bridge Encodable -> JSONValue without generic envelopes.
private struct AnyEncodable: Encodable {
  let value: Encodable
  init(_ value: Encodable) { self.value = value }
  func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

extension JSONValue {
  static func fromJSONObject(_ obj: Any) -> JSONValue {
    switch obj {
    case is NSNull: return .null
    case let b as Bool: return .bool(b)
    case let n as NSNumber:
      // NSNumber can be Bool; ensure we already handled Bool above.
      let cfType = CFNumberGetType(n)
      switch cfType {
      case .sInt8Type, .sInt16Type, .sInt32Type, .sInt64Type, .charType, .shortType, .intType, .longType, .longLongType:
        return .int(n.int64Value)
      default:
        return .double(n.doubleValue)
      }
    case let s as String: return .string(s)
    case let a as [Any]:
      return .array(a.map { fromJSONObject($0) })
    case let d as [String: Any]:
      var out: [String: JSONValue] = [:]
      for (k, v) in d { out[k] = fromJSONObject(v) }
      return .object(out)
    default:
      return .string(String(describing: obj))
    }
  }
}
