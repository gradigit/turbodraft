import AppKit
import Foundation
import TurboDraftAgent
import TurboDraftConfig
import TurboDraftCore
import TurboDraftMarkdown
#if TURBODRAFT_USE_CODEEDIT_TEXTVIEW
import CodeEditTextView
#endif

#if TURBODRAFT_USE_CODEEDIT_TEXTVIEW
private typealias TurboDraftEditorTextView = TextView
#else
private typealias TurboDraftEditorTextView = NSTextView
#endif

@MainActor
final class EditorViewController: NSViewController {
  private let session: EditorSession
  private let config: TurboDraftConfig
  private var agentConfig: TurboDraftConfig.Agent

  private let banner = BannerView()
  private let scrollView = NSScrollView()
  private let textView: TurboDraftEditorTextView
  private let styler = MarkdownStyler()

  private let autosaveDebouncer = AsyncDebouncer()
  private let styleDebouncer = AsyncDebouncer()
  private let openStyleDebouncer = AsyncDebouncer()
  private let fullOpenStyleDebouncer = AsyncDebouncer()
  private let watcherDebouncer = AsyncDebouncer()
  private var autosaveMaxFlushTask: Task<Void, Never>?
  private var autosavePending = false
  private var autosaveInFlight = false

  private var watcher: DirectoryWatcher?
  private var isApplyingProgrammaticUpdate = false

  private let agentRow = NSStackView()
  private let agentButton = NSButton(title: "Improve Prompt", target: nil, action: nil)
  private let saveStatus = NSTextField(labelWithString: "Saved")
  private var agentAdapter: AgentAdapting?
  private var agentRunning = false
  private var attachedImages: [URL] = []
  private var _typingLatencies: [Double] = []

  var typingLatencySamples: [Double] { _typingLatencies }

  private enum SaveState {
    case saved
    case unsaved
    case saving
    case error
  }

  private var saveState: SaveState = .saved

