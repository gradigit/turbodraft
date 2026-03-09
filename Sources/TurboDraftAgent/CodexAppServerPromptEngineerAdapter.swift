import Darwin
import Foundation
import TurboDraftCore

public enum CodexAppServerPromptEngineerError: Error, CustomStringConvertible {
  case commandNotFound
  case spawnFailed(errno: Int32)
  case writeFailed(errno: Int32)
  case timedOut
  case serverClosed
  case protocolError(String)
  case invalidOutput([String])
  case nonZeroExit(Int32, String)
  case missingAgentMessage
  case outputTooLarge

  public var description: String {
    switch self {
    case .commandNotFound: return "Codex CLI not found"
    case let .spawnFailed(e): return "Spawn failed errno=\(e)"
    case let .writeFailed(e): return "Write failed errno=\(e)"
    case .timedOut: return "Timed out"
    case .serverClosed: return "App server closed unexpectedly"
    case let .protocolError(s): return "Protocol error: \(s)"
    case let .invalidOutput(reasons): return "Invalid output (\(reasons.joined(separator: ",")))"
    case let .nonZeroExit(code, msg): return "Non-zero exit: \(code) (\(msg))"
    case .missingAgentMessage: return "Missing agent message"
    case .outputTooLarge: return "Output too large"
    }
  }
}

protocol CodexAppServerTransport: AnyObject {
  var isAlive: Bool { get }
  func shutdown()
  func ensureInitialized(timeoutMs: Int) throws
  func sendRequest(method: String, params: [String: Any]) throws -> Int
  func sendNotification(method: String, params: [String: Any]) throws
  func waitForResponse(id: Int, timeoutMs: Int) throws -> [String: Any]
  func readNextMessage(timeoutMs: Int) throws -> [String: Any]?
}

/// Prompt engineering agent powered by Codex App Server (`codex app-server`).
///
/// This adapter keeps a warm app-server process for low per-turn latency.
/// Transport is stdio with JSON Lines messages (one JSON object per line).
public final class CodexAppServerPromptEngineerAdapter: AgentAdapting, AgentSidebarStreamingChatAdapting, AgentRouteReporting, @unchecked Sendable {
  private let command: String
  private let model: String
  private let timeoutMs: Int
  private let webSearch: String
  private let promptProfile: String
  private let draftingPreset: String
  private let reasoningEffort: String
  private let reasoningSummary: String
  private let extraArgs: [String]
  private let environmentOverrides: [String: String]
  private let maxOutputBytes: Int
  private let routeLabel: String
  private let serverFactory: (() throws -> any CodexAppServerTransport)?
  private let routeLabelLock = NSLock()
  private var _lastRouteLabel: String = "uninitialized"

  private let queue = DispatchQueue(label: "TurboDraft.CodexAppServerPromptEngineer")
  private var server: (any CodexAppServerTransport)?
  private var chatSession: ChatSession?

  private struct ChatSession {
    let threadId: String
    let cwd: String
  }

  public convenience init(
    command: String = "codex",
    model: String = "gpt-5.3-codex-spark",
    timeoutMs: Int = 60_000,
    webSearch: String = "disabled",
    promptProfile: String = "large_opt",
    draftingPreset: String = "legacy",
    reasoningEffort: String = "low",
    reasoningSummary: String = "auto",
    extraArgs: [String] = [],
    environmentOverrides: [String: String] = [:],
    maxOutputBytes: Int = 2 * 1024 * 1024,
    routeLabel: String? = nil
  ) {
    self.init(
      command: command,
      model: model,
      timeoutMs: timeoutMs,
      webSearch: webSearch,
      promptProfile: promptProfile,
      draftingPreset: draftingPreset,
      reasoningEffort: reasoningEffort,
      reasoningSummary: reasoningSummary,
      extraArgs: extraArgs,
      environmentOverrides: environmentOverrides,
      maxOutputBytes: maxOutputBytes,
      routeLabel: routeLabel,
      serverFactory: nil
    )
  }

