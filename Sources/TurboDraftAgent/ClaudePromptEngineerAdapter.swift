import Darwin
import Foundation
import TurboDraftCore
import os

public enum ClaudePromptEngineerError: Error, CustomStringConvertible {
  case commandNotFound
  case spawnFailed(errno: Int32)
  case timedOut
  case nonZeroExit(Int32, String)
  case invalidOutput([String])
  case outputTooLarge

  public var description: String {
    switch self {
    case .commandNotFound: return "Claude CLI not found"
    case let .spawnFailed(e): return "Spawn failed errno=\(e)"
    case .timedOut: return "Timed out"
    case let .nonZeroExit(code, msg): return "Non-zero exit: \(code) (\(msg))"
    case let .invalidOutput(reasons): return "Invalid output (\(reasons.joined(separator: ",")))"
    case .outputTooLarge: return "Output too large"
    }
  }
}

/// Prompt engineering agent powered by the Claude Code CLI (`claude --print`).
///
/// Spawns `claude -p` per turn with a system prompt (the preamble) and the
/// user turn text piped via stdin. Output is read directly from stdout.
public final class ClaudePromptEngineerAdapter: AgentAdapting, @unchecked Sendable {
  private let command: String
  private let model: String
  private let timeoutMs: Int
  private let promptProfile: String
  private let reasoningEffort: String
  private let extraArgs: [String]
  private let maxOutputBytes: Int
  private static let adapterLog = Logger(subsystem: "com.turbodraft", category: "ClaudePromptEngineerAdapter")

  public init(
    command: String = "claude",
    model: String = "claude-sonnet-4-6",
    timeoutMs: Int = 120_000,
    promptProfile: String = "large_opt",
    reasoningEffort: String = "high",
    extraArgs: [String] = [],
    maxOutputBytes: Int = 2 * 1024 * 1024
  ) {
    self.command = command
    self.model = model
    self.timeoutMs = timeoutMs
    self.promptProfile = promptProfile
    self.reasoningEffort = reasoningEffort
    self.extraArgs = extraArgs
    self.maxOutputBytes = maxOutputBytes
  }

  /// Maps TurboDraft reasoning effort values to Claude CLI `--effort` values.
  private static func claudeEffort(_ effort: String) -> String {
    switch effort.lowercased() {
    case "minimal", "none", "low": return "low"
    case "medium": return "medium"
    case "high", "xhigh": return "high"
    default: return "high"
    }
  }

  public func draft(prompt: String, instruction: String, images: [URL], cwd: String?) async throws -> String {
    if !images.isEmpty {
      Self.adapterLog.warning("ClaudePromptEngineerAdapter does not yet support images; \(images.count) image(s) will be ignored")
    }
    guard let resolved = CommandResolver.resolveInPATH(command) else {
      throw ClaudePromptEngineerError.commandNotFound
    }
    let adapter = self
    return try await Task.detached {
      try await adapter.draftBlocking(resolved: resolved, prompt: prompt, instruction: instruction, cwd: cwd)
    }.value
  }

  private func draftBlocking(resolved: String, prompt: String, instruction: String, cwd: String?) async throws -> String {
    let profile = PromptEngineerPrompts.Profile(rawValue: promptProfile) ?? .largeOpt
    let preamble = PromptEngineerPrompts.preamble(for: profile)
    let userText = PromptEngineerPrompts.userTurnText(prompt: prompt, instruction: instruction)

    let out1 = try runClaude(resolved: resolved, systemPrompt: preamble, userMessage: userText, cwd: cwd)

    let normalized1 = PromptEngineerOutputGuard.normalize(output: out1).trimmingCharacters(in: .whitespacesAndNewlines)
    let check = PromptEngineerOutputGuard.check(draft: prompt, output: normalized1)
    if !check.needsRepair {
      return normalized1
    }

    // Repair turn with the repair instruction.
    let repairUserText = PromptEngineerPrompts.userTurnText(
      prompt: prompt,
      instruction: PromptEngineerPrompts.repairInstruction
    )
    let out2Raw = try runClaude(resolved: resolved, systemPrompt: preamble, userMessage: repairUserText, cwd: cwd)
    let out2 = PromptEngineerOutputGuard.normalize(output: out2Raw).trimmingCharacters(in: .whitespacesAndNewlines)
    let check2 = PromptEngineerOutputGuard.check(draft: prompt, output: out2)
    if check2.reasons.contains("missing_actionable_numbered_step_section") {
      throw ClaudePromptEngineerError.invalidOutput(check2.reasons)
    }
    return out2
  }