  init(session: EditorSession, config: TurboDraftConfig) {
    self.session = session
    self.config = config
    self.agentConfig = config.agent
    #if TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    self.textView = TextView(
      string: "",
      font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      textColor: EditorTheme.primaryText,
      lineHeightMultiplier: 1.0,
      wrapLines: true,
      isEditable: true,
      isSelectable: true,
      letterSpacing: 1.0,
      delegate: nil
    )
    #else
    self.textView = NSTextView(frame: .zero)
    #endif
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    autosaveDebouncer.cancel()
    styleDebouncer.cancel()
    openStyleDebouncer.cancel()
    fullOpenStyleDebouncer.cancel()
    watcherDebouncer.cancel()
    autosaveMaxFlushTask?.cancel()
    watcher?.stop()
    for url in attachedImages { try? FileManager.default.removeItem(at: url) }
    NotificationCenter.default.removeObserver(self)
  }

  override func loadView() {
    let root = AppearanceTrackingView()
    root.onAppearanceChange = { [weak self] in
      self?.applyTheme()
    }
    view = root
    view.wantsLayer = true

    banner.isHidden = true
    banner.applyTheme()
    banner.onRestore = { [weak self] in
      Task { @MainActor in
        await self?.restoreFromBanner()
      }
    }

    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.documentView = textView

    #if TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    textView.isEditable = true
    textView.isSelectable = true
    textView.allowsUndo = true
    textView.wrapLines = true
    textView.edgeInsets = HorizontalEdgeInsets(left: 18, right: 18)
    textView.translatesAutoresizingMaskIntoConstraints = false

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleTextDidChange(_:)),
      name: TextView.textDidChangeNotification,
      object: textView
    )
    #else
    textView.isRichText = true
    textView.isEditable = true
    textView.isSelectable = true
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.importsGraphics = false
    textView.delegate = self
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.drawsBackground = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainerInset = NSSize(width: 18, height: 18)
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleTextDidChange(_:)),
      name: NSText.didChangeNotification,
      object: textView
    )
    #endif

    agentRow.orientation = .horizontal
    agentRow.spacing = 10
    agentRow.translatesAutoresizingMaskIntoConstraints = false

    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false

    saveStatus.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    saveStatus.lineBreakMode = .byTruncatingTail
    saveStatus.alignment = .left

    agentButton.target = self
    agentButton.action = #selector(runAgent)
    agentButton.refusesFirstResponder = true
    agentRow.addArrangedSubview(saveStatus)
    agentRow.addArrangedSubview(spacer)
    agentRow.addArrangedSubview(agentButton)
    saveStatus.setContentHuggingPriority(.required, for: .horizontal)
    saveStatus.setContentCompressionResistancePriority(.required, for: .horizontal)
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    agentButton.setContentHuggingPriority(.required, for: .horizontal)

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(banner)
    stack.addArrangedSubview(scrollView)
    stack.addArrangedSubview(agentRow)
    view.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stack.topAnchor.constraint(equalTo: view.topAnchor),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      banner.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
    ])

    applyAgentConfig()

    applyTheme()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    setSaveState(saveState)
    focusEditor()
  }

  func setAgentConfig(_ agent: TurboDraftConfig.Agent) {
    agentConfig = agent
    applyAgentConfig()
  }

  func runPromptEngineer() {
    runAgent()
  }

  func restorePreviousBuffer() {
    Task { @MainActor in
      await restoreFromBanner()
    }
  }

  func flushAutosaveNow(reason: String = "forced_flush") async {
    autosaveDebouncer.cancel()
    autosaveMaxFlushTask?.cancel()
    autosaveMaxFlushTask = nil

    if !autosavePending, let info = await session.currentInfo(), info.isDirty {
      autosavePending = true
    }
    await runAutosave(reason: reason)
  }

  private func applyTheme() {
    view.layer?.backgroundColor = EditorTheme.editorBackground.cgColor
    #if TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    textView.wantsLayer = true
    textView.layer?.backgroundColor = EditorTheme.editorBackground.cgColor
    textView.textColor = EditorTheme.primaryText
    #else
    textView.backgroundColor = EditorTheme.editorBackground
    textView.textColor = EditorTheme.primaryText
    textView.insertionPointColor = EditorTheme.caret
    #endif
    banner.applyTheme()
    setSaveState(saveState)
  }

  func focusEditor() {
    guard view.window != nil else { return }
    if isEditorFirstResponder() { return }
    let attemptFocus = { [weak self] in
      guard let self, let window = self.view.window else { return }
      if !window.isKeyWindow {
        window.makeKeyAndOrderFront(nil)
      }
      _ = window.makeFirstResponder(nil)
      _ = window.makeFirstResponder(self.textView)
      #if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
      let len = (self.textView.string as NSString).length
      var sel = self.textView.selectedRange()
      if sel.location == NSNotFound {
        sel = NSRange(location: len, length: 0)
      } else {
        sel = NSRange(location: min(sel.location, len), length: 0)
      }
      self.textView.setSelectedRange(sel)
      self.textView.scrollRangeToVisible(sel)
      #endif
    }

    attemptFocus()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { attemptFocus() }
  }

  func waitUntilEditorReady(timeoutMs: Int = 320) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, timeoutMs)) * 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if isEditorFirstResponder() {
        return true
      }
      focusEditor()
      try? await Task.sleep(nanoseconds: 8_000_000)
    }
    return isEditorFirstResponder()
  }

  private func isEditorFirstResponder() -> Bool {
    guard let window = view.window else { return false }
    guard let responder = window.firstResponder else { return false }
    if responder === textView {
      return true
    }
    #if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    if let view = responder as? NSView, view === textView {
      return true
    }
    #endif
    return false
  }

  var preferredResponderView: NSView { textView }

  func applySessionInfo(_ info: SessionInfo, moveCursorLine: Int?, column: Int?) {
    autosaveDebouncer.cancel()
    autosaveMaxFlushTask?.cancel()
    autosaveMaxFlushTask = nil
    autosavePending = info.isDirty

    // Clean up stale image temp files from the previous session.
    cleanUpAttachedImages()

    isApplyingProgrammaticUpdate = true
    textView.string = info.content
    isApplyingProgrammaticUpdate = false
    setSaveState(info.isDirty ? .unsaved : .saved)
    banner.set(message: info.bannerMessage, snapshotId: info.conflictSnapshotId)
    banner.isHidden = (info.bannerMessage == nil)
    // First paint fast path: style only initial visible/nearby content immediately,
    // then complete full styling shortly after.
    let fullRange = NSRange(location: 0, length: (info.content as NSString).length)
    let initialRange = initialOpenStylingRange(fullRange: fullRange)
    openStyleDebouncer.schedule(delayMs: 0) { [weak self] in
      guard let self else { return }
      await MainActor.run {
        self.applyStyling(forChangedRange: initialRange)
      }
    }
    let deferredStyleDelayMs = (config.editorMode == .ultraFast) ? 260 : 140
    fullOpenStyleDebouncer.schedule(delayMs: deferredStyleDelayMs) { [weak self] in
      guard let self else { return }
      await MainActor.run {
        self.applyStyling(forChangedRange: fullRange)
      }
    }
    if let line = moveCursorLine {
      moveCursor(toLine: line, column: column ?? 1)
    }
    attachWatcher(for: info.fileURL)

    if info.isDirty {
      scheduleAutosave()
    }
  }

  private func initialOpenStylingRange(fullRange: NSRange) -> NSRange {
    let eagerLimit = (config.editorMode == .ultraFast) ? 8_000 : 12_000
    if fullRange.length <= eagerLimit {
      return fullRange
    }

    let fullText = textView.string as NSString
    #if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    if let lm = textView.layoutManager, let tc = textView.textContainer {
      let visibleRect = scrollView.contentView.documentVisibleRect
      let glyph = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
      let char = lm.characterRange(forGlyphRange: glyph, actualGlyphRange: nil)
      let pad = (config.editorMode == .ultraFast) ? 1_200 : 2_000
      let start = max(0, char.location - pad)
      let end = min(fullRange.length, NSMaxRange(char) + pad)
      let padded = NSRange(location: start, length: max(0, end - start))
      return fullText.lineRange(for: padded)
    }
    #endif

    let fallbackLimit = (config.editorMode == .ultraFast) ? 4_500 : 8_000
    let fallback = NSRange(location: 0, length: min(fullRange.length, fallbackLimit))
    return fullText.lineRange(for: fallback)
  }

  private func attachWatcher(for fileURL: URL) {
    watcher?.stop()
    watcher = nil
    do {
      let w = try DirectoryWatcher(directoryURL: fileURL.deletingLastPathComponent())
      watcher = w
      w.start { [weak self] in
        guard let self else { return }
        Task { @MainActor in
          self.handleWatcherEvent()
        }
      }
    } catch {
      // Ignore watcher failures; autosave still works.
    }
  }

  private func handleWatcherEvent() {
    watcherDebouncer.schedule(delayMs: 0) { [weak self] in
      guard let self else { return }
      do {
        if let info = try await self.session.applyExternalDiskChange() {
          await MainActor.run {
            self.applySessionInfo(info, moveCursorLine: nil, column: nil)
          }
        }
      } catch {
        // Ignore; external changes can be transient.
      }
    }
  }

  @objc private func handleTextDidChange(_ note: Notification) {
    if isApplyingProgrammaticUpdate { return }
    let changeStartNs = DispatchTime.now().uptimeNanoseconds
    let content = textView.string
    setSaveState(.unsaved)
    Task { await session.updateBufferContent(content) }
    autosavePending = true
    scheduleAutosave()

    let changedRange: NSRange = {
      if let edited = textView.textStorage?.editedRange, edited.location != NSNotFound {
        return edited
      }
      if let updated = (note.userInfo?["NSUpdatedRange"] as? NSValue)?.rangeValue {
        return updated
      }
      // Fallback: style around insertion point instead of re-styling whole document.
      let cursor = max(0, min((content as NSString).length, textView.selectedRange().location))
      return NSRange(location: cursor, length: 0)
    }()
    let styleRange = stylingRange(forChangedRange: changedRange, in: content as NSString)
    styleDebouncer.schedule(delayMs: 10) { [weak self] in
      guard let self else { return }
      await MainActor.run {
        self.applyStyling(forChangedRange: styleRange)
        let endNs = DispatchTime.now().uptimeNanoseconds
        let latencyMs = Double(endNs - changeStartNs) / 1_000_000.0
        self.recordTypingLatency(latencyMs)
      }
    }
  }

  private func recordTypingLatency(_ ms: Double) {
    _typingLatencies.append(ms)
    if _typingLatencies.count > 100 {
      _typingLatencies.removeFirst()
    }
  }

  private func scheduleAutosave() {
    autosaveDebouncer.schedule(delayMs: config.autosaveDebounceMs) { [weak self] in
      guard let self else { return }
      await self.runAutosave(reason: "autosave_debounce")
    }

    if autosaveMaxFlushTask == nil {
      let delay = max(0, config.autosaveMaxFlushMs)
      autosaveMaxFlushTask = Task { [weak self] in
        if delay > 0 {
          try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
        }
        guard let self else { return }
        await MainActor.run {
          self.autosaveMaxFlushTask = nil
        }
        await self.runAutosave(reason: "autosave_max_flush")
      }
    }
  }

  private func runAutosave(reason: String) async {
    guard autosavePending else { return }
    if autosaveInFlight { return }
    autosaveInFlight = true
    defer { autosaveInFlight = false }

    await MainActor.run {
      self.setSaveState(.saving)
    }
    do {
      let info = try await session.autosave(reason: reason)
      await MainActor.run {
        let isDirty = info?.isDirty ?? false
        self.autosavePending = isDirty
        if isDirty {
          self.setSaveState(.unsaved)
          self.scheduleAutosave()
        } else {
          self.autosaveMaxFlushTask?.cancel()
          self.autosaveMaxFlushTask = nil
          self.setSaveState(.saved)
        }
      }
    } catch {
      await MainActor.run {
        self.setSaveState(.error)
      }
    }
  }

  private func stylingRange(forChangedRange changedRange: NSRange, in fullText: NSString) -> NSRange {
    let docRange = NSRange(location: 0, length: fullText.length)
    let safeChanged = NSIntersectionRange(changedRange, docRange)
    let lineRange = fullText.lineRange(for: safeChanged)
    let lineText = fullText.substring(with: lineRange)

    // If a fence delimiter line changes, everything after it may need restyling.
    let fenceDelimiterPattern = #"^\s*(`{3,}|~{3,})"#
    if lineText.range(of: fenceDelimiterPattern, options: .regularExpression) != nil {
      return NSRange(location: lineRange.location, length: docRange.length - lineRange.location)
    }
    return lineRange
  }

  private func applyStyling(forChangedRange range: NSRange) {
    isApplyingProgrammaticUpdate = true
    defer { isApplyingProgrammaticUpdate = false }

    let fullText = textView.string as NSString
    let lineRange = fullText.lineRange(for: range)
    let editorFont: NSFont
    let editorTextColor: NSColor
    #if TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    editorFont = textView.font
    editorTextColor = textView.textColor
    #else
    editorFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    editorTextColor = textView.textColor ?? EditorTheme.primaryText
    #endif
    let baseAttrs: [NSAttributedString.Key: Any] = [
      .font: editorFont,
      .foregroundColor: editorTextColor,
    ]

    guard let storage = textView.textStorage else { return }
    textView.undoManager?.disableUndoRegistration()
    storage.beginEditing()
    storage.setAttributes(baseAttrs, range: lineRange)

    let highlights = styler.highlights(in: fullText as String, range: lineRange)
    for h in highlights {
      storage.addAttributes(h.attributes, range: h.range)
    }

    storage.endEditing()
    textView.undoManager?.enableUndoRegistration()
  }

  private func moveCursor(toLine line: Int, column: Int) {
    let text = textView.string as NSString
    var currentLine = 1
    var idx = 0
    while idx < text.length, currentLine < line {
      let r = text.lineRange(for: NSRange(location: idx, length: 0))
      idx = NSMaxRange(r)
      currentLine += 1
    }
    let lineRange = text.lineRange(for: NSRange(location: idx, length: 0))
    let target = min(lineRange.location + max(0, column - 1), NSMaxRange(lineRange))
    #if TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    textView.selectionManager.setSelectedRange(NSRange(location: target, length: 0))
    textView.scrollToVisible(NSRect(x: 0, y: max(0, CGFloat(target) * 16.0), width: 1, height: 1))
    #else
    textView.setSelectedRange(NSRange(location: target, length: 0))
    textView.scrollRangeToVisible(NSRange(location: target, length: 0))
    #endif
  }

  private func restoreFromBanner() async {
    guard let snapId = banner.snapshotId else { return }
    if let info = await session.restoreSnapshot(id: snapId) {
      applySessionInfo(info, moveCursorLine: nil, column: nil)
    }
  }

  @objc private func runAgent() {
    guard !agentRunning else { return }
    guard agentConfig.enabled else {
      banner.set(message: "Prompt engineer is disabled. Enable it from the Agent menu.", snapshotId: nil)
      banner.isHidden = false
      return
    }

    if agentAdapter == nil {
      agentAdapter = makeAgentAdapter()
    }

    guard let adapter = agentAdapter else {
      banner.set(message: "Prompt engineer is not configured (install Codex CLI and ensure `codex` is in PATH).", snapshotId: nil)
      banner.isHidden = false
      return
    }

    let instruction = "" // adapter applies a default instruction when empty
    let basePrompt = textView.string
    let imagesToPass = attachedImages
    attachedImages = []

    let oldTitle = agentButton.title
    agentButton.title = "Improving..."
    agentButton.isEnabled = false
    agentRunning = true
    banner.set(message: "Running prompt engineer...", snapshotId: nil)
    banner.isHidden = false

    Task {
      defer {
        for url in imagesToPass { try? FileManager.default.removeItem(at: url) }
      }
      do {
        await flushAutosaveNow(reason: "agent_preflight")
        let draft = try await adapter.draft(prompt: basePrompt, instruction: instruction, images: imagesToPass)

        let currentText = await MainActor.run { self.textView.string }
        await session.updateBufferContent(currentText)
        let restoreId = await session.snapshot(reason: "before_agent_apply")

        await session.updateBufferContent(draft)
        if let info = try? await session.autosave(reason: "agent_apply") {
          await MainActor.run {
            self.applySessionInfo(info, moveCursorLine: nil, column: nil)
            self.banner.set(message: "Applied agent output. You can restore your previous buffer.", snapshotId: restoreId)
            self.banner.isHidden = false
          }
        } else {
          await MainActor.run {
            self.isApplyingProgrammaticUpdate = true
            self.textView.string = draft
            self.isApplyingProgrammaticUpdate = false

            let fullRange = NSRange(location: 0, length: (draft as NSString).length)
            self.applyStyling(forChangedRange: fullRange)
            self.banner.set(message: "Applied agent output (no file open, not saved).", snapshotId: restoreId)
            self.banner.isHidden = false
          }
        }
      } catch {
        await MainActor.run {
          self.banner.set(message: "Agent failed: \(error)", snapshotId: nil)
          self.banner.isHidden = false
        }
      }

      await MainActor.run {
        self.agentButton.title = oldTitle
        self.agentButton.isEnabled = true
        self.agentRunning = false
      }
    }
  }

  private func cleanUpAttachedImages() {
    for url in attachedImages { try? FileManager.default.removeItem(at: url) }
    attachedImages.removeAll()
  }

  private func applyAgentConfig() {
    agentRow.isHidden = false
    agentButton.isHidden = !agentConfig.enabled
    agentAdapter = agentConfig.enabled ? makeAgentAdapter() : nil
  }

  private func setSaveState(_ state: SaveState) {
    saveState = state
    switch state {
    case .saved:
      saveStatus.stringValue = "Saved"
      saveStatus.textColor = NSColor.systemGreen
    case .unsaved:
      saveStatus.stringValue = "Unsaved"
      saveStatus.textColor = NSColor.systemOrange
    case .saving:
      saveStatus.stringValue = "Saving..."
      saveStatus.textColor = EditorTheme.secondaryText
    case .error:
      saveStatus.stringValue = "Save Error"
      saveStatus.textColor = NSColor.systemRed
    }

    view.window?.isDocumentEdited = (state != .saved)
  }

  private func makeAgentAdapter() -> AgentAdapting? {
    switch agentConfig.backend {
    case .exec:
      return CodexPromptEngineerAdapter(
        command: agentConfig.command,
        model: agentConfig.model,
        timeoutMs: agentConfig.timeoutMs,
        webSearch: agentConfig.webSearch.rawValue,
        promptProfile: agentConfig.promptProfile.rawValue,
        reasoningEffort: agentConfig.reasoningEffort.rawValue,
        reasoningSummary: agentConfig.reasoningSummary.rawValue,
        extraArgs: agentConfig.args
      )
    case .appServer:
      return CodexAppServerPromptEngineerAdapter(
        command: agentConfig.command,
        model: agentConfig.model,
        timeoutMs: agentConfig.timeoutMs,
        webSearch: agentConfig.webSearch.rawValue,
        promptProfile: agentConfig.promptProfile.rawValue,
        reasoningEffort: agentConfig.reasoningEffort.rawValue,
        reasoningSummary: agentConfig.reasoningSummary.rawValue,
        extraArgs: agentConfig.args
      )
    }
  }
}

