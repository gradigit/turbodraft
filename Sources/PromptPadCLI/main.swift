import Darwin
import Foundation
import PromptPadConfig
import PromptPadMarkdown
import PromptPadProtocol
import PromptPadTransport

enum CLIError: Error {
  case invalidArgs(String)
  case connectFailed(String)
  case timeout
  case benchFailed(String)
}

struct CLI {
  let args: [String]

  static let helpText = """
promptpad

Commands:
  promptpad config init [--path <path>]
  promptpad open --path <file> [--line N] [--column N] [--wait] [--timeout-ms N] [--stdio]
  promptpad bench run --path <file> [--warm N] [--cold N] [--out <file.json>]
  promptpad bench check --baseline <file.json> --results <file.json>
"""

  func run() throws {
    if args.count <= 1 || args.contains("--help") {
      printHelp()
      return
    }

    switch args[1] {
    case "config":
      try runConfig()
    case "open":
      try runOpen()
    case "bench":
      try runBench()
    default:
      throw CLIError.invalidArgs("Unknown command: \(args[1])")
    }
  }

  private func printHelp() {
    print(Self.helpText)
  }

  private func runConfig() throws {
    guard args.count >= 3 else { throw CLIError.invalidArgs("config requires subcommand") }
    guard args[2] == "init" else { throw CLIError.invalidArgs("unknown config subcommand") }
    let path = argValue("--path")
    try PromptPadConfig.writeDefault(to: path)
    print("Wrote default config.")
  }