  private func runClaude(resolved: String, systemPrompt: String, userMessage: String, cwd: String?) throws -> String {
    // Write system prompt to temp file to avoid ARG_MAX issues with long preambles.
    let preambleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("turbodraft-claude-\(UUID().uuidString).txt")
    try Data(systemPrompt.utf8).write(to: preambleURL, options: [.atomic])
    defer { try? FileManager.default.removeItem(at: preambleURL) }

    var args: [String] = [
      "-p",
      "--model", model,
      "--system-prompt-file", preambleURL.path,
      "--output-format", "text",
      "--effort", Self.claudeEffort(reasoningEffort),
      "--tools", "",
      "--max-turns", "1",
      "--no-session-persistence",
    ]
    args.append(contentsOf: extraArgs)

    let res = try spawnAndCapture(
      executablePath: resolved,
      arguments: args,
      stdin: Data(userMessage.utf8),
      timeoutMs: timeoutMs,
      maxOutputBytes: maxOutputBytes,
      cwd: cwd
    )
    if res.didTimeout {
      throw ClaudePromptEngineerError.timedOut
    }
    guard res.exitCode == 0 else {
      let msg = summarizeFailureOutput(res.output)
      throw ClaudePromptEngineerError.nonZeroExit(res.exitCode, msg.isEmpty ? "claude failed" : msg)
    }

    if res.output.count > maxOutputBytes {
      throw ClaudePromptEngineerError.outputTooLarge
    }
    return String(decoding: res.output, as: UTF8.self)
  }

  private func summarizeFailureOutput(_ data: Data) -> String {
    let text = String(decoding: data, as: UTF8.self)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    if let line = lines.reversed().first(where: { $0.contains("ERROR:") || $0.contains("Error:") }) {
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

  private func spawnAndCapture(executablePath: String, arguments: [String], stdin: Data, timeoutMs: Int, maxOutputBytes: Int, cwd: String? = nil) throws -> SpawnResult {
    var inFds: [Int32] = [0, 0]
    guard pipe(&inFds) == 0 else { throw ClaudePromptEngineerError.spawnFailed(errno: errno) }
    var outFds: [Int32] = [0, 0]
    guard pipe(&outFds) == 0 else {
      close(inFds[0]); close(inFds[1])
      throw ClaudePromptEngineerError.spawnFailed(errno: errno)
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

    if let cwd, !cwd.isEmpty {
      posix_spawn_file_actions_addchdir_np(&actions, cwd)
    }

    var pid: pid_t = 0
    let argv = [executablePath] + arguments
    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cArgs.append(nil)
    defer {
      for p in cArgs where p != nil { free(p) }
    }

    let execDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
    var cEnv: [UnsafeMutablePointer<CChar>?] = CommandResolver.buildEnv(prependingToPath: execDir).map { strdup($0) }
    cEnv.append(nil)
    defer { for p in cEnv where p != nil { free(p) } }

    let rc = posix_spawn(&pid, executablePath, &actions, nil, &cArgs, &cEnv)
    if rc != 0 {
      close(inFds[0]); close(inFds[1]); close(outFds[0]); close(outFds[1])
      if rc == ENOENT {
        throw ClaudePromptEngineerError.commandNotFound
      }
      throw ClaudePromptEngineerError.spawnFailed(errno: Int32(rc))
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

}