#if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
extension EditorViewController: NSTextViewDelegate {
  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    guard textView === self.textView else { return false }

    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      let selected = textView.selectedRange()
      guard let edit = MarkdownEnterBehavior.editForEnter(in: textView.string, selection: selected) else {
        return false
      }
      textView.insertText(edit.replacement, replacementRange: edit.replaceRange)
      textView.setSelectedRange(NSRange(location: edit.selectedLocation, length: 0))
      return true
    }

    if commandSelector == NSSelectorFromString("paste:") {
      return handleImagePaste()
    }

    return false
  }

  /// Returns true if an image was found on the pasteboard and handled (inserted placeholder + stored URL).
  /// Returns false to let NSTextView perform its default paste.
  private func handleImagePaste() -> Bool {
    let pb = NSPasteboard.general
    guard let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
          !images.isEmpty
    else { return false }

    for image in images {
      guard let url = saveTempImage(image) else { continue }
      attachedImages.append(url)
      let index = attachedImages.count
      textView.insertText("[image \(index)]", replacementRange: textView.selectedRange())
    }
    return true
  }

  private func saveTempImage(_ image: NSImage) -> URL? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { return nil }
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("turbodraft-img-\(UUID().uuidString).png")
    do {
      try png.write(to: url)
    } catch {
      return nil
    }
    return url
  }
}
#endif

@MainActor
// Already @MainActor via NSView inheritance.
final class BannerView: NSView {
  private let label = NSTextField(labelWithString: "")
  private let button = NSButton(title: "Restore", target: nil, action: nil)

  var snapshotId: String?
  var onRestore: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    applyTheme()

    label.font = NSFont.systemFont(ofSize: 12, weight: .medium)

    button.target = self
    button.action = #selector(tapped)
    button.refusesFirstResponder = true

    let stack = NSStackView(views: [label, button])
    stack.orientation = .horizontal
    stack.spacing = 10
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyTheme()
  }

  func applyTheme() {
    layer?.backgroundColor = EditorTheme.bannerBackground.cgColor
    label.textColor = EditorTheme.secondaryText
  }

  func set(message: String?, snapshotId: String?) {
    self.snapshotId = snapshotId
    label.stringValue = message ?? ""
    button.isHidden = (snapshotId == nil)
  }

  @objc private func tapped() { onRestore?() }
}

final class AppearanceTrackingView: NSView {
  var onAppearanceChange: (() -> Void)?

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onAppearanceChange?()
  }
}
