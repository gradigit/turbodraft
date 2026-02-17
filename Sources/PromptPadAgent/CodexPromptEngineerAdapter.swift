import Darwin
import Foundation
import PromptPadCore

public enum CodexPromptEngineerError: Error, CustomStringConvertible {
  case commandNotFound
  case spawnFailed(errno: Int32)
  case timedOut
  case nonZeroExit(Int32, String)
  case invalidOutput([String])
  case missingOutputFile
  case outputTooLarge

  public var description: String {
    switch self {
    case .commandNotFound: return "Codex CLI not found"
    case let .spawnFailed(e): return "Spawn failed errno=\(e)"
    case .timedOut: return "Timed out"
    case let .nonZeroExit(code, msg): return "Non-zero exit: \(code) (\(msg))"
    case let .invalidOutput(reasons): return "Invalid output (\(reasons.joined(separator: ",")))"
    case .missingOutputFile: return "Missing output file"
    case .outputTooLarge: return "Output too large"
    }
  }
}

/// Prompt engineering agent powered by OpenAI Codex CLI (`codex exec`).
///
/// This adapter writes the final assistant message to a temp file via
/// `--output-last-message` and returns that file content as the “draft”.
public final class CodexPromptEngineerAdapter: AgentAdapting, @unchecked Sendable {
  private let command: String
  private let model: String
  private let timeoutMs: Int
  private let webSearch: String
  private let promptProfile: String
  private let reasoningEffort: String
  private let reasoningSummary: String
  private let extraArgs: [String]
  private let maxOutputBytes: Int
  private actor State {
    var disableModelOverride = false

    func requestedModelOverride(_ model: String) -> String? {
      disableModelOverride ? nil : model
    }

    func disableOverride() {
      disableModelOverride = true
    }
  }
  private let state = State()

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

