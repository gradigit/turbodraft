import AppKit
import Foundation

private final class HarnessTextView: NSTextView {
  var onControlG: (() -> Void)?

  private static func isControlG(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.control), !flags.contains(.command), !flags.contains(.option) else { return false }
    let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
    return chars == "g"
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if Self.isControlG(event) {
      onControlG?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if Self.isControlG(event) {
      onControlG?()
      return
    }
    super.keyDown(with: event)
  }
}

@MainActor
private final class HarnessWindowController: NSWindowController {
  enum BenchmarkMode: String {
    case startup
    case roundtrip
  }

  private final class RunState {
    let id: String
    let startedNs: UInt64
    let initialText: String
    var promptPadActivatedMs: Double?
    var promptPadLostFrontmostMs: Double?
    var harnessReactivatedMs: Double?

    init(id: String, startedNs: UInt64, initialText: String) {
      self.id = id
      self.startedNs = startedNs
      self.initialText = initialText
    }
  }

  private let fileURL: URL
  private let promptpadBin: String
  private let timeoutMs: Int
  private let logFileURL: URL?
  private let benchmarkMode: BenchmarkMode

  private let textView = HarnessTextView(frame: .zero)
  private let statusField = NSTextField(labelWithString: "Ready")
  private let runButton = NSButton(title: "Open External Editor (Ctrl+G)", target: nil, action: nil)
  private let infoField = NSTextField(labelWithString: "")

  private var runIndex = 0
  private var activeRun: RunState?
  private var activationObserver: NSObjectProtocol?
  private var localKeyMonitor: Any?

  init(fileURL: URL, promptpadBin: String, timeoutMs: Int, logFileURL: URL?, benchmarkMode: BenchmarkMode) {
    self.fileURL = fileURL
    self.promptpadBin = promptpadBin
    self.timeoutMs = timeoutMs
    self.logFileURL = logFileURL
    self.benchmarkMode = benchmarkMode

    let window = NSWindow(
      contentRect: NSRect(x: 220, y: 220, width: 920, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "PromptPad E2E Harness"
    window.contentMinSize = NSSize(width: 560, height: 420)
    window.animationBehavior = .none
    window.isReleasedWhenClosed = false

    super.init(window: window)
    buildUI()
    installActivationObserver()
    ensureFixtureFile()
    loadInitialText()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    if let activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    }
    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
    }
  }