  init(
    command: String = "codex",
    model: String = "gpt-5.3-codex-spark",
    timeoutMs: Int = 60_000,
    webSearch: String = "disabled",
    promptProfile: String = "large_opt",
    draftingPreset: String = "legacy",
    reasoningEffort: String = "low",
    reasoningSummary: String = "auto",
    extraArgs: [String] = [],
    environmentOverrides: [String: String] = [:],
    maxOutputBytes: Int = 2 * 1024 * 1024,
    routeLabel: String? = nil,
    serverFactory: (() throws -> any CodexAppServerTransport)?
  ) {
    self.command = command
    self.model = model
    self.timeoutMs = timeoutMs
    self.webSearch = webSearch
    self.promptProfile = promptProfile
    self.draftingPreset = draftingPreset
    self.reasoningEffort = reasoningEffort
    self.reasoningSummary = reasoningSummary
    self.extraArgs = extraArgs
    self.environmentOverrides = environmentOverrides
    self.maxOutputBytes = maxOutputBytes
    self.serverFactory = serverFactory
    if let explicit = routeLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
      self.routeLabel = explicit
    } else if environmentOverrides["TURBODRAFT_PROVIDER_BACKEND"] == "litellm" {
      self.routeLabel = "codex app-server (litellm)"
    } else {
      self.routeLabel = "codex app-server (direct)"
    }
  }

  public var lastRouteLabel: String {
    routeLabelLock.lock()
    defer { routeLabelLock.unlock() }
    return _lastRouteLabel
  }

  deinit {
    let s = server
    queue.async {
      s?.shutdown()
    }
  }

  public func draft(prompt: String, instruction: String, images: [URL], cwd: String?) async throws -> String {
    try await withCheckedThrowingContinuation { cont in
      queue.async {
        do {
          let out = try self.draftSync(prompt: prompt, instruction: instruction, images: images, cwd: cwd)
          self.setLastRoute(self.routeLabel)
          cont.resume(returning: out)
        } catch {
          self.setLastRoute("\(self.routeLabel) (failed)")
          cont.resume(throwing: error)
        }
      }
    }
  }

  public func chat(message: String, draft: String, images: [URL], cwd: String?) async throws -> String {
    try await chat(message: message, draft: draft, images: images, cwd: cwd, onDelta: { _ in })
  }

  public func chat(
    message: String,
    draft: String,
    images: [URL],
    cwd: String?,
    onDelta: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    try await withCheckedThrowingContinuation { cont in
      queue.async {
        do {
          let out = try self.chatSync(
            message: message,
            draft: draft,
            images: images,
            cwd: cwd,
            onDelta: onDelta
          )
          self.setLastRoute("\(self.routeLabel) chat")
          cont.resume(returning: out)
        } catch {
          self.setLastRoute("\(self.routeLabel) chat (failed)")
          cont.resume(throwing: error)
        }
      }
    }
  }

  public func resetChatSession() {
    queue.async {
      self.chatSession = nil
    }
  }

  private func runTurn(
    s: any CodexAppServerTransport,
    threadId: String,
    userText: String,
    effortOverride: String?,
    images: [URL],
    onDelta: (@Sendable (String) -> Void)? = nil
  ) throws -> String {
    var inputItems: [[String: Any]] = [["type": "text", "text": userText]]
    let maxImageBytes = 20 * 1024 * 1024  // 20 MB limit
    for imgURL in images {
      if let data = try? Data(contentsOf: imgURL) {
        if data.count > maxImageBytes { continue }
        inputItems.append([
          "type": "image_url",
          "image_url": ["url": "data:image/png;base64,\(data.base64EncodedString())"],
        ])
      }
    }
    var turnParams: [String: Any] = [
      "threadId": threadId,
      "input": inputItems,
    ]
    if let eff = effortOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !eff.isEmpty {
      turnParams["effort"] = eff
    }
    if !reasoningSummary.isEmpty {
      turnParams["summary"] = reasoningSummary
    }

    let turnReq = try s.sendRequest(method: "turn/start", params: turnParams)
    let turnResp = try s.waitForResponse(id: turnReq, timeoutMs: 30_000)
    let turnId = try extractString(turnResp, ["result", "turn", "id"]) ?? ""
    if turnId.isEmpty {
      throw CodexAppServerPromptEngineerError.protocolError("turn/start missing turn.id")
    }

    let endByNs = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeoutMs)) * 1_000_000
    var agentText = ""
    var sawContentDelta = false

    while DispatchTime.now().uptimeNanoseconds < endByNs {
      let remainingMs = Int((endByNs - DispatchTime.now().uptimeNanoseconds) / 1_000_000)
      guard let msg = try s.readNextMessage(timeoutMs: max(10, min(500, remainingMs))) else {
        continue
      }

      if let method = msg["method"] as? String, let params = msg["params"] as? [String: Any] {
        if let delta = deltaText(method: method, params: params, turnId: turnId, sawContentDelta: &sawContentDelta)
        {
          if agentText.count + delta.utf8.count <= maxOutputBytes {
            agentText += delta
            onDelta?(delta)
          }
          continue
        }

        if method == "item/completed",
           let pTurnId = anyTurnID(in: params),
           pTurnId == turnId,
           let item = params["item"] as? [String: Any],
           let type = item["type"] as? String,
           type == "agentMessage",
           let text = item["text"] as? String
        {
          agentText = text
          let phase = (item["phase"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          if let phase, !phase.isEmpty, phase != "final_answer" {
            continue
          }
          return try validatedAgentText(agentText)
        }

        if method == "turn/completed",
           let pThreadId = params["threadId"] as? String,
           pThreadId == threadId,
           let turn = params["turn"] as? [String: Any],
           let id = turn["id"] as? String,
           id == turnId
        {
          let status = (turn["status"] as? String) ?? ""
          if status == "completed" {
            return try validatedAgentText(agentText)
          }
          let err = turn["error"] as? [String: Any]
          throw CodexAppServerPromptEngineerError.protocolError("turn status=\(status) error=\(String(describing: err))")
        }

        if method == "error",
           let pTurnId = anyTurnID(in: params),
           pTurnId == turnId
        {
          let willRetry = (params["willRetry"] as? Bool) ?? false
          if willRetry {
            continue
          }
          let err = params["error"] as? [String: Any]
          throw CodexAppServerPromptEngineerError.protocolError("server error: \(String(describing: err))")
        }
      }
    }

    throw CodexAppServerPromptEngineerError.timedOut
  }

  private func chatSync(
    message: String,
    draft: String,
    images: [URL],
    cwd: String?,
    onDelta: @escaping @Sendable (String) -> Void
  ) throws -> String {
    let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMessage.isEmpty else { return "" }

    let s = try ensureServer()
    try s.ensureInitialized(timeoutMs: 10_000)

    let effectiveCwd = cwd ?? FileManager.default.currentDirectoryPath
    let threadId = try ensureChatThread(s: s, cwd: effectiveCwd)
    let userText = PromptEngineerPrompts.draftingChatUserTurn(draft: draft, message: trimmedMessage)

    do {
      return try runTurn(
        s: s,
        threadId: threadId,
        userText: userText,
        effortOverride: PromptEngineerPrompts.effectiveReasoningEffort(model: model, requested: reasoningEffort),
        images: images,
        onDelta: onDelta
      )
    } catch CodexAppServerPromptEngineerError.serverClosed {
      chatSession = nil
      throw CodexAppServerPromptEngineerError.serverClosed
    } catch {
      // If thread/session drifted, retry once on a fresh chat thread.
      chatSession = nil
      let retryThread = try ensureChatThread(s: s, cwd: effectiveCwd)
      return try runTurn(
        s: s,
        threadId: retryThread,
        userText: userText,
        effortOverride: PromptEngineerPrompts.effectiveReasoningEffort(model: model, requested: reasoningEffort),
        images: images,
        onDelta: onDelta
      )
    }
  }

  private func draftSync(prompt: String, instruction: String, images: [URL], cwd: String?) throws -> String {
    let s = try ensureServer()
    try s.ensureInitialized(timeoutMs: 10_000)
    let profile = PromptEngineerPrompts.Profile(rawValue: promptProfile) ?? .largeOpt
    let preset = PromptEngineerPrompts.DraftingPreset(rawValue: draftingPreset) ?? .coding
    let preamble = PromptEngineerPrompts.preamble(for: profile)

    let cwd = cwd ?? FileManager.default.currentDirectoryPath
    let threadParams: [String: Any] = [
      "model": model,
      "modelProvider": "openai",
      "approvalPolicy": "never",
      "sandbox": "read-only",
      "ephemeral": true,
      "cwd": cwd,
      "baseInstructions": preamble,
      "developerInstructions": preamble,
      "personality": "pragmatic",
    ]

    let threadReq = try s.sendRequest(method: "thread/start", params: threadParams)
    let threadResp = try s.waitForResponse(id: threadReq, timeoutMs: 30_000)
    let threadId = try extractString(threadResp, ["result", "thread", "id"]) ?? ""
    if threadId.isEmpty {
      throw CodexAppServerPromptEngineerError.protocolError("thread/start missing thread.id")
    }

    let baseEff = PromptEngineerPrompts.effectiveReasoningEffort(model: model, requested: reasoningEffort)
    let userText = PromptEngineerPrompts.userTurnText(prompt: prompt, instruction: instruction, preset: preset)
    let out1Raw = try runTurn(
      s: s,
      threadId: threadId,
      userText: userText,
      effortOverride: baseEff,
      images: images,
      onDelta: nil
    )
    let out1 = PromptEngineerOutputGuard.normalize(output: out1Raw).trimmingCharacters(in: .whitespacesAndNewlines)
    let check = PromptEngineerOutputGuard.check(draft: prompt, output: out1, preset: preset)
    if !check.needsRepair {
      return out1
    }

    let repairEff = PromptEngineerOutputGuard.suggestedRepairEffort(baseEff)
    let out2Raw = try runTurn(
      s: s,
      threadId: threadId,
      userText: PromptEngineerPrompts.userTurnText(
        prompt: prompt,
        instruction: PromptEngineerPrompts.repairInstruction,
        preset: preset
      ),
      effortOverride: repairEff.isEmpty ? baseEff : repairEff,
      images: [],
      onDelta: nil
    )
    let out2 = PromptEngineerOutputGuard.normalize(output: out2Raw).trimmingCharacters(in: .whitespacesAndNewlines)
    let check2 = PromptEngineerOutputGuard.check(draft: prompt, output: out2, preset: preset)
    if preset == .legacy, check2.needsRepair {
      throw CodexAppServerPromptEngineerError.invalidOutput(check2.reasons)
    }
    if check2.reasons.contains("missing_execution_structure")
      || check2.reasons.contains("missing_exploration_structure")
      || check2.reasons.contains("missing_task_planning_instruction")
      || check2.reasons.contains("missing_pivot_language_contract")
      || check2.reasons.contains("contains_internal_agent_role_names")
      || check2.reasons.contains("missing_actionable_numbered_step_section")
    {
      throw CodexAppServerPromptEngineerError.invalidOutput(check2.reasons)
    }
    return out2
  }

  private func ensureChatThread(s: any CodexAppServerTransport, cwd: String) throws -> String {
    if let session = chatSession, session.cwd == cwd {
      return session.threadId
    }

    let params: [String: Any] = [
      "model": model,
      "modelProvider": "openai",
      "approvalPolicy": "never",
      "sandbox": "read-only",
      "ephemeral": true,
      "cwd": cwd,
      "baseInstructions": PromptEngineerPrompts.draftingChatSystemPreamble,
      "developerInstructions": PromptEngineerPrompts.draftingChatSystemPreamble,
      "personality": "pragmatic",
    ]
    let req = try s.sendRequest(method: "thread/start", params: params)
    let resp = try s.waitForResponse(id: req, timeoutMs: 30_000)
    let threadId = try extractString(resp, ["result", "thread", "id"]) ?? ""
    if threadId.isEmpty {
      throw CodexAppServerPromptEngineerError.protocolError("chat thread/start missing thread.id")
    }
    let session = ChatSession(threadId: threadId, cwd: cwd)
    chatSession = session
    return session.threadId
  }

  private func ensureServer() throws -> any CodexAppServerTransport {
    if let existing = server, existing.isAlive {
      return existing
    }

    if let serverFactory {
      let created = try serverFactory()
      server = created
      chatSession = nil
      return created
    }

    guard let resolved = CommandResolver.resolveInPATH(command) else {
      throw CodexAppServerPromptEngineerError.commandNotFound
    }

    let args: [String] = {
      var out: [String] = [
        "app-server",
        "--listen",
        "stdio://",
        "-c",
        "web_search=\(webSearch)",
      ]

      // Allow passing additional `-c/--config` overrides to app-server via agent.args.
      out.append(contentsOf: filterAppServerArgs(extraArgs))
      return out
    }()

    let spawned = try ServerProcess.spawn(
      executablePath: resolved,
      arguments: args,
      environmentOverrides: environmentOverrides
    )
    server = spawned
    chatSession = nil
    return spawned
  }

  private func filterAppServerArgs(_ args: [String]) -> [String] {
    var out: [String] = []
    var i = 0
    while i < args.count {
      let a = args[i]
      if a == "-c" || a == "--config" || a == "--enable" || a == "--disable" {
        if i + 1 < args.count {
          out.append(a)
          out.append(args[i + 1])
          i += 2
          continue
        }
      }
      i += 1
    }
    return out
  }

  private func extractString(_ obj: Any, _ path: [String]) throws -> String? {
    var cur: Any = obj
    for k in path {
      guard let d = cur as? [String: Any], let v = d[k] else { return nil }
      cur = v
    }
    return cur as? String
  }

  private func anyTurnID(in params: [String: Any]) -> String? {
    if let turnId = params["turnId"] as? String { return turnId }
    if let turnId = params["turn_id"] as? String { return turnId }
    if let msg = params["msg"] as? [String: Any] {
      if let turnId = msg["turn_id"] as? String { return turnId }
      if let turnId = msg["turnId"] as? String { return turnId }
    }
    return nil
  }

  private func deltaText(
    method: String,
    params: [String: Any],
    turnId: String,
    sawContentDelta: inout Bool
  ) -> String? {
    if method == "item/agentMessage/delta",
       anyTurnID(in: params) == turnId,
       let delta = params["delta"] as? String
    {
      return delta
    }

    if method == "codex/event/agent_message_content_delta",
       anyTurnID(in: params) == turnId,
       let msg = params["msg"] as? [String: Any],
       let delta = msg["delta"] as? String
    {
      sawContentDelta = true
      return delta
    }

    if method == "codex/event/agent_message_delta",
       !sawContentDelta,
       anyTurnID(in: params) == turnId,
       let msg = params["msg"] as? [String: Any],
       let delta = msg["delta"] as? String
    {
      return delta
    }

    return nil
  }

  private func validatedAgentText(_ text: String) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      throw CodexAppServerPromptEngineerError.missingAgentMessage
    }
    if trimmed.utf8.count > maxOutputBytes {
      throw CodexAppServerPromptEngineerError.outputTooLarge
    }
    return trimmed
  }

  private func setLastRoute(_ value: String) {
    routeLabelLock.lock()
    _lastRouteLabel = value
    routeLabelLock.unlock()
  }

  // MARK: - ServerProcess

  final class ServerProcess: CodexAppServerTransport {
    let pid: pid_t
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private var buffer = Data()
    private var nextId: Int = 1
    private var initialized = false
    private var pendingMessages: [[String: Any]] = []

    init(pid: pid_t, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32) {
      self.pid = pid
      self.stdinFD = stdinFD
      self.stdoutFD = stdoutFD
      self.stderrFD = stderrFD
    }

    var isAlive: Bool {
      kill(pid, 0) == 0
    }

    static func spawn(
      executablePath: String,
      arguments: [String],
      environmentOverrides: [String: String] = [:]
    ) throws -> ServerProcess {
      var inFds: [Int32] = [0, 0]
      guard pipe(&inFds) == 0 else { throw CodexAppServerPromptEngineerError.spawnFailed(errno: errno) }
      var outFds: [Int32] = [0, 0]
      guard pipe(&outFds) == 0 else {
        close(inFds[0]); close(inFds[1])
        throw CodexAppServerPromptEngineerError.spawnFailed(errno: errno)
      }
      var errFds: [Int32] = [0, 0]
      guard pipe(&errFds) == 0 else {
        close(inFds[0]); close(inFds[1]); close(outFds[0]); close(outFds[1])
        throw CodexAppServerPromptEngineerError.spawnFailed(errno: errno)
      }

      setCloExec(inFds[0]); setCloExec(inFds[1])
      setCloExec(outFds[0]); setCloExec(outFds[1])
      setCloExec(errFds[0]); setCloExec(errFds[1])

      var actions: posix_spawn_file_actions_t? = nil
      posix_spawn_file_actions_init(&actions)
      defer { posix_spawn_file_actions_destroy(&actions) }

      posix_spawn_file_actions_adddup2(&actions, inFds[0], STDIN_FILENO)
      posix_spawn_file_actions_adddup2(&actions, outFds[1], STDOUT_FILENO)
      posix_spawn_file_actions_adddup2(&actions, errFds[1], STDERR_FILENO)

      posix_spawn_file_actions_addclose(&actions, inFds[1])
      posix_spawn_file_actions_addclose(&actions, outFds[0])
      posix_spawn_file_actions_addclose(&actions, errFds[0])
      posix_spawn_file_actions_addclose(&actions, inFds[0])
      posix_spawn_file_actions_addclose(&actions, outFds[1])
      posix_spawn_file_actions_addclose(&actions, errFds[1])

      var pid: pid_t = 0
      let argv = [executablePath] + arguments
      var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
      cArgs.append(nil)
      defer {
        for p in cArgs where p != nil { free(p) }
      }

      let execDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
      let baseEnv = CommandResolver.buildEnv(prependingToPath: execDir)
      let mergedEnv = SpawnEnvironment.merged(base: baseEnv, overrides: environmentOverrides)
      var cEnv: [UnsafeMutablePointer<CChar>?] = mergedEnv.map { strdup($0) }
      cEnv.append(nil)
      defer { for p in cEnv where p != nil { free(p) } }

      let rc = posix_spawn(&pid, executablePath, &actions, nil, &cArgs, &cEnv)
      if rc != 0 {
        close(inFds[0]); close(inFds[1]); close(outFds[0]); close(outFds[1]); close(errFds[0]); close(errFds[1])
        if rc == ENOENT {
          throw CodexAppServerPromptEngineerError.commandNotFound
        }
        throw CodexAppServerPromptEngineerError.spawnFailed(errno: Int32(rc))
      }

      close(inFds[0])
      close(outFds[1])
      close(errFds[1])

      setNonBlocking(outFds[0])

      // Drain stderr continuously so the child can't block on a full buffer.
      DispatchQueue.global(qos: .utility).async {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
          let n: Int = buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(errFds[0], base, raw.count)
          }
          if n > 0 { continue }
          break
        }
      }

      return ServerProcess(pid: pid, stdinFD: inFds[1], stdoutFD: outFds[0], stderrFD: errFds[0])
    }

    func shutdown() {
      _ = Darwin.close(stdinFD)
      _ = Darwin.close(stdoutFD)
      _ = Darwin.close(stderrFD)
      kill(pid, SIGTERM)
      var st: Int32 = 0
      _ = waitpid(pid, &st, 0)
    }

    func ensureInitialized(timeoutMs: Int) throws {
      if initialized { return }
      let params: [String: Any] = [
        "clientInfo": ["name": "TurboDraft", "version": "0.0.1"],
        "capabilities": ["experimentalApi": true],
      ]
      let reqId = try sendRequest(method: "initialize", params: params)
      _ = try waitForResponse(id: reqId, timeoutMs: timeoutMs)
      try sendNotification(method: "initialized", params: [:])
      initialized = true
    }

    func sendNotification(method: String, params: [String: Any]) throws {
      let obj: [String: Any] = ["method": method, "params": params]
      let data: Data
      do {
        data = try JSONSerialization.data(withJSONObject: obj, options: [])
      } catch {
        throw CodexAppServerPromptEngineerError.protocolError("failed to serialize notification: \(error)")
      }
      var frame = data
      frame.append(0x0A)
      do {
        try writeAll(fd: stdinFD, data: frame)
      } catch {
        throw CodexAppServerPromptEngineerError.writeFailed(errno: errno)
      }
    }

    func sendRequest(method: String, params: [String: Any]) throws -> Int {
      let id = nextId
      nextId += 1
      let obj: [String: Any] = ["id": id, "method": method, "params": params]
      let data: Data
      do {
        data = try JSONSerialization.data(withJSONObject: obj, options: [])
      } catch {
        throw CodexAppServerPromptEngineerError.protocolError("failed to serialize request: \(error)")
      }
      var frame = data
      frame.append(0x0A) // \n
      do {
        try writeAll(fd: stdinFD, data: frame)
      } catch {
        throw CodexAppServerPromptEngineerError.writeFailed(errno: errno)
      }
      return id
    }

    func waitForResponse(id: Int, timeoutMs: Int) throws -> [String: Any] {
      let endByNs = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeoutMs)) * 1_000_000
      while DispatchTime.now().uptimeNanoseconds < endByNs {
        let remainingMs = Int((endByNs - DispatchTime.now().uptimeNanoseconds) / 1_000_000)
        guard let msg = try readNextRawMessage(timeoutMs: max(10, min(500, remainingMs))) else {
          continue
        }
        if let msgId = msg["id"] as? Int, msgId == id {
          if let err = msg["error"] as? [String: Any] {
            let code = (err["code"] as? Int) ?? 1
            let message = (err["message"] as? String) ?? "request failed"
            throw CodexAppServerPromptEngineerError.nonZeroExit(Int32(code), message)
          }
          return msg
        }
        pendingMessages.append(msg)
      }
      throw CodexAppServerPromptEngineerError.timedOut
    }

    func readNextMessage(timeoutMs: Int) throws -> [String: Any]? {
      if !pendingMessages.isEmpty {
        return pendingMessages.removeFirst()
      }
      return try readNextRawMessage(timeoutMs: timeoutMs)
    }

    private func readNextRawMessage(timeoutMs: Int) throws -> [String: Any]? {
      let endByNs = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeoutMs)) * 1_000_000
      while DispatchTime.now().uptimeNanoseconds < endByNs {
        if let line = extractLine() {
          let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
          if trimmed.isEmpty { continue }
          guard let data = trimmed.data(using: .utf8) else { continue }
          guard let obj = try? JSONSerialization.jsonObject(with: data),
                let dict = obj as? [String: Any]
          else {
            continue
          }
          return dict
        }

        let remainingMs = Int((endByNs - DispatchTime.now().uptimeNanoseconds) / 1_000_000)
        var pfd = pollfd(fd: stdoutFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let r = poll(&pfd, 1, Int32(max(1, min(50, remainingMs))))
        if r > 0 {
          var buf = [UInt8](repeating: 0, count: 8192)
          let n: Int = buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(stdoutFD, base, raw.count)
          }
          if n > 0 {
            buffer.append(contentsOf: buf[0..<n])
            continue
          }
          if n == 0 {
            throw CodexAppServerPromptEngineerError.serverClosed
          }
          if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            continue
          }
          throw CodexAppServerPromptEngineerError.serverClosed
        }
      }
      return nil
    }

    private func extractLine() -> String? {
      if let nl = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer.prefix(upTo: nl)
        buffer.removeSubrange(buffer.startIndex...nl)
        return String(decoding: lineData, as: UTF8.self)
      }
      return nil
    }

  }
}
