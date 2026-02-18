import Darwin
import Foundation
import TurboDraftCore

public enum CodexAppServerPromptEngineerError: Error, CustomStringConvertible {
  case commandNotFound
  case spawnFailed(errno: Int32)
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

/// Prompt engineering agent powered by Codex App Server (`codex app-server`).
///
/// This adapter keeps a warm app-server process for low per-turn latency.
/// Transport is stdio with JSON Lines messages (one JSON object per line).
public final class CodexAppServerPromptEngineerAdapter: AgentAdapting, @unchecked Sendable {
  private let command: String
  private let model: String
  private let timeoutMs: Int
  private let webSearch: String
  private let promptProfile: String
  private let reasoningEffort: String
  private let reasoningSummary: String
  private let extraArgs: [String]
  private let maxOutputBytes: Int

  private let queue = DispatchQueue(label: "TurboDraft.CodexAppServerPromptEngineer")
  private var server: ServerProcess?

  public init(
    command: String = "codex",
    model: String = "gpt-5.3-codex-spark",
    timeoutMs: Int = 60_000,
    webSearch: String = "disabled",
    promptProfile: String = "large_opt",
    reasoningEffort: String = "low",
    reasoningSummary: String = "auto",
    extraArgs: [String] = [],
    maxOutputBytes: Int = 2 * 1024 * 1024
  ) {
    self.command = command
    self.model = model
    self.timeoutMs = timeoutMs
    self.webSearch = webSearch
    self.promptProfile = promptProfile
    self.reasoningEffort = reasoningEffort
    self.reasoningSummary = reasoningSummary
    self.extraArgs = extraArgs
    self.maxOutputBytes = maxOutputBytes
  }

  deinit {
    let s = server
    queue.async {
      s?.shutdown()
    }
  }

  public func draft(prompt: String, instruction: String) async throws -> String {
    try await withCheckedThrowingContinuation { cont in
      queue.async {
        do {
          cont.resume(returning: try self.draftSync(prompt: prompt, instruction: instruction))
        } catch {
          cont.resume(throwing: error)
        }
      }
    }
  }

  private func effectiveReasoningEffort(model: String) -> String {
    let e = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
    if e.isEmpty { return e }
    let m = model.lowercased()
    if m.contains("spark"), e == "minimal" {
      return "low"
    }
    if m.contains("gpt-5.3-codex"), e == "minimal" {
      return "none"
    }
    return e
  }

  private func runTurn(
    s: ServerProcess,
    threadId: String,
    prompt: String,
    instruction: String,
    effortOverride: String?
  ) throws -> String {
    let userText = PromptEngineerPrompts.userTurnText(prompt: prompt, instruction: instruction)
    var turnParams: [String: Any] = [
      "threadId": threadId,
      "input": [
        ["type": "text", "text": userText],
      ],
    ]
    if let eff = effortOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !eff.isEmpty {
      turnParams["effort"] = eff
    }
    if !reasoningSummary.isEmpty {
      turnParams["summary"] = reasoningSummary
    }

    let turnReq = s.sendRequest(method: "turn/start", params: turnParams)
    let turnResp = try s.waitForResponse(id: turnReq, timeoutMs: 30_000)
    let turnId = try extractString(turnResp, ["result", "turn", "id"]) ?? ""
    if turnId.isEmpty {
      throw CodexAppServerPromptEngineerError.protocolError("turn/start missing turn.id")
    }

    let endByNs = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeoutMs)) * 1_000_000
    var agentText = ""
    var sawFinalAgent = false

    while DispatchTime.now().uptimeNanoseconds < endByNs {
      let remainingMs = Int((endByNs - DispatchTime.now().uptimeNanoseconds) / 1_000_000)
      guard let msg = try s.readNextMessage(timeoutMs: max(10, min(500, remainingMs))) else {
        continue
      }

      if let method = msg["method"] as? String, let params = msg["params"] as? [String: Any] {
        if method == "item/agentMessage/delta",
           let pTurnId = params["turnId"] as? String,
           pTurnId == turnId,
           !sawFinalAgent,
           let delta = params["delta"] as? String
        {
          if agentText.count + delta.utf8.count <= maxOutputBytes {
            agentText += delta
          }
          continue
        }

        if method == "item/completed",
           let pTurnId = params["turnId"] as? String,
           pTurnId == turnId,
           let item = params["item"] as? [String: Any],
           let type = item["type"] as? String,
           type == "agentMessage",
           let text = item["text"] as? String
        {
          agentText = text
          sawFinalAgent = true
          continue
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
            let trimmed = agentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
              throw CodexAppServerPromptEngineerError.missingAgentMessage
            }
            if trimmed.utf8.count > maxOutputBytes {
              throw CodexAppServerPromptEngineerError.outputTooLarge
            }
            return trimmed
          }
          let err = turn["error"] as? [String: Any]
          throw CodexAppServerPromptEngineerError.protocolError("turn status=\(status) error=\(String(describing: err))")
        }

        if method == "error",
           let pTurnId = params["turnId"] as? String,
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