  private func buildUI() {
    guard let window, let contentView = window.contentView else { return }
    contentView.wantsLayer = true

    let root = NSStackView()
    root.orientation = .vertical
    root.spacing = 10
    root.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(root)

    let header = NSStackView()
    header.orientation = .horizontal
    header.spacing = 10
    header.translatesAutoresizingMaskIntoConstraints = false

    runButton.target = self
    runButton.action = #selector(triggerExternalEditor)
    runButton.bezelStyle = .rounded

    statusField.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    statusField.textColor = NSColor.systemGreen
    statusField.lineBreakMode = .byTruncatingTail

    infoField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    infoField.textColor = NSColor.secondaryLabelColor
    infoField.lineBreakMode = .byTruncatingTail
    infoField.stringValue = "Fixture: \(fileURL.path) · mode=\(benchmarkMode.rawValue)"

    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false

    header.addArrangedSubview(runButton)
    header.addArrangedSubview(spacer)
    header.addArrangedSubview(statusField)
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false

    textView.isEditable = true
    textView.isSelectable = true
    textView.allowsUndo = true
    textView.isRichText = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.textContainerInset = NSSize(width: 16, height: 16)
    textView.drawsBackground = true
    textView.backgroundColor = NSColor.textBackgroundColor
    textView.onControlG = { [weak self] in
      self?.triggerExternalEditor()
    }
    scroll.documentView = textView

    root.addArrangedSubview(header)
    root.addArrangedSubview(infoField)
    root.addArrangedSubview(scroll)

    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
      root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
      root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
    ])
  }

  private func installActivationObserver() {
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      Task { @MainActor [weak self] in
        guard let self, let run = self.activeRun else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

        if self.isPromptPadApp(app), run.promptPadActivatedMs == nil {
          run.promptPadActivatedMs = self.elapsedMs(since: run.startedNs)
        }

        if let activated = run.promptPadActivatedMs, run.promptPadLostFrontmostMs == nil {
          if !self.isPromptPadApp(app) || app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            run.promptPadLostFrontmostMs = max(activated, self.elapsedMs(since: run.startedNs))
          }
        }

        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier, run.harnessReactivatedMs == nil {
          // Ignore early activation events before PromptPad had any chance to open.
          if run.promptPadActivatedMs != nil || self.activeRun != nil {
            run.harnessReactivatedMs = self.elapsedMs(since: run.startedNs)
          }
        }
      }
    }
  }

  fileprivate func installGlobalControlGMonitor() {
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
      if flags.contains(.control), !flags.contains(.command), !flags.contains(.option), chars == "g" {
        self.triggerExternalEditor()
        return nil
      }
      return event
    }
  }

  private func isPromptPadApp(_ app: NSRunningApplication) -> Bool {
    let name = (app.localizedName ?? "").lowercased()
    if name.contains("promptpad") {
      return true
    }
    if let executable = app.executableURL?.lastPathComponent.lowercased() {
      return executable.contains("promptpad")
    }
    return false
  }

  private func ensureFixtureFile() {
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        let seed = """
        # PromptPad E2E fixture

        This is the editable prompt fixture for end-to-end UX latency tests.
        """
        try seed.write(to: fileURL, atomically: true, encoding: .utf8)
      }
    } catch {
      setStatus("Fixture setup failed: \(error)", color: .systemRed)
    }
  }

  private func loadInitialText() {
    do {
      let text = try String(contentsOf: fileURL, encoding: .utf8)
      textView.string = text
    } catch {
      textView.string = ""
      setStatus("Fixture load failed: \(error)", color: .systemRed)
    }
  }

  fileprivate func ensureHarnessTextFocus() {
    guard let window else { return }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    _ = window.makeFirstResponder(textView)
  }

  @objc
  func triggerExternalEditor() {
    guard activeRun == nil else { return }
    runIndex += 1

    do {
      try textView.string.write(to: fileURL, atomically: true, encoding: .utf8)
    } catch {
      setStatus("Write failed: \(error)", color: .systemRed)
      emitRecord([
        "event": "e2e_run_error",
        "error": "write_failed",
        "message": String(describing: error),
        "runIndex": runIndex,
      ])
      return
    }

    let run = RunState(
      id: UUID().uuidString,
      startedNs: DispatchTime.now().uptimeNanoseconds,
      initialText: textView.string
    )
    activeRun = run

    let modeText = benchmarkMode == .roundtrip ? "roundtrip" : "startup"
    setStatus("Opening external editor (\(modeText))...", color: .systemOrange)

    let stderrPipe = Pipe()
    let process = Process()
    var args = ["open", "--path", fileURL.path, "--timeout-ms", String(timeoutMs)]
    if benchmarkMode == .roundtrip {
      args.append("--wait")
    }

    if promptpadBin.contains("/") {
      process.executableURL = URL(fileURLWithPath: promptpadBin)
      process.arguments = args
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [promptpadBin] + args
    }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderrPipe

    process.terminationHandler = { [weak self] proc in
      let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      let stderr = String(data: stderrData, encoding: .utf8) ?? ""
      Task { @MainActor in
        self?.completeRun(run: run, process: proc, stderr: stderr)
      }
    }

    do {
      try process.run()
    } catch {
      activeRun = nil
      setStatus("Launch failed: \(error)", color: .systemRed)
      emitRecord([
        "event": "e2e_run_error",
        "error": "launch_failed",
        "message": String(describing: error),
        "runId": run.id,
        "runIndex": runIndex,
      ])
    }
  }

  private func completeRun(run: RunState, process: Process, stderr: String) {
    defer { activeRun = nil }
    let endMs = elapsedMs(since: run.startedNs)

    let finalText: String
    do {
      finalText = try String(contentsOf: fileURL, encoding: .utf8)
    } catch {
      finalText = run.initialText
    }
    textView.string = finalText

    let textChanged = finalText != run.initialText
    let textFocusMs = ensureTextFocusAndMeasure(since: run.startedNs)
    let rc = Int(process.terminationStatus)
    let ok = (rc == 0) && textChanged

    setStatus(
      ok ? "Run \(runIndex) OK" : "Run \(runIndex) failed (rc=\(rc), changed=\(textChanged))",
      color: ok ? .systemGreen : .systemRed
    )

    var payload: [String: Any] = [
      "event": "e2e_run",
      "benchmarkMode": benchmarkMode.rawValue,
      "runId": run.id,
      "runIndex": runIndex,
      "filePath": fileURL.path,
      "returnCode": rc,
      "ok": ok,
      "textChangedByEditor": textChanged,
      "ctrlGToEditorCommandReturnMs": endMs,
      "harnessResidentBytes": harnessResidentBytes(),
      "ts": ISO8601DateFormatter().string(from: Date()),
    ]
    if benchmarkMode == .roundtrip {
      payload["ctrlGToEditorWaitReturnMs"] = endMs
    }
    if let v = run.promptPadActivatedMs { payload["ctrlGToPromptPadActiveMs"] = v }
    if let v = run.promptPadLostFrontmostMs { payload["ctrlGToPromptPadLostFrontmostMs"] = v }
    if let v = run.harnessReactivatedMs { payload["ctrlGToHarnessReactivatedMs"] = v }
    if let v = textFocusMs { payload["ctrlGToTextFocusMs"] = v }
    let stderrTrimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if !stderrTrimmed.isEmpty {
      payload["stderrTail"] = String(stderrTrimmed.suffix(400))
    }
    emitRecord(payload)
  }

  private func ensureTextFocusAndMeasure(since startedNs: UInt64) -> Double? {
    guard let window else { return nil }
    // Try once synchronously first.
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    _ = window.makeFirstResponder(textView)
    if window.firstResponder === textView {
      return elapsedMs(since: startedNs)
    }
    // Fallback: 2ms polling, 200ms timeout (reduced from 8ms/500ms to cut quantization noise).
    let deadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.002))
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      _ = window.makeFirstResponder(textView)
      if window.firstResponder === textView {
        return elapsedMs(since: startedNs)
      }
    }
    return window.firstResponder === textView ? elapsedMs(since: startedNs) : nil
  }

  private func elapsedMs(since startedNs: UInt64) -> Double {
    let now = DispatchTime.now().uptimeNanoseconds
    return Double(now - startedNs) / 1_000_000.0
  }

  private func harnessResidentBytes() -> Int64 {
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

  private func setStatus(_ text: String, color: NSColor) {
    statusField.stringValue = text
    statusField.textColor = color
  }

  private func emitRecord(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
    let line = data + Data([0x0A])

    if let str = String(data: line, encoding: .utf8) {
      FileHandle.standardOutput.write(str.data(using: .utf8) ?? Data())
      fflush(stdout)
    }

    guard let logFileURL else { return }
    do {
      try FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: logFileURL.path) {
        let fh = try FileHandle(forWritingTo: logFileURL)
        try fh.seekToEnd()
        try fh.write(contentsOf: line)
        try fh.close()
      } else {
        try line.write(to: logFileURL, options: .atomic)
      }
    } catch {
      // best effort log path
    }
  }
}

