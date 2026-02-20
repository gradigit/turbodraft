import Foundation
import TurboDraftCore
import Darwin
import os

public enum CodexCLIAgentError: Error, CustomStringConvertible {
  case commandNotFound
  case spawnFailed(errno: Int32)
  case nonZeroExit(Int32, String)
  case outputTooLarge
  case timedOut

  public var description: String {
    switch self {
    case .commandNotFound: return "Command not found"
    case let .spawnFailed(e): return "Spawn failed errno=\(e)"
    case let .nonZeroExit(code, msg): return "Non-zero exit: \(code)\(msg.isEmpty ? "" : " (\(msg))")"
    case .outputTooLarge: return "Output too large"
    case .timedOut: return "Timed out"
    }
  }
}

private let cliAgentLog = Logger(subsystem: "com.turbodraft", category: "CodexCLIAgentAdapter")

public final class CodexCLIAgentAdapter: AgentAdapting, Sendable {
  private let command: String
  private let args: [String]
  private let timeoutMs: Int
  private let maxOutputBytes: Int

  public init(command: String, args: [String], timeoutMs: Int = 30_000, maxOutputBytes: Int = 2 * 1024 * 1024) {
    self.command = command
    self.args = args
    self.timeoutMs = timeoutMs
    self.maxOutputBytes = maxOutputBytes
  }

  public func draft(prompt: String, instruction: String, images: [URL], cwd: String?) async throws -> String {
    if !images.isEmpty {
      cliAgentLog.warning("CodexCLIAgentAdapter does not support images; \(images.count) image(s) will be ignored")
    }

    let input = """
PROMPT:
\(prompt)

INSTRUCTION:
\(instruction)
"""

    return try await runProcess(stdin: input, cwd: cwd)
  }

  private func runProcess(stdin: String, cwd: String?) async throws -> String {
    guard let resolved = CommandResolver.resolveInPATH(command) else {
      throw CodexCLIAgentError.commandNotFound
    }

    let inputData = Data(stdin.utf8)
    // Run blocking posix_spawn + poll loop off the cooperative thread pool (#10).
    let adapter = self
    let result = try await Task.detached {
      try adapter.spawnAndCapture(executablePath: resolved, arguments: adapter.args, stdin: inputData, cwd: cwd)
    }.value
    if result.didOverflow {
      throw CodexCLIAgentError.outputTooLarge
    }
    if result.didTimeout {
      throw CodexCLIAgentError.timedOut
    }
    guard result.exitCode == 0 else {
      let tail = String(decoding: result.output.suffix(512), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw CodexCLIAgentError.nonZeroExit(result.exitCode, tail)
    }
    return String(decoding: result.output, as: UTF8.self)
  }

  private struct SpawnResult {
    var exitCode: Int32
    var output: Data
    var didTimeout: Bool
    var didOverflow: Bool
  }

  private func spawnAndCapture(executablePath: String, arguments: [String], stdin: Data, cwd: String? = nil) throws -> SpawnResult {
    var inFds: [Int32] = [0, 0]
    guard pipe(&inFds) == 0 else {
      throw CodexCLIAgentError.spawnFailed(errno: errno)
    }
    var outFds: [Int32] = [0, 0]
    guard pipe(&outFds) == 0 else {
      close(inFds[0]); close(inFds[1])
      throw CodexCLIAgentError.spawnFailed(errno: errno)
    }

    setCloExec(inFds[0]); setCloExec(inFds[1])
    setCloExec(outFds[0]); setCloExec(outFds[1])

    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }

    // Child: stdin <- inFds[0], stdout/stderr -> outFds[1]
    posix_spawn_file_actions_adddup2(&actions, inFds[0], STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, outFds[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, outFds[1], STDERR_FILENO)

    // Ensure the child doesn't inherit the unused ends (prevents EOF issues).
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
        throw CodexCLIAgentError.commandNotFound
      }
      throw CodexCLIAgentError.spawnFailed(errno: Int32(rc))
    }

    // Parent: write -> inFds[1], read <- outFds[0]
    close(inFds[0])
    close(outFds[1])

    do {
      try writeAll(fd: inFds[1], data: stdin)
    } catch {
      // If the child exits early, stdin writes can fail; still continue to collect output/exit status.
    }
    close(inFds[1])

    // Non-blocking reads + poll so we can enforce timeouts.
    setNonBlocking(outFds[0])

    let startNs = DispatchTime.now().uptimeNanoseconds
    let timeoutNs = UInt64(max(0, timeoutMs)) * 1_000_000

    var didTimeout = false
    var didOverflow = false
    var status: Int32? = nil
    var sawEOF = false
    var output = Data()
    output.reserveCapacity(min(maxOutputBytes, 64 * 1024))

    func drainOutput() {
      if didOverflow { return }
      var buf = [UInt8](repeating: 0, count: 8192)
      while true {
        let n: Int = buf.withUnsafeMutableBytes { raw in
          guard let base = raw.baseAddress else { return -1 }
          return Darwin.read(outFds[0], base, raw.count)
        }
        if n > 0 {
          output.append(contentsOf: buf[0..<n])
          if output.count > maxOutputBytes, !didOverflow {
            didOverflow = true
            kill(pid, SIGKILL)
            break
          }
          continue
        }
        if n == 0 {
          sawEOF = true
          break
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          break
        }
        // Treat other read errors as EOF-like; we won't get more output.
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

    return SpawnResult(exitCode: exitCode, output: output, didTimeout: didTimeout, didOverflow: didOverflow)
  }

}