  public func draft(prompt: String, instruction: String) async throws -> String {
    guard let resolved = CommandResolver.resolveInPATH(command) else {
      throw CodexPromptEngineerError.commandNotFound
    }

    let requestedModel: String? = await state.requestedModelOverride(model)
    var modelOverride: String? = requestedModel
    let profile = PromptEngineerPrompts.Profile(rawValue: promptProfile) ?? .largeOpt

    var out1: String
    do {
      let stdinText = PromptEngineerPrompts.compose(prompt: prompt, instruction: instruction, profile: profile)
      out1 = try runCodex(resolved: resolved, stdin: Data(stdinText.utf8), modelOverride: modelOverride)
    } catch let e as CodexPromptEngineerError {
      if case let .nonZeroExit(_, msg) = e,
        msg.contains("model is not supported when using Codex with a ChatGPT account")
      {
        // Retry once without forcing the model; let the CLI pick a supported default.
        await state.disableOverride()
        modelOverride = nil
        let stdinText = PromptEngineerPrompts.compose(prompt: prompt, instruction: instruction, profile: profile)
        out1 = try runCodex(resolved: resolved, stdin: Data(stdinText.utf8), modelOverride: modelOverride)
      } else {
        throw e
      }
    }

    let normalized1 = PromptEngineerOutputGuard.normalize(output: out1).trimmingCharacters(in: .whitespacesAndNewlines)
    let check = PromptEngineerOutputGuard.check(draft: prompt, output: normalized1)
    if !check.needsRepair {
      return normalized1
    }

    let usedModel = (modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? model
    let baseEffort = effectiveReasoningEffort(model: usedModel, requested: reasoningEffort)
    let repairEffort = PromptEngineerOutputGuard.suggestedRepairEffort(baseEffort)

    let stdinRepairText = PromptEngineerPrompts.compose(
      prompt: prompt,
      instruction: PromptEngineerPrompts.repairInstruction,
      profile: profile
    )
    let out2Raw = try runCodex(
      resolved: resolved,
      stdin: Data(stdinRepairText.utf8),
      modelOverride: modelOverride,
      reasoningEffortOverride: repairEffort.isEmpty ? nil : repairEffort
    )
    let out2 = PromptEngineerOutputGuard.normalize(output: out2Raw).trimmingCharacters(in: .whitespacesAndNewlines)
    let check2 = PromptEngineerOutputGuard.check(draft: prompt, output: out2)
    if check2.reasons.contains("missing_actionable_numbered_step_section") {
      throw CodexPromptEngineerError.invalidOutput(check2.reasons)
    }
    return out2
  }

  private func effectiveReasoningEffort(model: String, requested: String) -> String {
    let e = requested.trimmingCharacters(in: .whitespacesAndNewlines)
    if e.isEmpty { return e }
    let m = model.lowercased()
    if m.contains("spark"), e == "minimal" {
      // Spark models reject "minimal"; prefer a safe, supported fallback.
      return "low"
    }
    if m.contains("gpt-5.3-codex"), e == "minimal" {
      // Some Codex backends reject "minimal" and accept "none" instead.
      return "none"
    }
    return e
  }

  private func runCodex(resolved: String, stdin: Data, modelOverride: String?, reasoningEffortOverride: String? = nil) throws -> String {
    let outURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("promptpad-codex-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: outURL) }

    // Use Codex CLI exec mode. `-` reads from stdin.
    var args: [String] = [
      "exec",
      "--skip-git-repo-check",
      "--ephemeral",
      "--sandbox",
      "read-only",
      "--output-last-message",
      outURL.path,
    ]
    let m = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !m.isEmpty {
      args.append(contentsOf: ["--model", m])
    }

    // Default to a lightweight, tool-free run. Users can override via agent.args.
    // NOTE: Codex approvals are configured via config; there is no `--ask-for-approval` flag.
    // Keeping this as a config override avoids interactive prompts while staying CLI-compatible.
    args.append(contentsOf: ["-c", "approval=never"])
    args.append(contentsOf: ["-c", "web_search=\(webSearch)"])
    let usedModel = m.isEmpty ? model : m
    let reqEff = reasoningEffortOverride ?? reasoningEffort
    args.append(contentsOf: ["-c", "model_reasoning_effort=\(effectiveReasoningEffort(model: usedModel, requested: reqEff))"])
    args.append(contentsOf: ["-c", "model_reasoning_summary=\(reasoningSummary)"])
    args.append(contentsOf: ["-c", "mcp_servers.context7.enabled=false"])
    args.append(contentsOf: ["-c", "mcp_servers.playwright.enabled=false"])

    args.append(contentsOf: extraArgs)
    args.append("-")

    let res = try spawnAndCapture(executablePath: resolved, arguments: args, stdin: stdin, timeoutMs: timeoutMs, maxOutputBytes: 256 * 1024)
    if res.didTimeout {
      throw CodexPromptEngineerError.timedOut
    }
    guard res.exitCode == 0 else {
      let msg = summarizeFailureOutput(res.output)
      throw CodexPromptEngineerError.nonZeroExit(res.exitCode, msg.isEmpty ? "codex exec failed" : msg)
    }

    guard let data = try? Data(contentsOf: outURL) else {
      throw CodexPromptEngineerError.missingOutputFile
    }

    if data.count > maxOutputBytes {
      throw CodexPromptEngineerError.outputTooLarge
    }
    return String(decoding: data, as: UTF8.self)
  }

  private func summarizeFailureOutput(_ data: Data) -> String {
    let text = String(decoding: data, as: UTF8.self)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    if let line = lines.reversed().first(where: { $0.contains("ERROR:") }) {
      if let r = line.range(of: "\"detail\":\"") {
        let rest = line[r.upperBound...]
        if let end = rest.firstIndex(of: "\"") {
          return String(rest[..<end])
        }
      }
      if let r = line.range(of: "ERROR:") {
        return line[r.upperBound...].trimmingCharacters(in: .whitespaces)
      }
      return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if let line = lines.reversed().first(where: { $0.localizedCaseInsensitiveContains("error") }) {
      return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let tail = lines.suffix(12).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if tail.count > 900 {
      let idx = tail.index(tail.startIndex, offsetBy: 900)
      return String(tail[..<idx]) + "…"
    }
    return tail
  }

  private struct SpawnResult {
    var exitCode: Int32
    var output: Data
    var didTimeout: Bool
  }

  private func spawnAndCapture(executablePath: String, arguments: [String], stdin: Data, timeoutMs: Int, maxOutputBytes: Int) throws -> SpawnResult {
    var inFds: [Int32] = [0, 0]
    guard pipe(&inFds) == 0 else { throw CodexPromptEngineerError.spawnFailed(errno: errno) }
    var outFds: [Int32] = [0, 0]
    guard pipe(&outFds) == 0 else {
      close(inFds[0]); close(inFds[1])
      throw CodexPromptEngineerError.spawnFailed(errno: errno)
    }

    setCloExec(inFds[0]); setCloExec(inFds[1])
    setCloExec(outFds[0]); setCloExec(outFds[1])

    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }

    posix_spawn_file_actions_adddup2(&actions, inFds[0], STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, outFds[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, outFds[1], STDERR_FILENO)

    posix_spawn_file_actions_addclose(&actions, inFds[1])
    posix_spawn_file_actions_addclose(&actions, outFds[0])
    posix_spawn_file_actions_addclose(&actions, inFds[0])
    posix_spawn_file_actions_addclose(&actions, outFds[1])

    var pid: pid_t = 0
    let argv = [executablePath] + arguments
    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cArgs.append(nil)
    defer {
      for p in cArgs where p != nil { free(p) }
    }

    let rc = posix_spawn(&pid, executablePath, &actions, nil, &cArgs, environ)
    if rc != 0 {
      close(inFds[0]); close(inFds[1]); close(outFds[0]); close(outFds[1])
      throw CodexPromptEngineerError.spawnFailed(errno: Int32(rc))
    }

    close(inFds[0])
    close(outFds[1])

    do { try writeAll(fd: inFds[1], data: stdin) } catch { /* ignore */ }
    close(inFds[1])

    setNonBlocking(outFds[0])

    let startNs = DispatchTime.now().uptimeNanoseconds
    let timeoutNs = UInt64(max(0, timeoutMs)) * 1_000_000

    var didTimeout = false
    var status: Int32? = nil
    var sawEOF = false
    var output = Data()
    output.reserveCapacity(min(maxOutputBytes, 32 * 1024))

    func drainOutput() {
      if sawEOF { return }
      var buf = [UInt8](repeating: 0, count: 8192)
      while output.count < maxOutputBytes {
        let n: Int = buf.withUnsafeMutableBytes { raw in
          guard let base = raw.baseAddress else { return -1 }
          return Darwin.read(outFds[0], base, raw.count)
        }
        if n > 0 {
          output.append(contentsOf: buf[0..<n])
          continue
        }
        if n == 0 {
          sawEOF = true
          break
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          break
        }
        sawEOF = true
        break
      }
    }

    while true {
      drainOutput()

      if status == nil {
        var st: Int32 = 0
        let w = waitpid(pid, &st, WNOHANG)
        if w == pid {
          status = st
        }
      }

      if status != nil, sawEOF {
        break
      }

      let elapsedNs = DispatchTime.now().uptimeNanoseconds - startNs
      if status == nil, elapsedNs > timeoutNs, !didTimeout {
        didTimeout = true
        kill(pid, SIGTERM)

        let graceStart = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - graceStart < 1_000_000_000 {
          drainOutput()
          var st: Int32 = 0
          let w = waitpid(pid, &st, WNOHANG)
          if w == pid {
            status = st
            break
          }
          var pfd = pollfd(fd: outFds[0], events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
          _ = poll(&pfd, 1, 20)
        }

        if status == nil {
          kill(pid, SIGKILL)
          var st: Int32 = 0
          _ = waitpid(pid, &st, 0)
          status = st
        }
      }

      var pfd = pollfd(fd: outFds[0], events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
      _ = poll(&pfd, 1, 50)
    }

    close(outFds[0])

    let st = status ?? 0
    let wstatus = st & 0x7F
    let exitCode: Int32
    if wstatus == 0 {
      exitCode = (st >> 8) & 0xFF
    } else {
      exitCode = 128 + wstatus
    }

    return SpawnResult(exitCode: exitCode, output: output, didTimeout: didTimeout)
  }

  private func setCloExec(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFD)
    if flags >= 0 {
      _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }
  }

  private func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 {
      _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
  }

  private func writeAll(fd: Int32, data: Data) throws {
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
        throw CodexPromptEngineerError.spawnFailed(errno: errno)
      }
    }
  }
}