private final class HarnessAppDelegate: NSObject, NSApplicationDelegate {
  private var controller: HarnessWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let env = ProcessInfo.processInfo.environment

    let fixturePath = env["PROMPTPAD_E2E_FILE"] ?? {
      let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      return tmp.appendingPathComponent("promptpad-e2e-fixture.md").path
    }()
    let promptpadBin = env["PROMPTPAD_BIN"] ?? "promptpad"
    let timeoutMs = Int(env["PROMPTPAD_E2E_TIMEOUT_MS"] ?? "") ?? 600_000
    let logFileURL = env["PROMPTPAD_E2E_LOG"].flatMap { URL(fileURLWithPath: $0) }
    let mode = HarnessWindowController.BenchmarkMode(rawValue: (env["PROMPTPAD_E2E_MODE"] ?? "roundtrip").lowercased()) ?? .roundtrip

    let wc = HarnessWindowController(
      fileURL: URL(fileURLWithPath: fixturePath),
      promptpadBin: promptpadBin,
      timeoutMs: timeoutMs,
      logFileURL: logFileURL,
      benchmarkMode: mode
    )
    controller = wc
    wc.installGlobalControlGMonitor()
    wc.showWindow(nil)
    wc.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    wc.ensureHarnessTextFocus()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@main
struct PromptPadE2EHarnessMain {
  static func main() {
    let app = NSApplication.shared
    let delegate = HarnessAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
  }
}