  private func runOpen() throws {
    guard let path = argValue("--path") else { throw CLIError.invalidArgs("open requires --path") }
    let line = argInt("--line")
    let column = argInt("--column")
    let wait = args.contains("--wait")
    let timeoutMs = argInt("--timeout-ms") ?? 600_000
    let useStdio = args.contains("--stdio")

    if useStdio {
      let (proc, conn, sessionId) = try openViaStdio(path: path, line: line, column: column)
      if wait {
        _ = try waitViaConnection(conn, sessionId: sessionId, timeoutMs: timeoutMs)
        _ = try quitViaConnection(conn)
        proc.waitUntilExit()
      }
    } else {
      let cfg = PromptPadConfig.load()
      let socketPath = cfg.socketPath
      let t0 = nowMs()
      let connectStart = nowMs()
      let fd = try connectOrLaunch(socketPath: socketPath, timeoutMs: timeoutMs)
      let connectMs = nowMs() - connectStart
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)

      let rpcStart = nowMs()
      let sessionId = try openViaConnection(conn, path: path, line: line, column: column)
      let rpcMs = nowMs() - rpcStart
      let totalMs = nowMs() - t0

      appendOpenLatencyRecord([
        "event": "cli_open",
        "mode": "socket",
        "connectMs": connectMs,
        "rpcOpenMs": rpcMs,
        "totalMs": totalMs,
      ])
      if wait {
        let waitStart = nowMs()
        _ = try waitViaConnection(conn, sessionId: sessionId, timeoutMs: timeoutMs)
        appendOpenLatencyRecord([
          "event": "cli_wait",
          "mode": "socket",
          "waitMs": nowMs() - waitStart,
        ])
      }
    }
  }

  private func nowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
  }

  private func appendOpenLatencyRecord(_ payload: [String: Any]) {
    do {
      let dir = try PromptPadPaths.applicationSupportDir().appendingPathComponent("telemetry", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let file = dir.appendingPathComponent("editor-open.jsonl")
      var record = payload
      record["ts"] = ISO8601DateFormatter().string(from: Date())
      let data = try JSONSerialization.data(withJSONObject: record, options: [])
      let line = data + Data([0x0A])
      if let fh = try? FileHandle(forWritingTo: file) {
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

  private func runBench() throws {
    guard args.count >= 3 else { throw CLIError.invalidArgs("bench requires subcommand") }
    switch args[2] {
    case "run":
      try runBenchRun()
    case "check":
      try runBenchCheck()
    default:
      throw CLIError.invalidArgs("bench requires run|check")
    }
  }

  private struct BenchRunResult: Codable {
    var timestamp: String
    var osVersion: String
    var warmN: Int
    var coldN: Int
    var metrics: [String: Double]
  }

  private func runBenchRun() throws {
    guard let path = argValue("--path") else { throw CLIError.invalidArgs("bench run requires --path") }
    let warmN = argInt("--warm") ?? 50
    let coldN = argInt("--cold") ?? 0
    let outPath = argValue("--out")

    let cfg = PromptPadConfig.load()
    let socketPath = cfg.socketPath

    var metrics: [String: Double] = [:]

    // Warm bench: ensure running.
    _ = try openViaSocket(socketPath: socketPath, path: path, line: 1, column: 1, timeoutMs: 60_000)
    Thread.sleep(forTimeInterval: 0.05)

    // Warm Ctrl+G to editable: include CLI process startup (spawn 'promptpad open' repeatedly).
    _ = try runCtrlGOpenOnce(path: path) // warm caches
    Thread.sleep(forTimeInterval: 0.05)

    var ctrlGSamplesMs: [Double] = []
    for _ in 0..<warmN {
      let start = DispatchTime.now().uptimeNanoseconds
      let code = try runCtrlGOpenOnce(path: path)
      if code != 0 {
        throw CLIError.benchFailed("spawned open exited \(code)")
      }
      let end = DispatchTime.now().uptimeNanoseconds
      ctrlGSamplesMs.append(Double(end - start) / 1_000_000.0)
      Thread.sleep(forTimeInterval: 0.01)
    }
    let warmCtrlGP95 = percentile(ctrlGSamplesMs, p: 0.95)
    print("warm_ctrl_g_to_editable_p95_ms=\(String(format: "%.2f", warmCtrlGP95))")
    metrics["warm_ctrl_g_to_editable_p95_ms"] = warmCtrlGP95

    // Warm open round-trip (in-process, no extra process launch).
    var samplesMs: [Double] = []
    for _ in 0..<warmN {
      let start = DispatchTime.now().uptimeNanoseconds
      _ = try openViaSocket(socketPath: socketPath, path: path, line: 1, column: 1, timeoutMs: 60_000)
      let end = DispatchTime.now().uptimeNanoseconds
      samplesMs.append(Double(end - start) / 1_000_000.0)
    }
    let warmOpenP95 = percentile(samplesMs, p: 0.95)
    print("warm_open_roundtrip_p95_ms=\(String(format: "%.2f", warmOpenP95))")
    metrics["warm_open_roundtrip_p95_ms"] = warmOpenP95

    // Warm text engine microbenchmark (synthetic insertion + markdown highlight pass).
    let initialText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let warmTextKitP95 = syntheticTypingP95(initialText: initialText, samples: warmN)
    print("warm_textkit_highlight_p95_ms=\(String(format: "%.2f", warmTextKitP95))")
    metrics["warm_textkit_highlight_p95_ms"] = warmTextKitP95

    // Warm autosave bench: measure sessionSave RPC time over a single connection.
    do {
      let fd = try connectOrLaunch(socketPath: socketPath, timeoutMs: 60_000)
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
      try sendHello(conn)
      let openRes = try sendSessionOpen(conn, path: path, line: 1, column: 1)

      var saveSamplesMs: [Double] = []
      for i in 0..<warmN {
        let content = "PromptPad bench save \(i)\n\n" + String(repeating: "x", count: 4096)
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try sendSessionSave(conn, sessionId: openRes.sessionId, content: content)
        let end = DispatchTime.now().uptimeNanoseconds
        saveSamplesMs.append(Double(end - start) / 1_000_000.0)
      }
      let warmSaveP95 = percentile(saveSamplesMs, p: 0.95)
      print("warm_save_roundtrip_p95_ms=\(String(format: "%.2f", warmSaveP95))")
      metrics["warm_save_roundtrip_p95_ms"] = warmSaveP95
    }

    // Warm reflect bench: external disk writes should reflect back into session content quickly.
    // This uses an event-driven server wait (no client poll loop) to avoid quantization bias.
    do {
      let fileURL = URL(fileURLWithPath: path)
      let fd = try connectOrLaunch(socketPath: socketPath, timeoutMs: 60_000)
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
      try sendHello(conn)
      let openRes = try sendSessionOpen(conn, path: path, line: 1, column: 1)

      var lastRevision = openRes.revision
      var reflectSamplesMs: [Double] = []
      for i in 0..<warmN {
        let externalContent = "PromptPad bench reflect \(i)\n" + String(repeating: "y", count: 2048)
        try Data(externalContent.utf8).write(to: fileURL, options: [.atomic])

        let start = DispatchTime.now().uptimeNanoseconds
        let wait = try sendSessionWaitForRevision(
          conn,
          sessionId: openRes.sessionId,
          baseRevision: lastRevision,
          timeoutMs: 5_000
        )
        var revision = wait.revision
        var matched = wait.changed && wait.content == externalContent
        if !matched {
          let fallbackDeadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
          while DispatchTime.now().uptimeNanoseconds < fallbackDeadline {
            let reload = try sendSessionReload(conn, sessionId: openRes.sessionId)
            if reload.content == externalContent {
              revision = reload.revision
              matched = true
              break
            }
            Thread.sleep(forTimeInterval: 0.02)
          }
        }
        if !matched {
          throw CLIError.benchFailed("reflect did not update within deadline")
        }

        let end = DispatchTime.now().uptimeNanoseconds
        reflectSamplesMs.append(Double(end - start) / 1_000_000.0)
        lastRevision = revision
      }

      let warmReflectP95 = percentile(reflectSamplesMs, p: 0.95)
      print("warm_agent_reflect_p95_ms=\(String(format: "%.2f", warmReflectP95))")
      metrics["warm_agent_reflect_p95_ms"] = warmReflectP95
    }

    if coldN > 0 {
      var coldCtrlGSamplesMs: [Double] = []
      for _ in 0..<coldN {
        // Force non-resident cold path.
        _ = try? posixSpawnAndWait(command: "pkill", arguments: ["-f", "promptpad-app"])
        try? FileManager.default.removeItem(atPath: socketPath)
        Thread.sleep(forTimeInterval: 0.02)

        let start = DispatchTime.now().uptimeNanoseconds
        let code = try runCtrlGOpenOnce(path: path)
        let end = DispatchTime.now().uptimeNanoseconds
        guard code == 0 else {
          throw CLIError.benchFailed("cold ctrl+g open exited \(code)")
        }
        coldCtrlGSamplesMs.append(Double(end - start) / 1_000_000.0)
        Thread.sleep(forTimeInterval: 0.01)
      }
      let coldCtrlGP95 = percentile(coldCtrlGSamplesMs, p: 0.95)
      print("cold_ctrl_g_to_editable_p95_ms=\(String(format: "%.2f", coldCtrlGP95))")
      metrics["cold_ctrl_g_to_editable_p95_ms"] = coldCtrlGP95
    }

    if let outPath {
      let now = ISO8601DateFormatter().string(from: Date())
      let res = BenchRunResult(
        timestamp: now,
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        warmN: warmN,
        coldN: coldN,
        metrics: metrics
      )
      let url = URL(fileURLWithPath: outPath)
      let data = try JSONEncoder().encode(res)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: [.atomic])
    }
  }

  private func runBenchCheck() throws {
    guard let baselinePath = argValue("--baseline") else { throw CLIError.invalidArgs("bench check requires --baseline") }
    guard let resultsPath = argValue("--results") else { throw CLIError.invalidArgs("bench check requires --results") }

    let baselineURL = URL(fileURLWithPath: baselinePath)
    let resultsURL = URL(fileURLWithPath: resultsPath)

    let baselineData = try Data(contentsOf: baselineURL)
    let baseline = try JSONDecoder().decode([String: Double].self, from: baselineData)

    let resultsData = try Data(contentsOf: resultsURL)
    let results = try JSONDecoder().decode(BenchRunResult.self, from: resultsData)

    var failures: [String] = []
    for (k, cap) in baseline {
      guard let value = results.metrics[k] else {
        failures.append("\(k): missing (cap \(cap))")
        continue
      }
      if value > cap {
        failures.append("\(k): \(String(format: "%.2f", value)) > cap \(String(format: "%.2f", cap))")
      }
    }
    if !failures.isEmpty {
      throw CLIError.benchFailed(failures.joined(separator: "; "))
    }
  }

  private func openViaSocket(socketPath: String, path: String, line: Int?, column: Int?, timeoutMs: Int) throws -> String {
    let fd = try connectOrLaunch(socketPath: socketPath, timeoutMs: timeoutMs)
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
    return try openViaConnection(conn, path: path, line: line, column: column)
  }

  private func waitViaSocket(socketPath: String, sessionId: String, timeoutMs: Int) throws -> String {
    let fd = try connectOrLaunch(socketPath: socketPath, timeoutMs: timeoutMs)
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
    return try waitViaConnection(conn, sessionId: sessionId, timeoutMs: timeoutMs)
  }

  private func spawnStdioApp() throws -> (Process, JSONRPCConnection) {
    let inPipe = Pipe()
    let outPipe = Pipe()

    let proc = Process()
    let (appExe, appBaseArgs) = appLaunchCommand()
    proc.executableURL = appExe
    proc.arguments = appBaseArgs + ["--stdio", "--no-socket"]
    proc.standardInput = inPipe
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.standardError
    try proc.run()

    let conn = JSONRPCConnection(readHandle: outPipe.fileHandleForReading, writeHandle: inPipe.fileHandleForWriting)
    return (proc, conn)
  }

  private func openViaStdio(path: String, line: Int?, column: Int?) throws -> (Process, JSONRPCConnection, String) {
    let (proc, conn) = try spawnStdioApp()
    let sessionId = try openViaConnection(conn, path: path, line: line, column: column)
    return (proc, conn, sessionId)
  }

  private func openViaConnection(_ conn: JSONRPCConnection, path: String, line: Int?, column: Int?) throws -> String {
    try sendHello(conn)
    let decoded = try sendSessionOpen(conn, path: path, line: line, column: column)
    return decoded.sessionId
  }

  private func waitViaConnection(_ conn: JSONRPCConnection, sessionId: String, timeoutMs: Int) throws -> String {
    let decoded = try sendSessionWait(conn, sessionId: sessionId, timeoutMs: timeoutMs)
    return decoded.reason
  }

  private func sendHello(_ conn: JSONRPCConnection) throws {
    let hello = JSONRPCRequest(id: .int(1), method: PromptPadMethod.hello, params: JSONValue.object([
      "client": .string("promptpad-cli"),
      "clientVersion": .string("dev"),
    ]))
    try conn.sendJSON(hello)
    _ = try conn.readResponse()
  }

  private func sendSessionOpen(_ conn: JSONRPCConnection, path: String, line: Int?, column: Int?) throws -> SessionOpenResult {
    var paramsObj: [String: JSONValue] = ["path": .string(path)]
    if let line { paramsObj["line"] = .int(Int64(line)) }
    if let column { paramsObj["column"] = .int(Int64(column)) }
    let openReq = JSONRPCRequest(id: .int(2), method: PromptPadMethod.sessionOpen, params: .object(paramsObj))
    try conn.sendJSON(openReq)
    let resp = try conn.readResponse()
    if let err = resp.error {
      throw CLIError.connectFailed("open error \(err.code): \(err.message)")
    }
    guard let result = resp.result else {
      throw CLIError.connectFailed("missing result")
    }
    return try result.decode(SessionOpenResult.self)
  }

  private func sendSessionSave(_ conn: JSONRPCConnection, sessionId: String, content: String) throws -> SessionSaveResult {
    let req = JSONRPCRequest(id: .int(3), method: PromptPadMethod.sessionSave, params: .object([
      "sessionId": .string(sessionId),
      "content": .string(content),
    ]))
    try conn.sendJSON(req)
    let resp = try conn.readResponse()
    if let err = resp.error {
      throw CLIError.connectFailed("save error \(err.code): \(err.message)")
    }
    guard let result = resp.result else { throw CLIError.connectFailed("missing save result") }
    return try result.decode(SessionSaveResult.self)
  }

  private func sendSessionReload(_ conn: JSONRPCConnection, sessionId: String) throws -> SessionReloadResult {
    let req = JSONRPCRequest(id: .int(4), method: PromptPadMethod.sessionReload, params: .object([
      "sessionId": .string(sessionId),
    ]))
    try conn.sendJSON(req)
    let resp = try conn.readResponse()
    if let err = resp.error {
      throw CLIError.connectFailed("reload error \(err.code): \(err.message)")
    }
    guard let result = resp.result else { throw CLIError.connectFailed("missing reload result") }
    return try result.decode(SessionReloadResult.self)
  }

  private func sendSessionWaitForRevision(
    _ conn: JSONRPCConnection,
    sessionId: String,
    baseRevision: String,
    timeoutMs: Int
  ) throws -> SessionWaitForRevisionResult {
    let req = JSONRPCRequest(id: .int(5), method: PromptPadMethod.sessionWaitForRevision, params: .object([
      "sessionId": .string(sessionId),
      "baseRevision": .string(baseRevision),
      "timeoutMs": .int(Int64(timeoutMs)),
    ]))
    try conn.sendJSON(req)
    let resp = try conn.readResponse()
    if let err = resp.error {
      throw CLIError.connectFailed("waitForRevision error \(err.code): \(err.message)")
    }
    guard let result = resp.result else {
      throw CLIError.connectFailed("missing waitForRevision result")
    }
    return try result.decode(SessionWaitForRevisionResult.self)
  }

  private func sendSessionWait(_ conn: JSONRPCConnection, sessionId: String, timeoutMs: Int) throws -> SessionWaitResult {
    let waitReq = JSONRPCRequest(id: .int(6), method: PromptPadMethod.sessionWait, params: .object([
      "sessionId": .string(sessionId),
      "timeoutMs": .int(Int64(timeoutMs)),
    ]))
    try conn.sendJSON(waitReq)
    let resp = try conn.readResponse()
    if let err = resp.error {
      throw CLIError.connectFailed("wait error \(err.code): \(err.message)")
    }
    guard let result = resp.result else { return SessionWaitResult(reason: "unknown") }
    return try result.decode(SessionWaitResult.self)
  }

  private func quitViaConnection(_ conn: JSONRPCConnection) throws -> Bool {
    let req = JSONRPCRequest(id: .int(7), method: PromptPadMethod.appQuit, params: .null)
    try conn.sendJSON(req)
    let resp = try conn.readResponse()
    return resp.error == nil
  }

  private enum SpawnError: Error {
    case spawnFailed(errno: Int32)
    case waitFailed(errno: Int32)
  }

  private func posixSpawnDetached(command: String, arguments: [String]) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: command)
    proc.arguments = arguments
    proc.standardInput = FileHandle.nullDevice
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try proc.run()
  }

  private func runCtrlGOpenOnce(path: String) throws -> Int32 {
    let baseArgs = ["--path", path, "--line", "1", "--column", "1", "--timeout-ms", "60000"]
    let cfg = PromptPadConfig.load()
    let socketPath = cfg.socketPath
    let argv0 = args.first ?? "promptpad"

    do {
      let code = try posixSpawnAndWait(command: argv0, arguments: ["open"] + baseArgs)
      if code == 0 {
        return 0
      }
    } catch {
      // Fall through.
    }

    if let exe = siblingExecutablePath(named: "promptpad-open") {
      if let code = try? posixSpawnAndWait(command: exe, arguments: baseArgs), code == 0 {
        return 0
      }
    }

    do {
      let code = try posixSpawnAndWait(command: "promptpad-open", arguments: baseArgs)
      if code == 0 {
        return 0
      }
    } catch SpawnError.spawnFailed(let e) where e == ENOENT {
      // Fall through.
    } catch {
      // Fall through to socket fallback.
    }

    do {
      _ = try openViaSocket(socketPath: socketPath, path: path, line: 1, column: 1, timeoutMs: 60_000)
      return 0
    } catch {
      return try posixSpawnAndWait(command: argv0, arguments: ["open"] + baseArgs)
    }
  }

  private func posixSpawnAndWait(command: String, arguments: [String]) throws -> Int32 {
    var pid: pid_t = 0
    let argv = [command] + arguments
    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cArgs.append(nil)
    defer {
      for p in cArgs where p != nil { free(p) }
    }

    let rc = posix_spawnp(&pid, command, nil, nil, &cArgs, environ)
    if rc != 0 {
      throw SpawnError.spawnFailed(errno: Int32(rc))
    }

    var status: Int32 = 0
    if waitpid(pid, &status, 0) < 0 {
      throw SpawnError.waitFailed(errno: errno)
    }
    let wstatus = status & 0x7F
    if wstatus == 0 {
      return (status >> 8) & 0xFF
    }
    return 128 + wstatus
  }

  private func siblingExecutablePath(named name: String) -> String? {
    let argv0 = args.first ?? ""
    guard argv0.contains("/") else { return nil }
    let dir = URL(fileURLWithPath: argv0).deletingLastPathComponent()
    let candidate = dir.appendingPathComponent(name).path
    if FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    return nil
  }

  private func percentile(_ samplesMs: [Double], p: Double) -> Double {
    if samplesMs.isEmpty { return 0 }
    let p = max(0.0, min(1.0, p))
    let sorted = samplesMs.sorted()
    if p == 0.0 { return sorted[0] }
    let idx = Int(ceil(Double(sorted.count) * p)) - 1
    return sorted[max(0, min(idx, sorted.count - 1))]
  }

  private func syntheticTypingP95(initialText: String, samples: Int) -> Double {
    if samples <= 0 { return 0 }
    var content = initialText
    var cursor = (content as NSString).length
    var timingsMs: [Double] = []
    timingsMs.reserveCapacity(samples)

    let insertionPattern = Array("abcdefghijklmnopqrstuvwxyz ")

    for i in 0..<samples {
      let ch = String(insertionPattern[i % insertionPattern.count])
      let start = DispatchTime.now().uptimeNanoseconds

      let mutable = NSMutableString(string: content)
      mutable.insert(ch, at: cursor)
      content = String(mutable)

      let changedRange = NSRange(location: cursor, length: (ch as NSString).length)
      let lineRange = (content as NSString).lineRange(for: changedRange)
      _ = MarkdownHighlighter.highlights(in: content, range: lineRange)

      let end = DispatchTime.now().uptimeNanoseconds
      timingsMs.append(Double(end - start) / 1_000_000.0)
      cursor += (ch as NSString).length
    }

    return percentile(timingsMs, p: 0.95)
  }

  private func connectOrLaunch(socketPath: String, timeoutMs: Int) throws -> Int32 {
    let start = DispatchTime.now().uptimeNanoseconds
    let deadlineNs = start + UInt64(timeoutMs) * 1_000_000
    var didLaunch = false
    var sleepSeconds = 0.005

    while DispatchTime.now().uptimeNanoseconds < deadlineNs {
      if let fd = try? UnixDomainSocket.connect(path: socketPath) {
        return fd
      }
      // Best-effort launch: spawn promptpad-app if available in PATH.
      if !didLaunch {
        didLaunch = true
        let (appExe, appBaseArgs) = appLaunchCommand()
        _ = try? posixSpawnDetached(command: appExe.path, arguments: appBaseArgs)
      }
      Thread.sleep(forTimeInterval: sleepSeconds)
      sleepSeconds = min(sleepSeconds + 0.003, 0.025)
    }
    throw CLIError.timeout
  }

  private func appLaunchCommand() -> (URL, [String]) {
    let argv0 = args.first ?? "promptpad"
    if argv0.contains("/") {
      let dir = URL(fileURLWithPath: argv0).deletingLastPathComponent()
      let candidate = dir.appendingPathComponent("promptpad-app")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return (candidate, ["--start-hidden"])
      }
    }
    return (URL(fileURLWithPath: "/usr/bin/env"), ["promptpad-app", "--start-hidden"])
  }

  private func argValue(_ key: String) -> String? {
    guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
    return args[idx + 1]
  }

  private func argInt(_ key: String) -> Int? {
    guard let s = argValue(key) else { return nil }
    return Int(s)
  }
}

do {
  try CLI(args: CommandLine.arguments).run()
} catch let e as CLIError {
  switch e {
  case .invalidArgs(let msg):
    fputs("promptpad: \(msg)\n\n", stderr)
    fputs(CLI.helpText + "\n", stderr)
    exit(2)
  case .connectFailed(let msg):
    fputs("promptpad: \(msg)\n", stderr)
    exit(3)
  case .timeout:
    fputs("promptpad: timeout\n", stderr)
    exit(4)
  case .benchFailed(let msg):
    fputs("promptpad: bench failed: \(msg)\n", stderr)
    exit(5)
  }
} catch {
  fputs("promptpad: \(error)\n", stderr)
  exit(1)
}
