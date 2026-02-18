import AppKit
import Darwin
import Foundation
import TurboDraftConfig
import TurboDraftMarkdown
import TurboDraftProtocol
import TurboDraftTransport

enum CLIError: Error {
  case invalidArgs(String)
  case connectFailed(String)
  case timeout
  case benchFailed(String)
}

struct CLI {
  let args: [String]

  static let helpText = """
turbodraft

Commands:
  turbodraft config init [--path <path>]
  turbodraft open --path <file> [--line N] [--column N] [--wait] [--timeout-ms N] [--stdio]
  turbodraft bench run --path <file> [--fixture-dir <dir>] [--warm N] [--cold N] [--warmup-discard N] [--out <file.json>]
  turbodraft bench check --baseline <file.json> --results <file.json> [--compare <previous.json>]
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
    try TurboDraftConfig.writeDefault(to: path)
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
      let cfg = TurboDraftConfig.load()
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
      let dir = try TurboDraftPaths.applicationSupportDir().appendingPathComponent("telemetry", isDirectory: true)
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
    var warmupDiscard: Int
    var metrics: [String: Double]
    var rawSamples: [String: [Double]]
  }

  private func runBenchRun() throws {
    let warmN = argInt("--warm") ?? 50
    let coldN = argInt("--cold") ?? 10
    let warmupDiscard = argInt("--warmup-discard") ?? 3
    let outPath = argValue("--out")

    let cfg = TurboDraftConfig.load()
    let socketPath = cfg.socketPath

    // Bench lockfile to prevent concurrent runs.
    let lockDir = try TurboDraftPaths.applicationSupportDir()
    let lockPath = lockDir.appendingPathComponent("bench.lock").path
    if FileManager.default.fileExists(atPath: lockPath) {
      let existingPid = try? String(contentsOfFile: lockPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let pidStr = existingPid, let pid = Int(pidStr), kill(pid_t(pid), 0) == 0 {
        throw CLIError.benchFailed("Another bench is running (PID \(pidStr))")
      }
      try? FileManager.default.removeItem(atPath: lockPath)
    }
    try "\(getpid())".write(toFile: lockPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: lockPath) }

    // Determine fixture paths: --fixture-dir iterates all .md files, --path uses a single file.
    let fixturePaths: [(path: String, suffix: String)]
    if let dir = argValue("--fixture-dir") {
      let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
      let mdFiles = files.filter { $0.hasSuffix(".md") }.sorted()
      guard !mdFiles.isEmpty else { throw CLIError.invalidArgs("no .md files in --fixture-dir") }
      fixturePaths = mdFiles.map { name in
        let fullPath = (dir as NSString).appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.size] as? Int) ?? 0
        return (path: fullPath, suffix: "_\(sizeSuffix(size))")
      }
    } else if let path = argValue("--path") {
      fixturePaths = [(path: path, suffix: "")]
    } else {
      throw CLIError.invalidArgs("bench run requires --path or --fixture-dir")
    }

    var allMetrics: [String: Double] = [:]
    var allRawSamples: [String: [Double]] = [:]
    var serverPid: Int?

    for (fixturePath, suffix) in fixturePaths {
      let fixtureURL = URL(fileURLWithPath: fixturePath)
      let originalContent = try String(contentsOf: fixtureURL, encoding: .utf8)
      defer {
        try? Data(originalContent.utf8).write(to: fixtureURL, options: [.atomic])
      }

      func killServer() {
        if let pid = serverPid {
          kill(pid_t(pid), SIGKILL)
          var status: Int32 = 0
          waitpid(pid_t(pid), &status, 0)
          serverPid = nil
        } else {
          _ = try? posixSpawnAndWait(command: "pkill", arguments: ["-9", "-f", "turbodraft-app"])
        }
        try? FileManager.default.removeItem(atPath: socketPath)
      }

      // Ensure app is running and capture server PID.
      do {
        let fd = try connectOrLaunch(socketPath: socketPath, timeoutMs: 60_000)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
        let hello = try sendHelloWithResult(conn)
        serverPid = hello.serverPid
        _ = try sendSessionOpen(conn, path: fixturePath, line: 1, column: 1)
      }
      Thread.sleep(forTimeInterval: 0.05)

      // --- Warm CLI open roundtrip (spawn 'turbodraft open' repeatedly) ---
      for _ in 0..<warmupDiscard {
        _ = try runCtrlGOpenOnce(path: fixturePath)
        Thread.sleep(forTimeInterval: 0.01)
      }
      var ctrlGSamplesMs: [Double] = []
      for _ in 0..<warmN {
        let start = DispatchTime.now().uptimeNanoseconds
        let code = try runCtrlGOpenOnce(path: fixturePath)
        if code != 0 { throw CLIError.benchFailed("spawned open exited \(code)") }
        let end = DispatchTime.now().uptimeNanoseconds
        ctrlGSamplesMs.append(Double(end - start) / 1_000_000.0)
        Thread.sleep(forTimeInterval: 0.01)
      }
      emitMetric("warm_cli_open_roundtrip", ctrlGSamplesMs, suffix: suffix, metrics: &allMetrics, rawSamples: &allRawSamples)
      // Compat aliases for one release cycle:
      allMetrics["warm_ctrl_g_to_editable_p95_ms\(suffix)"] = percentile(ctrlGSamplesMs, p: 0.95)
      allMetrics["warm_ctrl_g_to_editable_median_ms\(suffix)"] = percentile(ctrlGSamplesMs, p: 0.50)

      // --- Warm in-process open roundtrip (includes server timing decomposition) ---
      for _ in 0..<warmupDiscard {
        _ = try openViaSocket(socketPath: socketPath, path: fixturePath, line: 1, column: 1, timeoutMs: 60_000)
      }
      var openSamplesMs: [Double] = []
      var serverOpenSamplesMs: [Double] = []
      for _ in 0..<warmN {
        let fd = try connectOrLaunch(socketPath: socketPath, timeoutMs: 60_000)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
        _ = try sendHelloWithResult(conn)
        let start = DispatchTime.now().uptimeNanoseconds
        let openRes = try sendSessionOpen(conn, path: fixturePath, line: 1, column: 1)
        let end = DispatchTime.now().uptimeNanoseconds
        openSamplesMs.append(Double(end - start) / 1_000_000.0)
        if let srvMs = openRes.serverOpenMs {
          serverOpenSamplesMs.append(srvMs)
        }
      }
      emitMetric("warm_open_roundtrip", openSamplesMs, suffix: suffix, metrics: &allMetrics, rawSamples: &allRawSamples)
      if !serverOpenSamplesMs.isEmpty {
        emitMetric("warm_server_open", serverOpenSamplesMs, suffix: suffix, metrics: &allMetrics, rawSamples: &allRawSamples)
      }

      // --- Warm text engine microbenchmark (synthetic insertion + highlight) ---
      let initialText = originalContent
      // Warmup discard for textkit too.
      _ = syntheticTypingTimings(initialText: initialText, samples: warmupDiscard)
      let textKitTimings = syntheticTypingTimings(initialText: initialText, samples: warmN)
      emitMetric("warm_textkit_insert_and_style", textKitTimings, suffix: suffix, metrics: &allMetrics, rawSamples: &allRawSamples)
      // Compat alias:
      allMetrics["warm_textkit_highlight_p95_ms\(suffix)"] = percentile(textKitTimings, p: 0.95)
      allMetrics["warm_textkit_highlight_median_ms\(suffix)"] = percentile(textKitTimings, p: 0.50)

      // --- Warm RPC save roundtrip (uses actual fixture content for realistic payloads) ---
      do {
        let fd = try connectOrLaunch(socketPath: socketPath, timeoutMs: 60_000)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
        _ = try sendHelloWithResult(conn)
        let openRes = try sendSessionOpen(conn, path: fixturePath, line: 1, column: 1)

        for _ in 0..<warmupDiscard {
          _ = try sendSessionSave(conn, sessionId: openRes.sessionId, content: originalContent + "\n// warmup\n")
        }
        var saveSamplesMs: [Double] = []
        var serverSaveSamplesMs: [Double] = []
        for i in 0..<warmN {
          let mutatedContent = originalContent + "\n// bench save \(i)\n"
          let start = DispatchTime.now().uptimeNanoseconds
          let saveRes = try sendSessionSave(conn, sessionId: openRes.sessionId, content: mutatedContent)
          let end = DispatchTime.now().uptimeNanoseconds
          saveSamplesMs.append(Double(end - start) / 1_000_000.0)
          if let srvMs = saveRes.serverSaveMs {
            serverSaveSamplesMs.append(srvMs)
          }
        }
        emitMetric("warm_rpc_save_roundtrip", saveSamplesMs, suffix: suffix, metrics: &allMetrics, rawSamples: &allRawSamples)
        // Compat alias:
        allMetrics["warm_save_roundtrip_p95_ms\(suffix)"] = percentile(saveSamplesMs, p: 0.95)
        allMetrics["warm_save_roundtrip_median_ms\(suffix)"] = percentile(saveSamplesMs, p: 0.50)
        if !serverSaveSamplesMs.isEmpty {
          emitMetric("warm_server_save", serverSaveSamplesMs, suffix: suffix, metrics: &allMetrics, rawSamples: &allRawSamples)
        }
      }

      // --- Warm reflect bench with event-driven vs polling fallback tracking ---
      do {
        let fileURL = URL(fileURLWithPath: fixturePath)
        let fd = try connectOrLaunch(socketPath: socketPath, timeoutMs: 60_000)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
        _ = try sendHelloWithResult(conn)
        let openRes = try sendSessionOpen(conn, path: fixturePath, line: 1, column: 1)

        var lastRevision = openRes.revision
        // Warmup discard for reflect.
        for i in 0..<warmupDiscard {
          let warmupContent = "warmup reflect \(i)\n"
          try Data(warmupContent.utf8).write(to: fileURL, options: [.atomic])
          let wait = try sendSessionWaitForRevision(conn, sessionId: openRes.sessionId, baseRevision: lastRevision, timeoutMs: 5_000)
          lastRevision = wait.revision
          if !wait.changed || wait.content != warmupContent {
            let reload = try sendSessionReload(conn, sessionId: openRes.sessionId)
            lastRevision = reload.revision
          }
        }

        var reflectEventMs: [Double] = []
        var reflectPolledMs: [Double] = []
        var reflectAllMs: [Double] = []
        for i in 0..<warmN {
          let externalContent = "TurboDraft bench reflect \(i)\n" + String(repeating: "y", count: 2048)
          try Data(externalContent.utf8).write(to: fileURL, options: [.atomic])

          let start = DispatchTime.now().uptimeNanoseconds
          let wait = try sendSessionWaitForRevision(conn, sessionId: openRes.sessionId, baseRevision: lastRevision, timeoutMs: 5_000)
          var revision = wait.revision
          var matched = wait.changed && wait.content == externalContent
          var usedPollingFallback = false
          if !matched {
            usedPollingFallback = true
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
          if !matched { throw CLIError.benchFailed("reflect did not update within deadline") }

          let end = DispatchTime.now().uptimeNanoseconds
          let elapsedMs = Double(end - start) / 1_000_000.0
          reflectAllMs.append(elapsedMs)
          if usedPollingFallback {
            reflectPolledMs.append(elapsedMs)
          } else {
            reflectEventMs.append(elapsedMs)
          }
          lastRevision = revision
        }

        emitMetric("warm_agent_reflect", reflectAllMs, suffix: suffix, metrics: &allMetrics, rawSamples: &allRawSamples)
        if !reflectEventMs.isEmpty {
          emitMetric("warm_agent_reflect_event", reflectEventMs, suffix: suffix, metrics: &allMetrics, rawSamples: &allRawSamples)
        }
        allMetrics["warm_agent_reflect_polled_count\(suffix)"] = Double(reflectPolledMs.count)
        if Double(reflectPolledMs.count) > Double(warmN) * 0.10 {
          fputs("WARNING: \(reflectPolledMs.count)/\(warmN) reflect iterations used polling fallback\n", stderr)
        }
      }

      // --- Query typing latency + memory from bench metrics RPC ---
      do {
        let fd = try connectOrLaunch(socketPath: socketPath, timeoutMs: 60_000)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
        _ = try sendHelloWithResult(conn)
        let openRes = try sendSessionOpen(conn, path: fixturePath, line: 1, column: 1)
        if let benchResult = try? sendBenchMetrics(conn, sessionId: openRes.sessionId) {
          if !benchResult.typingLatencySamples.isEmpty {
            emitMetric("warm_typing_latency", benchResult.typingLatencySamples, suffix: suffix, metrics: &allMetrics, rawSamples: &allRawSamples)
          }
          allMetrics["peak_memory_resident_bytes\(suffix)"] = Double(benchResult.memoryResidentBytes)
          if let readyMs = benchResult.sessionOpenToReadyMs {
            allMetrics["warm_session_open_to_ready_ms\(suffix)"] = readyMs
          }
        }
      }

      // --- Quit latency (only for last fixture) ---
      if fixturePath == fixturePaths.last?.path {
        do {
          let fd = try connectOrLaunch(socketPath: socketPath, timeoutMs: 60_000)
          let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
          let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
          let hello = try sendHelloWithResult(conn)
          serverPid = hello.serverPid
          let quitStart = DispatchTime.now().uptimeNanoseconds
          _ = try quitViaConnection(conn)
          if let pid = serverPid {
            var quitStatus: Int32 = 0
            waitpid(pid_t(pid), &quitStatus, 0)
          }
          let quitMs = Double(DispatchTime.now().uptimeNanoseconds - quitStart) / 1_000_000.0
          allMetrics["warm_quit_latency_ms"] = quitMs
          print("warm_quit_latency_ms=\(String(format: "%.2f", quitMs))")
          serverPid = nil
        }
      }
    }

    // --- Cold measurements ---
    let coldPath = fixturePaths.first?.path ?? ""
    if coldN > 0, !coldPath.isEmpty {
      let fixtureURL = URL(fileURLWithPath: coldPath)
      let originalContent = try String(contentsOf: fixtureURL, encoding: .utf8)
      defer {
        try? Data(originalContent.utf8).write(to: fixtureURL, options: [.atomic])
      }

      // Kill any lingering server before cold runs.
      if let pid = serverPid {
        kill(pid_t(pid), SIGKILL)
        var s: Int32 = 0
        waitpid(pid_t(pid), &s, 0)
        serverPid = nil
      } else {
        _ = try? posixSpawnAndWait(command: "pkill", arguments: ["-9", "-f", "turbodraft-app"])
      }
      try? FileManager.default.removeItem(atPath: socketPath)
      Thread.sleep(forTimeInterval: 0.30)

      var coldSamplesMs: [Double] = []
      for _ in 0..<coldN {
        // Force non-resident cold path: kill with verification.
        if let pid = serverPid {
          kill(pid_t(pid), SIGKILL)
          var s: Int32 = 0
          waitpid(pid_t(pid), &s, 0)
          serverPid = nil
        } else {
          _ = try? posixSpawnAndWait(command: "pkill", arguments: ["-9", "-f", "turbodraft-app"])
        }
        let killDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while DispatchTime.now().uptimeNanoseconds < killDeadline {
          let rc = try? posixSpawnAndWait(command: "pgrep", arguments: ["-f", "turbodraft-app"])
          if rc != 0 { break }
          Thread.sleep(forTimeInterval: 0.05)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        Thread.sleep(forTimeInterval: 0.20)

        let start = DispatchTime.now().uptimeNanoseconds
        let code = try runCtrlGOpenOnce(path: coldPath)
        let end = DispatchTime.now().uptimeNanoseconds
        guard code == 0 else { throw CLIError.benchFailed("cold open exited \(code)") }
        coldSamplesMs.append(Double(end - start) / 1_000_000.0)

        // Capture new server PID for next kill.
        if let fd = try? connectOrLaunch(socketPath: socketPath, timeoutMs: 5_000) {
          let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
          let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
          if let hello = try? sendHelloWithResult(conn) {
            serverPid = hello.serverPid
          }
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
      emitMetric("cold_cli_open_roundtrip", coldSamplesMs, suffix: "", metrics: &allMetrics, rawSamples: &allRawSamples)
      // Compat aliases:
      allMetrics["cold_ctrl_g_to_editable_p95_ms"] = percentile(coldSamplesMs, p: 0.95)
      allMetrics["cold_ctrl_g_to_editable_median_ms"] = percentile(coldSamplesMs, p: 0.50)
    }

    // Cleanup: kill server.
    if let pid = serverPid {
      kill(pid_t(pid), SIGKILL)
      var s: Int32 = 0
      waitpid(pid_t(pid), &s, 0)
    } else {
      _ = try? posixSpawnAndWait(command: "pkill", arguments: ["-9", "-f", "turbodraft-app"])
      Thread.sleep(forTimeInterval: 0.5)
    }
    try? FileManager.default.removeItem(atPath: socketPath)

    if let outPath {
      let now = ISO8601DateFormatter().string(from: Date())
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let res = BenchRunResult(
        timestamp: now,
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        warmN: warmN,
        coldN: coldN,
        warmupDiscard: warmupDiscard,
        metrics: allMetrics,
        rawSamples: allRawSamples
      )
      let url = URL(fileURLWithPath: outPath)
      let data = try encoder.encode(res)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: [.atomic])
    }
  }

  private func sizeSuffix(_ bytes: Int) -> String {
    if bytes < 1_000 { return "\(bytes)b" }
    if bytes < 10_000 { return "\(bytes / 1_000)k" }
    if bytes < 100_000 { return "\(bytes / 1_000)k" }
    return "\(bytes / 1_000)k"
  }

  private func emitMetric(_ name: String, _ samples: [Double], suffix: String, metrics: inout [String: Double], rawSamples: inout [String: [Double]]) {
    let p95 = percentile(samples, p: 0.95)
    let median = percentile(samples, p: 0.50)
    print("\(name)_p95_ms\(suffix)=\(String(format: "%.2f", p95))")
    print("\(name)_median_ms\(suffix)=\(String(format: "%.2f", median))")
    metrics["\(name)_p95_ms\(suffix)"] = p95
    metrics["\(name)_median_ms\(suffix)"] = median
    rawSamples["\(name)\(suffix)"] = samples
  }

  private func runBenchCheck() throws {
    guard let resultsPath = argValue("--results") else { throw CLIError.invalidArgs("bench check requires --results") }
    let resultsData = try Data(contentsOf: URL(fileURLWithPath: resultsPath))
    let results = try JSONDecoder().decode(BenchRunResult.self, from: resultsData)

    // A/B comparison mode: --compare <previous.json>
    if let comparePath = argValue("--compare") {
      let prevData = try Data(contentsOf: URL(fileURLWithPath: comparePath))
      let prev = try JSONDecoder().decode(BenchRunResult.self, from: prevData)
      let thresholdPct = Double(argValue("--threshold-pct") ?? "5.0") ?? 5.0

      let commonKeys = Set(prev.rawSamples.keys).intersection(results.rawSamples.keys)
      var regressions: [String] = []
      print(String(format: "%-40s %10s %10s %8s %8s %s", "Metric", "Median A", "Median B", "Delta%", "p-value", "Verdict"))
      print(String(repeating: "-", count: 88))
      for key in commonKeys.sorted() {
        let a = prev.rawSamples[key] ?? []
        let b = results.rawSamples[key] ?? []
        guard a.count >= 3, b.count >= 3 else { continue }
        let medA = percentile(a, p: 0.50)
        let medB = percentile(b, p: 0.50)
        let deltaPct = medA != 0 ? (medB - medA) / medA * 100.0 : 0.0
        let pValue = mannWhitneyU(a, b)
        let significant = pValue < 0.05
        let verdict: String
        if significant && deltaPct > thresholdPct {
          verdict = "REGRESSION"
          regressions.append("\(key): \(String(format: "%.1f", deltaPct))% slower (p=\(String(format: "%.4f", pValue)))")
        } else if significant && deltaPct < -thresholdPct {
          verdict = "IMPROVEMENT"
        } else {
          verdict = "NO_CHANGE"
        }
        print(String(format: "%-40s %10.2f %10.2f %7.1f%% %8.4f %s", key, medA, medB, deltaPct, pValue, verdict))
      }
      if !regressions.isEmpty {
        throw CLIError.benchFailed("Regressions detected: " + regressions.joined(separator: "; "))
      }
      return
    }

    // Threshold mode: --baseline <file.json>
    guard let baselinePath = argValue("--baseline") else {
      throw CLIError.invalidArgs("bench check requires --baseline or --compare")
    }
    let baselineData = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
    let baseline = try JSONDecoder().decode([String: Double].self, from: baselineData)

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

  /// Mann-Whitney U test with normal approximation. Returns p-value.
  private func mannWhitneyU(_ a: [Double], _ b: [Double]) -> Double {
    let na = a.count
    let nb = b.count
    guard na > 0, nb > 0 else { return 1.0 }

    // Combine and rank.
    struct TaggedValue: Comparable {
      let value: Double
      let group: Int // 0 = a, 1 = b
      static func < (lhs: TaggedValue, rhs: TaggedValue) -> Bool { lhs.value < rhs.value }
    }
    var combined = a.map { TaggedValue(value: $0, group: 0) } + b.map { TaggedValue(value: $0, group: 1) }
    combined.sort()
    let n = combined.count

    // Assign average ranks for ties.
    var ranks = [Double](repeating: 0, count: n)
    var i = 0
    while i < n {
      var j = i + 1
      while j < n, combined[j].value == combined[i].value { j += 1 }
      let avgRank = Double(i + 1 + j) / 2.0
      for k in i..<j { ranks[k] = avgRank }
      i = j
    }

    var rankSumA = 0.0
    for k in 0..<n where combined[k].group == 0 {
      rankSumA += ranks[k]
    }
    let u1 = rankSumA - Double(na * (na + 1)) / 2.0
    let meanU = Double(na * nb) / 2.0
    let sigmaU = sqrt(Double(na * nb * (na + nb + 1)) / 12.0)
    guard sigmaU > 0 else { return 1.0 }
    let z = abs(u1 - meanU) / sigmaU
    // Two-tailed p-value approximation using error function.
    let p = erfc(z / sqrt(2.0))
    return min(1.0, p)
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

  @discardableResult
  private func sendHelloWithResult(_ conn: JSONRPCConnection) throws -> HelloResult {
    let hello = JSONRPCRequest(id: .int(1), method: TurboDraftMethod.hello, params: JSONValue.object([
      "client": .string("turbodraft-cli"),
      "clientVersion": .string("dev"),
    ]))
    try conn.sendJSON(hello)
    let resp = try conn.readResponse()
    guard let result = resp.result else {
      return HelloResult(protocolVersion: 1, capabilities: TurboDraftCapabilities(supportsWait: false, supportsAgentDraft: false, supportsQuit: false), serverPid: 0)
    }
    return try result.decode(HelloResult.self)
  }

  private func sendHello(_ conn: JSONRPCConnection) throws {
    _ = try sendHelloWithResult(conn)
  }

  private func sendSessionOpen(_ conn: JSONRPCConnection, path: String, line: Int?, column: Int?) throws -> SessionOpenResult {
    var paramsObj: [String: JSONValue] = ["path": .string(path)]
    if let line { paramsObj["line"] = .int(Int64(line)) }
    if let column { paramsObj["column"] = .int(Int64(column)) }
    let openReq = JSONRPCRequest(id: .int(2), method: TurboDraftMethod.sessionOpen, params: .object(paramsObj))
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
    let req = JSONRPCRequest(id: .int(3), method: TurboDraftMethod.sessionSave, params: .object([
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
    let req = JSONRPCRequest(id: .int(4), method: TurboDraftMethod.sessionReload, params: .object([
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
    let req = JSONRPCRequest(id: .int(5), method: TurboDraftMethod.sessionWaitForRevision, params: .object([
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
    let waitReq = JSONRPCRequest(id: .int(6), method: TurboDraftMethod.sessionWait, params: .object([
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
    let req = JSONRPCRequest(id: .int(7), method: TurboDraftMethod.appQuit, params: .null)
    try conn.sendJSON(req)
    let resp = try conn.readResponse()
    return resp.error == nil
  }

  private func sendBenchMetrics(_ conn: JSONRPCConnection, sessionId: String) throws -> BenchMetricsResult {
    let req = JSONRPCRequest(id: .int(8), method: TurboDraftMethod.benchMetrics, params: .object([
      "sessionId": .string(sessionId),
    ]))
    try conn.sendJSON(req)
    let resp = try conn.readResponse()
    if let err = resp.error {
      throw CLIError.connectFailed("benchMetrics error \(err.code): \(err.message)")
    }
    guard let result = resp.result else { throw CLIError.connectFailed("missing benchMetrics result") }
    return try result.decode(BenchMetricsResult.self)
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
    let cfg = TurboDraftConfig.load()
    let socketPath = cfg.socketPath
    let argv0 = args.first ?? "turbodraft"

    do {
      let code = try posixSpawnAndWait(command: argv0, arguments: ["open"] + baseArgs)
      if code == 0 {
        return 0
      }
    } catch {
      // Fall through.
    }

    if let exe = siblingExecutablePath(named: "turbodraft-open") {
      if let code = try? posixSpawnAndWait(command: exe, arguments: baseArgs), code == 0 {
        return 0
      }
    }

    do {
      let code = try posixSpawnAndWait(command: "turbodraft-open", arguments: baseArgs)
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

  private func syntheticTypingTimings(initialText: String, samples: Int) -> [Double] {
    if samples <= 0 { return [] }
    // Use NSMutableAttributedString to approximate NSTextStorage editing cost.
    let storage = NSMutableAttributedString(string: initialText)
    var cursor = storage.length
    var timingsMs: [Double] = []
    timingsMs.reserveCapacity(samples)

    let insertionPattern = Array("abcdefghijklmnopqrstuvwxyz ")

    for i in 0..<samples {
      let ch = String(insertionPattern[i % insertionPattern.count])
      let start = DispatchTime.now().uptimeNanoseconds

      // 1. Insert character (simulates NSTextStorage.replaceCharacters).
      let insertRange = NSRange(location: cursor, length: 0)
      storage.replaceCharacters(in: insertRange, with: ch)

      // 2. Compute changed line range.
      let chLen = (ch as NSString).length
      let changedRange = NSRange(location: cursor, length: chLen)
      let content = storage.string
      let lineRange = (content as NSString).lineRange(for: changedRange)

      // 3. Run highlighter.
      let highlights = MarkdownHighlighter.highlights(in: content, range: lineRange)

      // 4. Apply attributes back (simulates applyStyling).
      storage.beginEditing()
      let defaultAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      ]
      storage.setAttributes(defaultAttrs, range: lineRange)
      for h in highlights {
        // Map highlight kinds to dummy attributes (real colors require AppKit EditorTheme).
        var attrs: [NSAttributedString.Key: Any] = [:]
        switch h.kind {
        case .headerText(let level):
          attrs[.font] = NSFont.monospacedSystemFont(ofSize: CGFloat(17 - min(level, 4)), weight: .bold)
        case .strongText:
          attrs[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        case .codeFenceDelimiter, .codeFenceInfo, .codeBlockLine, .headerMarker,
             .listMarker, .quoteMarker, .horizontalRule, .inlineCodeDelimiter,
             .strongMarker, .emphasisMarker, .strikethroughMarker, .highlightMarker, .linkPunctuation:
          attrs[.foregroundColor] = NSColor.secondaryLabelColor
        default:
          attrs[.foregroundColor] = NSColor.labelColor
        }
        storage.addAttributes(attrs, range: h.range)
      }
      storage.endEditing()

      let end = DispatchTime.now().uptimeNanoseconds
      timingsMs.append(Double(end - start) / 1_000_000.0)
      cursor += chLen
    }

    return timingsMs
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
      // Best-effort launch: spawn turbodraft-app if available in PATH.
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
    let argv0 = args.first ?? "turbodraft"
    if argv0.contains("/") {
      let dir = URL(fileURLWithPath: argv0).deletingLastPathComponent()
      let candidate = dir.appendingPathComponent("turbodraft-app")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return (candidate, ["--start-hidden"])
      }
    }
    return (URL(fileURLWithPath: "/usr/bin/env"), ["turbodraft-app", "--start-hidden"])
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
    fputs("turbodraft: \(msg)\n\n", stderr)
    fputs(CLI.helpText + "\n", stderr)
    exit(2)
  case .connectFailed(let msg):
    fputs("turbodraft: \(msg)\n", stderr)
    exit(3)
  case .timeout:
    fputs("turbodraft: timeout\n", stderr)
    exit(4)
  case .benchFailed(let msg):
    fputs("turbodraft: bench failed: \(msg)\n", stderr)
    exit(5)
  }
} catch {
  fputs("turbodraft: \(error)\n", stderr)
  exit(1)
}