  private func draftSync(prompt: String, instruction: String) throws -> String {
    let s = try ensureServer()
    try s.ensureInitialized(timeoutMs: 10_000)
    let profile = PromptEngineerPrompts.Profile(rawValue: promptProfile) ?? .largeOpt
    let preamble = PromptEngineerPrompts.preamble(for: profile)

    let cwd = FileManager.default.currentDirectoryPath
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

    let threadReq = s.sendRequest(method: "thread/start", params: threadParams)
    let threadResp = try s.waitForResponse(id: threadReq, timeoutMs: 30_000)
    let threadId = try extractString(threadResp, ["result", "thread", "id"]) ?? ""
    if threadId.isEmpty {
      throw CodexAppServerPromptEngineerError.protocolError("thread/start missing thread.id")
    }

    let baseEff = effectiveReasoningEffort(model: model)
    let out1Raw = try runTurn(s: s, threadId: threadId, prompt: prompt, instruction: instruction, effortOverride: baseEff)
    let out1 = PromptEngineerOutputGuard.normalize(output: out1Raw).trimmingCharacters(in: .whitespacesAndNewlines)
    let check = PromptEngineerOutputGuard.check(draft: prompt, output: out1)
    if !check.needsRepair {
      return out1
    }

    let repairEff = PromptEngineerOutputGuard.suggestedRepairEffort(baseEff)
    let out2Raw = try runTurn(
      s: s,
      threadId: threadId,
      prompt: prompt,
      instruction: PromptEngineerPrompts.repairInstruction,
      effortOverride: repairEff.isEmpty ? baseEff : repairEff
    )
    let out2 = PromptEngineerOutputGuard.normalize(output: out2Raw).trimmingCharacters(in: .whitespacesAndNewlines)
    let check2 = PromptEngineerOutputGuard.check(draft: prompt, output: out2)
    if check2.reasons.contains("missing_actionable_numbered_step_section") {
      throw CodexAppServerPromptEngineerError.invalidOutput(check2.reasons)
    }
    return out2
  }

  private func ensureServer() throws -> ServerProcess {
    if let existing = server, existing.isAlive {
      return existing
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
        "-c",
        "mcp_servers.context7.enabled=false",
        "-c",
        "mcp_servers.playwright.enabled=false",
      ]

      // Allow passing additional `-c/--config` overrides to app-server via agent.args.
      out.append(contentsOf: filterAppServerArgs(extraArgs))
      return out
    }()

    let spawned = try ServerProcess.spawn(executablePath: resolved, arguments: args)
    server = spawned
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

  // MARK: - ServerProcess

  private final class ServerProcess {
    let pid: pid_t
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private var buffer = Data()
    private var nextId: Int = 1
    private var initialized = false

    init(pid: pid_t, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32) {
      self.pid = pid
      self.stdinFD = stdinFD
      self.stdoutFD = stdoutFD
      self.stderrFD = stderrFD
    }

    var isAlive: Bool {
      kill(pid, 0) == 0
    }

    static func spawn(executablePath: String, arguments: [String]) throws -> ServerProcess {
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

      let rc = posix_spawn(&pid, executablePath, &actions, nil, &cArgs, environ)
      if rc != 0 {
        close(inFds[0]); close(inFds[1]); close(outFds[0]); close(outFds[1]); close(errFds[0]); close(errFds[1])
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
      let reqId = sendRequest(method: "initialize", params: params)
      _ = try waitForResponse(id: reqId, timeoutMs: timeoutMs)
      initialized = true
    }

    func sendRequest(method: String, params: [String: Any]) -> Int {
      let id = nextId
      nextId += 1
      let obj: [String: Any] = ["id": id, "method": method, "params": params]
      let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data()
      var frame = data
      frame.append(0x0A) // \n
      _ = try? writeAll(fd: stdinFD, data: frame)
      return id
    }

    func waitForResponse(id: Int, timeoutMs: Int) throws -> [String: Any] {
      let endByNs = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeoutMs)) * 1_000_000
      while DispatchTime.now().uptimeNanoseconds < endByNs {
        let remainingMs = Int((endByNs - DispatchTime.now().uptimeNanoseconds) / 1_000_000)
        guard let msg = try readNextMessage(timeoutMs: max(10, min(500, remainingMs))) else {
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
      }
      throw CodexAppServerPromptEngineerError.timedOut
    }

    func readNextMessage(timeoutMs: Int) throws -> [String: Any]? {
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

    private static func setCloExec(_ fd: Int32) {
      let flags = fcntl(fd, F_GETFD)
      if flags >= 0 {
        _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
      }
    }

    private static func setNonBlocking(_ fd: Int32) {
      let flags = fcntl(fd, F_GETFL)
      if flags >= 0 {
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
      }
    }

    private static func writeAll(fd: Int32, data: Data) throws {
      try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
          let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
          if n > 0 {
            offset += n
            continue
          }
          if n == -1, errno == EINTR {
            continue
          }
          throw CodexAppServerPromptEngineerError.spawnFailed(errno: errno)
        }
      }
    }

    private func setCloExec(_ fd: Int32) { Self.setCloExec(fd) }
    private func setNonBlocking(_ fd: Int32) { Self.setNonBlocking(fd) }
    private func writeAll(fd: Int32, data: Data) throws { try Self.writeAll(fd: fd, data: data) }
  }
}
