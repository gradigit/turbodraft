import AppKit
import Foundation
import os
import TurboDraftAgent
import TurboDraftConfig
import TurboDraftCore
import TurboDraftProtocol
import TurboDraftTransport

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var allWindowControllers: [EditorWindowController] = []
  private var idleWindowControllers: [EditorWindowController] = []
  private var sessionsById: [String: EditorSession] = [:]
  private var windowsById: [String: EditorWindowController] = [:]
  private var sessionPathById: [String: String] = [:]
  private var sessionLastTouchedById: [String: Date] = [:]
  private weak var focusedWindowController: EditorWindowController?

  private var socketServer: UnixDomainSocketServer?
  private var stdioServer: JSONRPCServerConnection?
  private var sessionSweepTask: Task<Void, Never>?
  private var lastSessionSweepAt = Date.distantPast
  private var telemetryHandle: FileHandle?
  private lazy var telemetryFileURL: URL? = {
    do {
      let dir = try TurboDraftPaths.applicationSupportDir().appendingPathComponent("telemetry", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir.appendingPathComponent("editor-open.jsonl")
    } catch {
      Self.appLog.warning("Failed to prepare telemetry path: \(String(describing: error), privacy: .public)")
      return nil
    }
  }()
  private var cfg = TurboDraftConfig.load()

  private var colorThemes: [EditorColorTheme] = []
  private var agentEnabledMenuItem: NSMenuItem?
  private let modelPresets: [String] = [
    "gpt-5.3-codex-spark",
    "gpt-5.3-codex",
    "gpt-5.3",
    "gpt-5",
    "o3",
    "o4-mini",
    "claude-sonnet-4-6",
  ]
  private let startHidden = CommandLine.arguments.contains("--start-hidden")
  private let terminateOnLastClose = CommandLine.arguments.contains("--terminate-on-last-close")
  private static let appLog = Logger(subsystem: "com.turbodraft", category: "AppDelegate")
  private static let telemetryDateFormatter = ISO8601DateFormatter()
  private let sessionSweepInterval: TimeInterval = 60
  private let orphanSessionMaxAge: TimeInterval = 120

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = false
    // Lower tooltip hover delay for snappier in-editor discoverability.
    UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 180])
    cleanUpStaleTempFiles()
    colorThemes = EditorColorTheme.allThemes()

    if !startHidden {
      let wc = makeWindowController(session: EditorSession(), showInDock: true)
      wc.showWindow(nil)
      focusedWindowController = wc
    } else {
      // Pre-create one idle window so first Ctrl+G is instant.
      let wc = makeWindowController(session: EditorSession(), showInDock: false)
      idleWindowControllers.append(wc)
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
        try ensureSocketDirectorySecure(for: cfg.socketPath)

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

    startSessionSweepTask()

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
      if NSApp.activationPolicy() == .accessory {
        NSApp.setActivationPolicy(.regular)
      }
      let wc = dequeueIdleWindowController()
      wc.showWindow(nil)
      focusedWindowController = wc
    }
    return true
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    guard let first = filenames.first else {
      sender.reply(toOpenOrPrint: .failure)
      return
    }
    Task { @MainActor in
      let wc = dequeueIdleWindowController()
      let editorSession = wc.session
      if NSApp.activationPolicy() == .accessory {
        NSApp.setActivationPolicy(.regular)
      }
      do {
        let info = try await wc.openPath(first, line: nil, column: nil)
        registerSession(
          id: info.sessionId,
          path: info.fileURL.standardizedFileURL.path,
          session: editorSession,
          window: wc
        )
        sender.reply(toOpenOrPrint: .success)
      } catch {
        NSLog("openFiles failed: \(error)")
        sender.reply(toOpenOrPrint: .failure)
      }
    }
  }

  @objc private func gracefulQuit(_ sender: Any?) {
    if startHidden {
      // LaunchAgent mode: close all windows → idle pool, stay alive for instant reopen.
      for wc in allWindowControllers where !idleWindowControllers.contains(where: { $0 === wc }) {
        wc.window?.performClose(nil)
      }
    } else {
      Task { @MainActor in
        await performGracefulShutdown()
        NSApplication.shared.terminate(nil)
      }
    }
  }

  @objc private func forceQuit(_ sender: Any?) {
    Task { @MainActor in
      await performGracefulShutdown()
      NSApplication.shared.terminate(nil)
    }
  }

  private func performGracefulShutdown() async {
    stopSessionSweepTask()
    try? telemetryHandle?.close()
    telemetryHandle = nil

    // Race all flushes against a 5s overall timeout to prevent quit hang.
    await withTaskGroup(of: Void.self) { group in
      group.addTask { @MainActor in
        for wc in self.allWindowControllers {
          await wc.flushAutosaveNow(reason: "app_terminate")
        }
        for session in self.sessionsById.values {
          await session.markClosed()
        }
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
      }
      _ = await group.next()
      group.cancelAll()
    }
  }

  private func ensureSocketDirectorySecure(for socketPath: String) throws {
    let socketURL = URL(fileURLWithPath: socketPath)
    let socketDirURL = socketURL.deletingLastPathComponent()
    let fm = FileManager.default
    var isDir: ObjCBool = false
    let path = socketDirURL.path
    if !fm.fileExists(atPath: path, isDirectory: &isDir) {
      try fm.createDirectory(
        at: socketDirURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      return
    }
    guard isDir.boolValue else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
    }

    let attrs = try? fm.attributesOfItem(atPath: path)
    let ownerID = (attrs?[.ownerAccountID] as? NSNumber)?.uint32Value
    let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0

    if ownerID == getuid() {
      do {
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
      } catch {
        Self.appLog.warning("Unable to tighten socket directory permissions at \(path, privacy: .public): \(String(describing: error), privacy: .public)")
      }
      return
    }

    // For shared/system-owned directories (for example /tmp), don't hard-fail startup.
    if (perms & 0o077) != 0 {
      Self.appLog.warning(
        "Socket directory \(path, privacy: .public) is not user-owned and is group/world-accessible (mode=\(String(perms, radix: 8), privacy: .public)); continuing with socket-file permissions + peer UID checks."
      )
    } else {
      Self.appLog.info(
        "Socket directory \(path, privacy: .public) is not user-owned (owner=\(String(ownerID ?? 0), privacy: .public)); skipping chmod."
      )
    }
  }

  private func startSessionSweepTask() {
    stopSessionSweepTask()
    sessionSweepTask = Task { [weak self] in
      while !Task.isCancelled {
        let intervalSeconds = self?.sessionSweepInterval ?? 60
        let sleepNs = UInt64(max(1.0, intervalSeconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: sleepNs)
        guard let self else { return }
        await self.sweepOrphanSessionsIfNeeded(force: true, reason: "periodic")
      }
    }
  }

  private func stopSessionSweepTask() {
    sessionSweepTask?.cancel()
    sessionSweepTask = nil
  }

  private func sweepOrphanSessionsIfNeeded(force: Bool = false, reason: String) async {
    let now = Date()
    if !force, now.timeIntervalSince(lastSessionSweepAt) < sessionSweepInterval {
      return
    }
    lastSessionSweepAt = now

    var staleSessionIDs: [String] = []
    for id in sessionsById.keys {
      if windowsById[id] != nil {
        continue
      }
      let touchedAt = sessionLastTouchedById[id] ?? .distantPast
      if now.timeIntervalSince(touchedAt) >= orphanSessionMaxAge {
        staleSessionIDs.append(id)
      }
    }

    for id in staleSessionIDs {
      if let session = sessionsById.removeValue(forKey: id) {
        await session.markClosed()
      }
      windowsById.removeValue(forKey: id)
      sessionPathById.removeValue(forKey: id)
      sessionLastTouchedById.removeValue(forKey: id)
    }

    if !staleSessionIDs.isEmpty {
      Self.appLog.info("Swept \(staleSessionIDs.count) orphaned session(s) (\(reason, privacy: .public))")
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

  private func makeWindowController(session: EditorSession, showInDock: Bool = true) -> EditorWindowController {
    if showInDock && NSApp.activationPolicy() == .accessory {
      NSApp.setActivationPolicy(.regular)
    }
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
    let resolvedColorTheme = EditorColorTheme.resolve(id: cfg.colorTheme, from: colorThemes)
    wc.setColorTheme(resolvedColorTheme)
    wc.setFont(family: cfg.fontFamily, size: cfg.fontSize)
    allWindowControllers.append(wc)
    return wc
  }

  private func dequeueIdleWindowController() -> EditorWindowController {
    if let wc = idleWindowControllers.popLast() {
      return wc
    }
    return makeWindowController(session: EditorSession(), showInDock: false)
  }

  private func handleWindowClosed(_ wc: EditorWindowController) {
    let removedSessionIds = windowsById.compactMap { key, value in
      value === wc ? key : nil
    }
    for sessionId in removedSessionIds {
      sessionsById.removeValue(forKey: sessionId)
      windowsById.removeValue(forKey: sessionId)
      sessionPathById.removeValue(forKey: sessionId)
      sessionLastTouchedById.removeValue(forKey: sessionId)
    }
    if focusedWindowController === wc {
      focusedWindowController = nil
    }

    // Recycle to idle pool (keep max 3 idle windows)
    if idleWindowControllers.count < 3 {
      idleWindowControllers.append(wc)
    } else {
      allWindowControllers.removeAll { $0 === wc }
    }

    // If no visible windows remain, handle accessory mode and terminate-on-last-close
    let visibleCount = allWindowControllers.count - idleWindowControllers.count
    if visibleCount <= 0 {
      if terminateOnLastClose {
        Task { @MainActor in
          await self.performGracefulShutdown()
          NSApplication.shared.terminate(nil)
        }
      } else if startHidden {
        NSApp.setActivationPolicy(.accessory)
      }
    }
  }

  private func registerSession(id: String, path: String, session: EditorSession, window: EditorWindowController) {
    sessionsById[id] = session
    windowsById[id] = window
    sessionPathById[id] = path
    sessionLastTouchedById[id] = Date()
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
      sessionLastTouchedById.removeValue(forKey: id)
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
    return allWindowControllers.last(where: { wc in !idleWindowControllers.contains(where: { $0 === wc }) })
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

  private func persistConfig(context: String) {
    cfg = cfg.sanitized()
    do {
      try cfg.write()
    } catch {
      Self.appLog.error("Failed to persist config (\(context, privacy: .public)): \(String(describing: error), privacy: .public)")
    }
  }

  private func touchSession(_ id: String) {
    sessionLastTouchedById[id] = Date()
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
    await sweepOrphanSessionsIfNeeded(reason: "request")

    // Known: encode → serialize → wrap round-trip is ~microsecond overhead per RPC (#46).
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
    case TurboDraftMethod.hello:
      let params = (try? (req.params ?? .object([:])).decode(HelloParams.self))
      let clientProtocolVersion = params?.protocolVersion
      if let v = clientProtocolVersion, v != TurboDraftProtocolVersion.current {
        return err(
          JSONRPCStandardErrorCode.invalidRequest,
          "protocolVersion mismatch: client=\(v) server=\(TurboDraftProtocolVersion.current)"
        )
      }
      let caps = TurboDraftCapabilities(supportsWait: true, supportsAgentDraft: cfg.agent.enabled, supportsQuit: true)
      let res = HelloResult(protocolVersion: TurboDraftProtocolVersion.current, capabilities: caps, serverPid: Int(getpid()))
      return ok(res)

    case TurboDraftMethod.sessionOpen:
      do {
        let params = try (req.params ?? .object([:])).decode(SessionOpenParams.self)
        guard let clientProtocolVersion = params.protocolVersion else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "protocolVersion is required")
        }
        guard clientProtocolVersion == TurboDraftProtocolVersion.current else {
          return err(
            JSONRPCStandardErrorCode.invalidRequest,
            "protocolVersion mismatch: client=\(clientProtocolVersion) server=\(TurboDraftProtocolVersion.current)"
          )
        }
        let t0 = nowMs()
        let normalizedPath = URL(fileURLWithPath: params.path).standardizedFileURL.path
        let editorSession: EditorSession
        let wc: EditorWindowController
        if let reuse = reusableSession(forPath: normalizedPath) {
          editorSession = reuse.0
          wc = reuse.1
          if let current = await editorSession.currentInfo(),
             current.fileURL.standardizedFileURL.path == normalizedPath {
            touchSession(current.sessionId)
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
              isDirty: current.isDirty,
              serverOpenMs: openMs
            )
            return ok(out)
          }
        } else {
          wc = dequeueIdleWindowController()
          editorSession = wc.session
        }
        if NSApp.activationPolicy() == .accessory {
          NSApp.setActivationPolicy(.regular)
        }
        let url = URL(fileURLWithPath: params.path)
        let info = try await editorSession.open(fileURL: url, cwd: params.cwd)
        retireSessionMappings(for: editorSession)
        registerSession(
          id: info.sessionId,
          path: info.fileURL.standardizedFileURL.path,
          session: editorSession,
          window: wc
        )
        touchSession(info.sessionId)

        // Present window asynchronously — doesn't block RPC response
        Task { @MainActor in
          await wc.presentSession(info, line: params.line, column: params.column)
        }

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
          isDirty: info.isDirty,
          serverOpenMs: openMs
        )
        return ok(out)
      } catch {
        return err(JSONRPCStandardErrorCode.invalidParams, "open failed: \(error)")
      }

    case TurboDraftMethod.sessionReload:
      do {
        let params = try (req.params ?? .object([:])).decode(SessionReloadParams.self)
        guard let editorSession = sessionsById[params.sessionId] else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "Invalid sessionId")
        }
        touchSession(params.sessionId)
        _ = try? await editorSession.applyExternalDiskChange()
        guard let info = await editorSession.currentInfo() else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "No session")
        }
        return ok(SessionReloadResult(content: info.content, revision: info.diskRevision))
      } catch {
        return err(JSONRPCStandardErrorCode.invalidParams, "reload failed: \(error)")
      }

    case TurboDraftMethod.sessionWaitForRevision:
      do {
        let params = try (req.params ?? .object([:])).decode(SessionWaitForRevisionParams.self)
        guard let editorSession = sessionsById[params.sessionId] else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "Invalid sessionId")
        }
        touchSession(params.sessionId)

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

    case TurboDraftMethod.sessionSave:
      do {
        let params = try (req.params ?? .object([:])).decode(SessionSaveParams.self)
        let saveT0 = nowMs()
        guard let editorSession = sessionsById[params.sessionId] else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "Invalid sessionId")
        }
        touchSession(params.sessionId)
        // Optimistic concurrency: reject stale saves unless force is true.
        if let baseRev = params.baseRevision, params.force != true {
          if let info = await editorSession.currentInfo(), info.diskRevision != baseRev {
            return err(JSONRPCStandardErrorCode.invalidRequest, "baseRevision mismatch (stale save)")
          }
        }
        // Session-bound save: ignore params.path and only save current session content.
        await editorSession.updateBufferContent(params.content)
        let _ = try await editorSession.autosave(reason: "rpc_save")
        let saveMs = nowMs() - saveT0
        if let info = await editorSession.currentInfo() {
          return ok(SessionSaveResult(ok: true, revision: info.diskRevision, serverSaveMs: saveMs))
        }
        return err(JSONRPCStandardErrorCode.invalidRequest, "No session")
      } catch {
        return err(JSONRPCStandardErrorCode.invalidParams, "save failed: \(error)")
      }

    case TurboDraftMethod.sessionClose:
      do {
        let params = try (req.params ?? .object([:])).decode(SessionCloseParams.self)
        let removedSession = sessionsById.removeValue(forKey: params.sessionId)
        windowsById.removeValue(forKey: params.sessionId)
        sessionPathById.removeValue(forKey: params.sessionId)
        sessionLastTouchedById.removeValue(forKey: params.sessionId)
        if let removedSession {
          await removedSession.markClosed()
        }
        return ok(SessionCloseResult(ok: removedSession != nil))
      } catch {
        return err(JSONRPCStandardErrorCode.invalidParams, "close failed: \(error)")
      }

    case TurboDraftMethod.sessionWait:
      do {
        let params = try (req.params ?? .object([:])).decode(SessionWaitParams.self)
        guard let editorSession = sessionsById[params.sessionId] else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "Invalid sessionId")
        }
        touchSession(params.sessionId)
        let closed = await editorSession.waitUntilClosed(timeoutMs: params.timeoutMs)
        if closed {
          sessionsById.removeValue(forKey: params.sessionId)
          windowsById.removeValue(forKey: params.sessionId)
          sessionPathById.removeValue(forKey: params.sessionId)
          sessionLastTouchedById.removeValue(forKey: params.sessionId)
        }
        return ok(SessionWaitResult(reason: closed ? "userClosed" : "timeout"))
      } catch {
        return err(JSONRPCStandardErrorCode.invalidParams, "wait failed: \(error)")
      }

    case TurboDraftMethod.benchMetrics:
      do {
        let params = try (req.params ?? .object([:])).decode(BenchMetricsParams.self)
        guard let editorSession = sessionsById[params.sessionId] else {
          return err(JSONRPCStandardErrorCode.invalidRequest, "Invalid sessionId")
        }
        touchSession(params.sessionId)
        // Collect typing latencies from the editor view controller.
        let wc = windowsById[params.sessionId]
        let latencies = wc?.typingLatencySamples ?? []
        let openToReadyMs = wc?.sessionOpenToReadyMs
        let historyStats = await editorSession.historyStats()
        // Query process memory via mach_task_info.
        let memBytes = processResidentBytes()
        return ok(BenchMetricsResult(
          typingLatencySamples: latencies,
          memoryResidentBytes: memBytes,
          sessionOpenToReadyMs: openToReadyMs,
          historySnapshotCount: historyStats.snapshotCount,
          historySnapshotBytes: Int64(historyStats.totalBytes),
          stylerCacheEntryCount: wc?.stylerCacheEntryCount,
          stylerCacheLimit: wc?.stylerCacheLimit
        ))
      } catch {
        return err(JSONRPCStandardErrorCode.invalidParams, "benchMetrics failed: \(error)")
      }

    case TurboDraftMethod.appQuit:
      Task { @MainActor in
        // Give the JSON-RPC response a chance to flush before terminating.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await self.performGracefulShutdown()
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
    appMenu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(gracefulQuit(_:)), keyEquivalent: "q"))
    if startHidden {
      let forceQuitItem = NSMenuItem(title: "Force Quit \(appName)", action: #selector(forceQuit(_:)), keyEquivalent: "q")
      forceQuitItem.keyEquivalentModifierMask = [.command, .option]
      appMenu.addItem(forceQuitItem)
    }

    // File menu
    let fileItem = NSMenuItem()
    fileItem.title = "File"
    main.addItem(fileItem)
    let fileMenu = NSMenu(title: "File")
    fileItem.submenu = fileMenu
    let submitClose = NSMenuItem(title: "Submit and Close", action: #selector(submitAndClose(_:)), keyEquivalent: "\r")
    submitClose.keyEquivalentModifierMask = [.command]
    submitClose.target = self
    fileMenu.addItem(submitClose)
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
    editMenu.addItem(.separator())
    let find = NSMenuItem(title: "Find…", action: #selector(showFind(_:)), keyEquivalent: "f")
    find.target = self
    find.keyEquivalentModifierMask = [.command]
    editMenu.addItem(find)
    let findNext = NSMenuItem(title: "Find Next", action: #selector(findNext(_:)), keyEquivalent: "g")
    findNext.target = self
    findNext.keyEquivalentModifierMask = [.command]
    editMenu.addItem(findNext)
    let findPrev = NSMenuItem(title: "Find Previous", action: #selector(findPrevious(_:)), keyEquivalent: "g")
    findPrev.target = self
    findPrev.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(findPrev)
    let useSelection = NSMenuItem(title: "Use Selection for Find", action: #selector(useSelectionForFind(_:)), keyEquivalent: "e")
    useSelection.target = self
    useSelection.keyEquivalentModifierMask = [.command]
    editMenu.addItem(useSelection)
    let replace = NSMenuItem(title: "Replace…", action: #selector(showReplace(_:)), keyEquivalent: "f")
    replace.target = self
    replace.keyEquivalentModifierMask = [.command, .option]
    editMenu.addItem(replace)
    let replaceNext = NSMenuItem(title: "Replace Next", action: #selector(replaceNext(_:)), keyEquivalent: "")
    replaceNext.target = self
    editMenu.addItem(replaceNext)
    let replaceAll = NSMenuItem(title: "Replace All", action: #selector(replaceAll(_:)), keyEquivalent: "")
    replaceAll.target = self
    editMenu.addItem(replaceAll)

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
    func addThemeItem(title: String, value: TurboDraftConfig.ThemeMode) {
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
    func addModeItem(title: String, value: TurboDraftConfig.EditorMode) {
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

    let colorThemeParent = NSMenuItem(title: "Color Theme", action: nil, keyEquivalent: "")
    let colorThemeMenu = NSMenu(title: "Color Theme")
    let resolvedId = cfg.colorTheme
    let builtIn = EditorColorTheme.builtInThemes
    let custom = colorThemes.filter { ct in !builtIn.contains(where: { $0.id == ct.id }) }
    for ct in builtIn {
      let item = NSMenuItem(title: ct.displayName, action: #selector(selectColorTheme(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = ct.id
      item.state = (ct.id == resolvedId) ? .on : .off
      item.tag = 903
      colorThemeMenu.addItem(item)
    }
    if !custom.isEmpty {
      colorThemeMenu.addItem(.separator())
      for ct in custom {
        let item = NSMenuItem(title: ct.displayName, action: #selector(selectColorTheme(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ct.id
        item.state = (ct.id == resolvedId) ? .on : .off
        item.tag = 903
        colorThemeMenu.addItem(item)
      }
    }
    colorThemeParent.submenu = colorThemeMenu
    viewMenu.addItem(colorThemeParent)

    viewMenu.addItem(.separator())

    let fontSizeParent = NSMenuItem(title: "Font Size", action: nil, keyEquivalent: "")
    let fontSizeMenu = NSMenu(title: "Font Size")
    for sz in [11, 12, 13, 14, 15, 16, 18, 20] {
      let item = NSMenuItem(title: "\(sz)", action: #selector(selectFontSize(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = sz
      item.state = (cfg.fontSize == sz) ? .on : .off
      item.tag = 904
      fontSizeMenu.addItem(item)
    }
    fontSizeParent.submenu = fontSizeMenu
    viewMenu.addItem(fontSizeParent)

    let fontFamilyParent = NSMenuItem(title: "Font Family", action: nil, keyEquivalent: "")
    let fontFamilyMenu = NSMenu(title: "Font Family")
    let fontPresets: [(title: String, family: String)] = [
      ("System Mono", "system"),
      ("Menlo", "Menlo"),
      ("SF Mono", "SF Mono"),
      ("JetBrains Mono", "JetBrains Mono NL"),
      ("Fira Code", "Fira Code"),
    ]
    for preset in fontPresets {
      let item = NSMenuItem(title: preset.title, action: #selector(selectFontFamily(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = preset.family
      item.state = (cfg.fontFamily == preset.family) ? .on : .off
      item.tag = 905
      fontFamilyMenu.addItem(item)
    }
    fontFamilyParent.submenu = fontFamilyMenu
    viewMenu.addItem(fontFamilyParent)

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
    improve.keyEquivalentModifierMask = [.command]
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
        case .claude: return "Claude CLI"
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
    persistConfig(context: "togglePromptEngineer")
  }

  @MainActor @objc private func improvePrompt(_ sender: NSMenuItem) {
    activeWindowController()?.runPromptEngineer()
  }

  @MainActor @objc private func showFind(_ sender: NSMenuItem) {
    activeWindowController()?.showFind(replace: false)
  }

  @MainActor @objc private func showReplace(_ sender: NSMenuItem) {
    activeWindowController()?.showFind(replace: true)
  }

  @MainActor @objc private func findNext(_ sender: NSMenuItem) {
    activeWindowController()?.findNext()
  }

  @MainActor @objc private func findPrevious(_ sender: NSMenuItem) {
    activeWindowController()?.findPrevious()
  }

  @MainActor @objc private func useSelectionForFind(_ sender: NSMenuItem) {
    activeWindowController()?.useSelectionForFind()
  }

  @MainActor @objc private func replaceNext(_ sender: NSMenuItem) {
    activeWindowController()?.replaceNext()
  }

  @MainActor @objc private func replaceAll(_ sender: NSMenuItem) {
    activeWindowController()?.replaceAll()
  }

  @MainActor @objc private func submitAndClose(_ sender: NSMenuItem) {
    activeWindowController()?.window?.performClose(nil)
  }

  @MainActor @objc private func restorePreviousBuffer(_ sender: NSMenuItem) {
    activeWindowController()?.restorePreviousBuffer()
  }

  private func sanitizeReasoningForModel(_ model: String) {
    let effort = PromptEngineerPrompts.effectiveReasoningEffort(
      model: model,
      requested: cfg.agent.reasoningEffort.rawValue
    )
    if effort != cfg.agent.reasoningEffort.rawValue {
      if let adjusted = TurboDraftConfig.Agent.ReasoningEffort(rawValue: effort) {
        cfg.agent.reasoningEffort = adjusted
      }
    }
  }

  @MainActor @objc private func selectAgentModel(_ sender: NSMenuItem) {
    guard let model = sender.representedObject as? String else { return }
    cfg.agent.model = model
    sanitizeReasoningForModel(model)
    sender.menu?.items.forEach {
      if $0.action == #selector(selectAgentModel(_:)) {
        $0.state = .off
      }
    }
    sender.state = .on
    applyAgentConfigToAllWindows()
    persistConfig(context: "selectAgentModel")
  }

  @MainActor @objc private func selectCustomAgentModel(_ sender: NSMenuItem) {
    let alert = NSAlert()
    alert.messageText = "Set Model"
    alert.informativeText = "Enter any model id supported by your CLI backend (Codex or Claude)."
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
    sanitizeReasoningForModel(model)
    applyAgentConfigToAllWindows()
    persistConfig(context: "selectCustomAgentModel")
    installMenu()
  }

  @MainActor @objc private func selectThemeMode(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = TurboDraftConfig.ThemeMode(rawValue: raw)
    else { return }
    cfg.theme = v
    sender.menu?.items.filter { $0.tag == 901 }.forEach { $0.state = .off }
    sender.state = .on
    applyThemeToAllWindows()
    persistConfig(context: "selectThemeMode")
  }

  @MainActor @objc private func selectEditorMode(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = TurboDraftConfig.EditorMode(rawValue: raw)
    else { return }
    cfg.editorMode = v
    sender.menu?.items.filter { $0.tag == 902 }.forEach { $0.state = .off }
    sender.state = .on
    applyEditorModeToAllWindows()
    persistConfig(context: "selectEditorMode")
  }

  @MainActor @objc private func selectColorTheme(_ sender: NSMenuItem) {
    guard let themeId = sender.representedObject as? String else { return }
    cfg.colorTheme = themeId
    sender.menu?.items.filter { $0.tag == 903 }.forEach { $0.state = .off }
    sender.state = .on
    applyColorThemeToAllWindows()
    persistConfig(context: "selectColorTheme")
  }

  private func applyColorThemeToAllWindows() {
    let resolved = EditorColorTheme.resolve(id: cfg.colorTheme, from: colorThemes)
    for wc in allWindowControllers {
      wc.setColorTheme(resolved)
    }
  }

  @MainActor @objc private func selectFontSize(_ sender: NSMenuItem) {
    guard let sz = sender.representedObject as? Int else { return }
    cfg.fontSize = sz
    sender.menu?.items.filter { $0.tag == 904 }.forEach { $0.state = .off }
    sender.state = .on
    applyFontToAllWindows()
    persistConfig(context: "selectFontSize")
  }

  @MainActor @objc private func selectFontFamily(_ sender: NSMenuItem) {
    guard let family = sender.representedObject as? String else { return }
    cfg.fontFamily = family
    sender.menu?.items.filter { $0.tag == 905 }.forEach { $0.state = .off }
    sender.state = .on
    applyFontToAllWindows()
    persistConfig(context: "selectFontFamily")
  }

  private func applyFontToAllWindows() {
    for wc in allWindowControllers {
      wc.setFont(family: cfg.fontFamily, size: cfg.fontSize)
    }
  }

  @MainActor @objc private func selectPromptProfile(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = TurboDraftConfig.Agent.PromptProfile(rawValue: raw)
    else { return }
    cfg.agent.promptProfile = v
    sender.menu?.items.forEach { $0.state = .off }
    sender.state = .on
    applyAgentConfigToAllWindows()
    persistConfig(context: "selectPromptProfile")
  }

  @MainActor @objc private func selectAgentBackend(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = TurboDraftConfig.Agent.Backend(rawValue: raw)
    else { return }
    let oldBackend = cfg.agent.backend
    cfg.agent.backend = v

    // Auto-switch command and model when crossing between Codex and Claude backends.
    if v == .claude, oldBackend != .claude {
      if cfg.agent.command == "codex" { cfg.agent.command = "claude" }
      if !cfg.agent.model.hasPrefix("claude-") { cfg.agent.model = "claude-sonnet-4-6" }
    } else if v != .claude, oldBackend == .claude {
      if cfg.agent.command == "claude" { cfg.agent.command = "codex" }
      if cfg.agent.model.hasPrefix("claude-") { cfg.agent.model = "gpt-5.3-codex-spark" }
    }

    sender.menu?.items.forEach { $0.state = .off }
    sender.state = .on
    applyAgentConfigToAllWindows()
    persistConfig(context: "selectAgentBackend")
    installMenu()
  }

  @MainActor @objc private func selectReasoningEffort(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = TurboDraftConfig.Agent.ReasoningEffort(rawValue: raw)
    else { return }
    cfg.agent.reasoningEffort = v
    sender.menu?.items.forEach { $0.state = .off }
    sender.state = .on
    applyAgentConfigToAllWindows()
    persistConfig(context: "selectReasoningEffort")
  }

  @MainActor @objc private func selectReasoningSummary(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = TurboDraftConfig.Agent.ReasoningSummary(rawValue: raw)
    else { return }
    cfg.agent.reasoningSummary = v
    sender.menu?.items.forEach { $0.state = .off }
    sender.state = .on
    applyAgentConfigToAllWindows()
    persistConfig(context: "selectReasoningSummary")
  }

  @MainActor @objc private func selectWebSearchMode(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let v = TurboDraftConfig.Agent.WebSearchMode(rawValue: raw)
    else { return }
    cfg.agent.webSearch = v
    sender.menu?.items.forEach { $0.state = .off }
    sender.state = .on
    applyAgentConfigToAllWindows()
    persistConfig(context: "selectWebSearchMode")
  }

  private func cleanUpStaleTempFiles() {
    let fm = FileManager.default

    // Clean legacy temp files unconditionally.
    let tmpDir = NSTemporaryDirectory()
    if let contents = try? fm.contentsOfDirectory(atPath: tmpDir) {
      let prefixes = ["turbodraft-img-", "turbodraft-codex-"]
      for name in contents where prefixes.contains(where: { name.hasPrefix($0) }) {
        try? fm.removeItem(atPath: tmpDir + "/" + name)
      }
    }

    // Clean stable image dir — only files older than 1 hour (active sessions may need recent ones).
    let imagesDir = fm.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/TurboDraft/images", isDirectory: true)
    if let contents = try? fm.contentsOfDirectory(atPath: imagesDir.path) {
      let cutoff = Date().addingTimeInterval(-3600)
      for name in contents where name.hasPrefix("turbodraft-img-") {
        let path = imagesDir.appendingPathComponent(name).path
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let modified = attrs[.modificationDate] as? Date,
           modified < cutoff {
          try? fm.removeItem(atPath: path)
        }
      }
    }
  }

  private func nowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
  }

  private func processResidentBytes() -> Int64 {
    var taskInfo = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: taskInfo) / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &taskInfo) { ptr in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Int64(taskInfo.resident_size)
  }

  private func appendLatencyRecord(_ payload: [String: Any]) {
    guard let file = telemetryFileURL else { return }
    do {
      var record = payload
      record["ts"] = Self.telemetryDateFormatter.string(from: Date())
      let data = try JSONSerialization.data(withJSONObject: record, options: [])
      let line = data + Data([0x0A])
      if telemetryHandle == nil {
        telemetryHandle = try? FileHandle(forWritingTo: file)
      }
      if let fh = telemetryHandle {
        try fh.seekToEnd()
        try fh.write(contentsOf: line)
      } else {
        // First record fallback if file doesn't exist yet.
        try line.write(to: file, options: [.atomic])
        telemetryHandle = try? FileHandle(forWritingTo: file)
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
    case let n as NSNumber:
      // CFBooleanGetTypeID() is the only reliable way to distinguish
      // JSON true/false from integers — NSNumber(1) matches `as Bool`.
      if CFGetTypeID(n) == CFBooleanGetTypeID() {
        return .bool(n.boolValue)
      }
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
