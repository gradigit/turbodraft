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
private typealias TurboDraftEditorTextView = EditorTextView
#endif

@MainActor
final class EditorViewController: NSViewController {
  private let session: EditorSession
  private let config: TurboDraftConfig
  private var editorMode: TurboDraftConfig.EditorMode
  private var agentConfig: TurboDraftConfig.Agent

  private let banner = BannerView()
  private let scrollView = NSScrollView()
  private let textView: TurboDraftEditorTextView
  private let styler = MarkdownStyler()
  private var colorTheme: EditorColorTheme = .defaultTheme

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

  private let findContainer = NSVisualEffectView()
  private let findStack = NSStackView()
  private let findRow = NSStackView()
  private let replaceRow = NSStackView()
  private let findField = NSSearchField()
  private let replaceField = NSTextField()
  private let findCountLabel = NSTextField(labelWithString: "")
  private let findPrevButton = NSButton(title: "Previous", target: nil, action: nil)
  private let findNextButton = NSButton(title: "Next", target: nil, action: nil)
  private let toggleReplaceButton = NSButton(title: "Replace", target: nil, action: nil)
  private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
  private let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)
  private let closeFindButton = NSButton(title: "Done", target: nil, action: nil)
  private let matchCaseButton = NSButton(title: "Aa", target: nil, action: nil)
  private let wholeWordButton = NSButton(title: "W", target: nil, action: nil)
  private let regexButton = NSButton(title: ".*", target: nil, action: nil)
  private var findCaseSensitive = false
  private var findWholeWord = false
  private var findRegexEnabled = false
  private var baseScrollInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
  private var defaultSelectedTextAttributes: [NSAttributedString.Key: Any]?
  private var allFindHighlightRanges: [NSRange] = []
  private var activeFindHighlightRange: NSRange?
  private var findFeedbackTask: Task<Void, Never>?
  private let maxVisibleFindHighlights = 700

  private let agentRow = NSStackView()
  private let agentButton = NSButton(title: "Improve Prompt", target: nil, action: nil)
  private let saveStatus = NSTextField(labelWithString: "Saved")
  private var agentAdapter: AgentAdapting?
  private var agentRunning = false
  private var sessionCwd: String?
  private var attachedImages: [String: URL] = [:]
  private var imageConversionTask: Task<Void, Never>?
  private var _typingLatencies: [Double] = []
  private var sessionOpenStartNs: UInt64?
  private var sessionOpenToReadyMsValue: Double?
  private let imagePlaceholderRegex = try! NSRegularExpression(pattern: #"\[image-([a-f0-9]{8})\]"#)
  private let listPrefixRegex = try! NSRegularExpression(
    pattern: #"^([ \t]*(?:>[ \t]*)*)(?:[-+*][ \t]+(?:\[[ xX]\][ \t]+)?|\d{1,9}[.)][ \t]+)"#
  )
  private let taskCheckboxRegex = try! NSRegularExpression(
    pattern: #"^([ \t]*(?:>[ \t]*)*)([-+*])([ \t]+)\[([ xX])\]([ \t]+)(.*)$"#
  )

  var typingLatencySamples: [Double] { _typingLatencies }
  var sessionOpenToReadyMs: Double? { sessionOpenToReadyMsValue }
  var stylerCacheEntryCount: Int { styler.cacheEntryCount }
  var stylerCacheLimit: Int { styler.cacheCapacity }

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
    self.editorMode = config.editorMode
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
    self.textView = EditorTextView(frame: .zero)
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
    findFeedbackTask?.cancel()
    watcher?.stop()
    for url in attachedImages.values { try? FileManager.default.removeItem(at: url) }
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
    banner.applyTheme(with: colorTheme)
    banner.onRestore = { [weak self] in
      Task { @MainActor in
        await self?.restoreFromBanner()
      }
    }

    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.documentView = textView
    baseScrollInsets = scrollView.contentInsets

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
    textView.usesFindPanel = true
    textView.isIncrementalSearchingEnabled = true
    textView.delegate = self
    textView.onImageDrop = { [weak self] images in
      self?.insertImages(images)
    }
    textView.onCommandEnter = { [weak self] in
      self?.view.window?.performClose(nil)
    }
    textView.onShowFind = { [weak self] in
      self?.showFind(replace: false)
    }
    textView.onShowReplace = { [weak self] in
      self?.showFind(replace: true)
    }
    textView.onFindNext = { [weak self] in
      self?.findNext()
    }
    textView.onFindPrevious = { [weak self] in
      self?.findPrevious()
    }
    textView.onUseSelectionForFind = { [weak self] in
      self?.useSelectionForFind()
    }
    textView.onCloseFind = { [weak self] in
      guard let self, !self.findContainer.isHidden else { return false }
      self.hideFind()
      return true
    }
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.drawsBackground = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainerInset = NSSize(width: 18, height: 18)
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    defaultSelectedTextAttributes = textView.selectedTextAttributes

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleTextDidChange(_:)),
      name: NSText.didChangeNotification,
      object: textView
    )
    #endif

    findContainer.material = .hudWindow
    findContainer.blendingMode = .withinWindow
    findContainer.state = .active
    findContainer.translatesAutoresizingMaskIntoConstraints = false
    findContainer.isHidden = true
    findContainer.wantsLayer = true
    findContainer.layer?.cornerRadius = 10
    findContainer.layer?.masksToBounds = true
    findContainer.layer?.borderWidth = 1
    findContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor

    findStack.orientation = .vertical
    findStack.spacing = 6
    findStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    findStack.translatesAutoresizingMaskIntoConstraints = false

    findRow.orientation = .horizontal
    findRow.spacing = 8
    findRow.alignment = .centerY
    findRow.distribution = .fill
    findRow.translatesAutoresizingMaskIntoConstraints = false

    findField.placeholderString = "Find"
    findField.sendsSearchStringImmediately = true
    findField.sendsWholeSearchString = false
    findField.controlSize = .small
    findField.focusRingType = .none
    findField.wantsLayer = true
    findField.layer?.cornerRadius = 6
    findField.layer?.borderWidth = 0.8
    findField.delegate = self
    findField.target = self
    findField.action = #selector(findFieldSubmitted(_:))
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(findFieldChanged(_:)),
      name: NSControl.textDidChangeNotification,
      object: findField
    )

    findCountLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    findCountLabel.textColor = colorTheme.secondaryText.withAlphaComponent(0.8)
    findCountLabel.alignment = .right
    findCountLabel.stringValue = ""

    findPrevButton.target = self
    findPrevButton.action = #selector(findPreviousAction(_:))
    findPrevButton.refusesFirstResponder = true
    findPrevButton.bezelStyle = .texturedRounded
    findPrevButton.controlSize = .small
    findNextButton.target = self
    findNextButton.action = #selector(findNextAction(_:))
    findNextButton.refusesFirstResponder = true
    findNextButton.bezelStyle = .texturedRounded
    findNextButton.controlSize = .small
    toggleReplaceButton.target = self
    toggleReplaceButton.action = #selector(toggleReplaceAction(_:))
    toggleReplaceButton.refusesFirstResponder = true
    toggleReplaceButton.bezelStyle = .texturedRounded
    toggleReplaceButton.controlSize = .small
    closeFindButton.target = self
    closeFindButton.action = #selector(closeFindAction(_:))
    closeFindButton.refusesFirstResponder = true
    closeFindButton.bezelStyle = .texturedRounded
    closeFindButton.controlSize = .small

    findRow.addArrangedSubview(findField)
    findRow.addArrangedSubview(findCountLabel)
    findRow.addArrangedSubview(findPrevButton)
    findRow.addArrangedSubview(findNextButton)
    findRow.addArrangedSubview(toggleReplaceButton)
    findRow.addArrangedSubview(closeFindButton)
    findField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    findField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    findCountLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    findCountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    replaceRow.orientation = .horizontal
    replaceRow.spacing = 8
    replaceRow.alignment = .centerY
    replaceRow.distribution = .fill
    replaceRow.translatesAutoresizingMaskIntoConstraints = false

    replaceField.placeholderString = "Replace"
    replaceField.controlSize = .small
    replaceField.focusRingType = .none
    replaceField.wantsLayer = true
    replaceField.layer?.cornerRadius = 6
    replaceField.layer?.borderWidth = 0.8
    replaceField.delegate = self
    replaceField.target = self
    replaceField.action = #selector(replaceFieldSubmitted(_:))
    replaceButton.target = self
    replaceButton.action = #selector(replaceNextAction(_:))
    replaceButton.refusesFirstResponder = true
    replaceButton.bezelStyle = .texturedRounded
    replaceButton.controlSize = .small
    replaceAllButton.target = self
    replaceAllButton.action = #selector(replaceAllAction(_:))
    replaceAllButton.refusesFirstResponder = true
    replaceAllButton.bezelStyle = .texturedRounded
    replaceAllButton.controlSize = .small
    matchCaseButton.target = self
    matchCaseButton.action = #selector(toggleMatchCaseAction(_:))
    matchCaseButton.setButtonType(.toggle)
    matchCaseButton.bezelStyle = .texturedRounded
    matchCaseButton.controlSize = .small
    matchCaseButton.toolTip = "Match Case"
    matchCaseButton.state = .off
    wholeWordButton.target = self
    wholeWordButton.action = #selector(toggleWholeWordAction(_:))
    wholeWordButton.setButtonType(.toggle)
    wholeWordButton.bezelStyle = .texturedRounded
    wholeWordButton.controlSize = .small
    wholeWordButton.toolTip = "Whole Word"
    wholeWordButton.state = .off
    regexButton.target = self
    regexButton.action = #selector(toggleRegexAction(_:))
    regexButton.setButtonType(.toggle)
    regexButton.bezelStyle = .texturedRounded
    regexButton.controlSize = .small
    regexButton.toolTip = "Regex"
    regexButton.state = .off

    replaceRow.addArrangedSubview(matchCaseButton)
    replaceRow.addArrangedSubview(wholeWordButton)
    replaceRow.addArrangedSubview(regexButton)
    replaceRow.addArrangedSubview(replaceField)
    replaceRow.addArrangedSubview(replaceButton)
    replaceRow.addArrangedSubview(replaceAllButton)
    replaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    replaceField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    replaceRow.isHidden = true

    findStack.addArrangedSubview(findRow)
    findStack.addArrangedSubview(replaceRow)
    findContainer.addSubview(findStack)
    NSLayoutConstraint.activate([
      findStack.leadingAnchor.constraint(equalTo: findContainer.leadingAnchor),
      findStack.trailingAnchor.constraint(equalTo: findContainer.trailingAnchor),
      findStack.topAnchor.constraint(equalTo: findContainer.topAnchor),
      findStack.bottomAnchor.constraint(equalTo: findContainer.bottomAnchor),
      findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
      replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
    ])

    agentRow.orientation = .horizontal
    agentRow.spacing = 10
    agentRow.translatesAutoresizingMaskIntoConstraints = false
    agentRow.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 6, right: 18)

    saveStatus.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    saveStatus.lineBreakMode = .byTruncatingTail
    saveStatus.alignment = .left
    saveStatus.translatesAutoresizingMaskIntoConstraints = false

    agentButton.target = self
    agentButton.action = #selector(runAgent)
    agentButton.refusesFirstResponder = true
    agentRow.addArrangedSubview(agentButton)
    agentButton.setContentHuggingPriority(.required, for: .horizontal)

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(banner)
    stack.addArrangedSubview(scrollView)
    stack.addArrangedSubview(agentRow)
    view.addSubview(stack)
    view.addSubview(saveStatus)
    view.addSubview(findContainer)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stack.topAnchor.constraint(equalTo: view.topAnchor),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      banner.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
      saveStatus.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 22),
      saveStatus.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 2),
      findContainer.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
      findContainer.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -12),
      findContainer.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 12),
      findContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
      findContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
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

  func setEditorMode(_ mode: TurboDraftConfig.EditorMode) {
    editorMode = mode
  }

  func runPromptEngineer() {
    runAgent()
  }

  func showFind(replace: Bool) {
    findContainer.isHidden = false
    replaceRow.isHidden = !replace
    toggleReplaceButton.title = replace ? "Hide Replace" : "Replace"
    matchCaseButton.state = findCaseSensitive ? .on : .off
    wholeWordButton.state = findWholeWord ? .on : .off
    regexButton.state = findRegexEnabled ? .on : .off
    updateFindCountLabel()
    updateCurrentFindHighlight()
    updateFindAvoidanceInset()
    applyFindControlTintTheme()
    DispatchQueue.main.async { [weak self] in
      self?.updateFindAvoidanceInset()
    }
    if replace {
      view.window?.makeFirstResponder(replaceField)
    } else {
      view.window?.makeFirstResponder(findField)
    }
  }

  func hideFind() {
    findContainer.isHidden = true
    findFeedbackTask?.cancel()
    clearAllFindHighlights()
    clearCurrentFindHighlight()
    restoreDefaultSelectionTheme()
    updateFindAvoidanceInset()
    view.window?.makeFirstResponder(textView)
  }

  func useSelectionForFind() {
    let selected = textView.selectedRange()
    guard selected.length > 0 else {
      showFind(replace: false)
      return
    }
    let ns = textView.string as NSString
    findField.stringValue = ns.substring(with: selected)
    showFind(replace: false)
  }

  func findNext() {
    guard let range = findMatch(forward: true) else {
      NSSound.beep()
      return
    }
    selectMatch(range)
  }

  func findPrevious() {
    guard let range = findMatch(forward: false) else {
      NSSound.beep()
      return
    }
    selectMatch(range)
  }

  func replaceNext() {
    guard !findField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      useSelectionForFind()
      return
    }

    let source = textView.string
    let selected = textView.selectedRange()
    let current: NSRange = {
      if let activeFindHighlightRange, selectedRangeMatchesQuery(activeFindHighlightRange) {
        return activeFindHighlightRange
      }
      return selected
    }()
    if selectedRangeMatchesQuery(current) {
      let replacementText = replacementString(for: current, in: source)
      _ = applyTextEdit(
        replacementRange: current,
        replacement: replacementText,
        selectedLocation: current.location + (replacementText as NSString).length,
        actionName: "Replace"
      )
      updateFindCountLabel()
      updateCurrentFindHighlight()
    } else if let range = findMatch(forward: true) {
      selectMatch(range)
      let replacementText = replacementString(for: range, in: source)
      _ = applyTextEdit(
        replacementRange: range,
        replacement: replacementText,
        selectedLocation: range.location + (replacementText as NSString).length,
        actionName: "Replace"
      )
      updateFindCountLabel()
      updateCurrentFindHighlight()
    } else {
      NSSound.beep()
    }
  }

  func replaceAll() {
    let query = findField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      NSSound.beep()
      return
    }
    let source = textView.string
    guard let result = TextSearchEngine.replaceAll(
      in: source,
      query: query,
      replacementTemplate: replaceField.stringValue,
      options: currentSearchOptions()
    ) else {
      NSSound.beep()
      return
    }
    let count = result.count
    guard count > 0 else {
      NSSound.beep()
      return
    }

    let fullRange = NSRange(location: 0, length: (source as NSString).length)
    _ = applyTextEdit(
      replacementRange: fullRange,
      replacement: result.text,
      selectedLocation: 0,
      actionName: "Replace All"
    )
    updateFindCountLabel()
    updateCurrentFindHighlight()
    showFindFeedback("\(count) replaced")
  }

  func restorePreviousBuffer() {
    Task { @MainActor in
      await restoreFromBanner()
    }
  }

  func prepareForIdlePool() {
    watcher?.stop()
    watcher = nil
    textView.undoManager?.removeAllActions()
    _typingLatencies.removeAll()
    sessionCwd = nil
    // Clear styler LRU cache to release attributed string memory.
    styler.setTheme(colorTheme)
    // Clear text storage so idle windows don't retain large documents.
    isApplyingProgrammaticUpdate = true
    textView.string = ""
    isApplyingProgrammaticUpdate = false
    sessionOpenStartNs = nil
    sessionOpenToReadyMsValue = nil
    // Clear session history snapshots (they're persisted in RecoveryStore).
    Task { await session.resetForRecycle() }
  }

  func flushAutosaveNow(reason: String = "forced_flush") async {
    autosaveDebouncer.cancel()
    autosaveMaxFlushTask?.cancel()
    autosaveMaxFlushTask = nil

    // On window/app close, wait for any pending image conversion, then copy
    // images to the clipboard so the user can Ctrl+V in the invoking CLI.
    if reason == "window_close" || reason == "app_terminate" {
      if let pending = imageConversionTask {
        // Race the conversion against a 2s timeout to prevent quit hang.
        await withTaskGroup(of: Void.self) { group in
          group.addTask { await pending.value }
          group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
          _ = await group.next()
          group.cancelAll()
        }
        imageConversionTask = nil
      }
      await appendImageReferencesForClose()
    }

    if !autosavePending, let info = await session.currentInfo(), info.isDirty {
      autosavePending = true
    }
    await runAutosave(reason: reason)
  }

  /// Scans text for `[image-XXXX]` placeholders, resolves them to `@/path`
  /// references prepended at the top, and strips the placeholders. Called on
  /// window/app close so the invoking CLI model reads images first.
  private func appendImageReferencesForClose() async {
    guard !attachedImages.isEmpty else { return }

    var text = textView.string

    let ids = imagePlaceholderIDs(in: text)
    let referencedURLs = ids.compactMap { attachedImages[$0] }

    // Remove all [image-XXXX] placeholders from the text.
    let ns = text as NSString
    let matches = imagePlaceholderRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    for match in matches.reversed() {
      if let r = Range(match.range, in: text) {
        text.replaceSubrange(r, with: "")
      }
    }

    // Prepend image references at the top so the model reads them first.
    if !referencedURLs.isEmpty {
      let refs = referencedURLs.map { "@\($0.path)" }.joined(separator: "\n")
      text = refs + "\n" + text
    }

    isApplyingProgrammaticUpdate = true
    textView.string = text
    isApplyingProgrammaticUpdate = false
    await session.updateBufferContent(text)
    autosavePending = true

    // Clear so deinit doesn't delete referenced files — the invoking CLI model
    // may still need them after editor close. Keep only still-referenced files.
    let referencedSet = Set(referencedURLs)
    for (id, url) in attachedImages where !referencedSet.contains(url) {
      try? FileManager.default.removeItem(at: url)
      attachedImages.removeValue(forKey: id)
    }
  }

  private func imagePlaceholderIDs(in text: String) -> [String] {
    let ns = text as NSString
    let matches = imagePlaceholderRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    var ids: [String] = []
    ids.reserveCapacity(matches.count)
    for m in matches {
      ids.append(ns.substring(with: m.range(at: 1)))
    }
    return ids
  }

  private func promptAndImagesForAgent(from text: String) -> (prompt: String, images: [URL]) {
    let ns = text as NSString
    let matches = imagePlaceholderRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return (text, []) }

    let mutable = NSMutableString(string: text)
    var images: [URL] = []
    var seen = Set<String>()
    for match in matches.reversed() {
      let id = ns.substring(with: match.range(at: 1))
      guard let url = attachedImages[id] else { continue }
      mutable.replaceCharacters(in: match.range, with: "@\(url.path)")
      if seen.insert(id).inserted {
        images.append(url)
      }
    }

    images.reverse()
    return (mutable as String, images)
  }

  private func pruneUnreferencedAttachedImages(using text: String) {
    let referenced = Set(imagePlaceholderIDs(in: text))
    for (id, url) in attachedImages where !referenced.contains(id) {
      try? FileManager.default.removeItem(at: url)
      attachedImages.removeValue(forKey: id)
    }
  }

  private func applyTheme() {
    let t = colorTheme
    view.layer?.backgroundColor = t.background.cgColor
    #if TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    textView.wantsLayer = true
    textView.layer?.backgroundColor = t.background.cgColor
    textView.textColor = t.foreground
    #else
    textView.backgroundColor = t.background
    textView.textColor = t.foreground
    textView.insertionPointColor = t.caret
    #endif
    let panelBg = t.banner.withAlphaComponent(0.98)
    findContainer.layer?.backgroundColor = panelBg.cgColor
    findContainer.layer?.borderColor = t.secondaryText.withAlphaComponent(0.28).cgColor
    findCountLabel.textColor = t.secondaryText.withAlphaComponent(0.8)
    let fieldText = t.isDark ? (t.foreground.blended(withFraction: 0.18, of: .white) ?? t.foreground) : t.foreground
    let fieldBorder = t.secondaryText.withAlphaComponent(0.38)
    findField.textColor = fieldText
    replaceField.textColor = fieldText
    findField.layer?.borderColor = fieldBorder.cgColor
    replaceField.layer?.borderColor = fieldBorder.cgColor
    findField.backgroundColor = t.background.withAlphaComponent(0.55)
    replaceField.backgroundColor = t.background.withAlphaComponent(0.55)
    applyFindControlTintTheme()
    if !findContainer.isHidden {
      updateCurrentFindHighlight()
    }
    banner.applyTheme(with: t)
    setSaveState(saveState)
  }

  func setColorTheme(_ theme: EditorColorTheme) {
    colorTheme = theme
    styler.setTheme(theme)
    applyTheme()
    let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
    if fullRange.length > 0 {
      applyStyling(forChangedRange: fullRange)
    }
  }

  func setFont(family: String, size: Int) {
    let sz = CGFloat(max(9, min(size, 72)))
    styler.rebuildFonts(family: family, size: sz)
    textView.font = styler.baseFont
    let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
    if fullRange.length > 0 {
      applyStyling(forChangedRange: fullRange)
    }
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
    recordSessionReadyIfNeeded()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { attemptFocus() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) { [weak self] in
      self?.recordSessionReadyIfNeeded()
    }
  }

  func waitUntilEditorReady(timeoutMs: Int = 320) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, timeoutMs)) * 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if isEditorFirstResponder() {
        recordSessionReadyIfNeeded()
        return true
      }
      focusEditor()
      try? await Task.sleep(nanoseconds: 8_000_000)
    }
    let ready = isEditorFirstResponder()
    if ready {
      recordSessionReadyIfNeeded()
    }
    return ready
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

  private func breakUndoCoalescingBoundary() {
    #if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    textView.breakUndoCoalescing()
    #endif
  }

  var preferredResponderView: NSView { textView }

  func applySessionInfo(_ info: SessionInfo, moveCursorLine: Int?, column: Int?) {
    autosaveDebouncer.cancel()
    autosaveMaxFlushTask?.cancel()
    autosaveMaxFlushTask = nil
    autosavePending = info.isDirty
    sessionCwd = info.cwd

    // Clean up stale image temp files from the previous session.
    cleanUpAttachedImages()

    isApplyingProgrammaticUpdate = true
    textView.string = info.content
    isApplyingProgrammaticUpdate = false
    sessionOpenStartNs = DispatchTime.now().uptimeNanoseconds
    sessionOpenToReadyMsValue = nil
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
    let deferredStyleDelayMs = (editorMode == .ultraFast) ? 260 : 140
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

  private func recordSessionReadyIfNeeded() {
    guard sessionOpenToReadyMsValue == nil else { return }
    guard let startNs = sessionOpenStartNs else { return }
    guard isEditorFirstResponder() else { return }
    let nowNs = DispatchTime.now().uptimeNanoseconds
    sessionOpenToReadyMsValue = Double(nowNs - startNs) / 1_000_000.0
  }

  private func initialOpenStylingRange(fullRange: NSRange) -> NSRange {
    let eagerLimit = (editorMode == .ultraFast) ? 8_000 : 12_000
    if fullRange.length <= eagerLimit {
      return fullRange
    }

    let fullText = textView.string as NSString
    #if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    if let lm = textView.layoutManager, let tc = textView.textContainer {
      let visibleRect = scrollView.contentView.documentVisibleRect
      let glyph = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
      let char = lm.characterRange(forGlyphRange: glyph, actualGlyphRange: nil)
      let pad = (editorMode == .ultraFast) ? 1_200 : 2_000
      let start = max(0, char.location - pad)
      let end = min(fullRange.length, NSMaxRange(char) + pad)
      let padded = NSRange(location: start, length: max(0, end - start))
      return fullText.lineRange(for: padded)
    }
    #endif

    let fallbackLimit = (editorMode == .ultraFast) ? 4_500 : 8_000
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
    if !findContainer.isHidden {
      updateFindCountLabel()
      updateCurrentFindHighlight()
    }
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
      // editedRange is only valid during processEditing; by the time
      // didChangeNotification fires it may already be NSNotFound.
      // Fall back to the full document so pastes always get styled.
      return NSRange(location: 0, length: (content as NSString).length)
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
    // Clamp range to current text length (range may be stale from debounce).
    let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: fullText.length))
    let lineRange = fullText.lineRange(for: safeRange)
    let editorFont: NSFont
    let editorTextColor: NSColor
    #if TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    editorFont = textView.font
    editorTextColor = colorTheme.foreground
    #else
    editorFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    // Don't read textView.textColor — NSTextView derives it from the text
    // storage, so our own highlight attributes (marker, heading) corrupt it.
    editorTextColor = colorTheme.foreground
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

    // Reset typingAttributes so stale styles don't bleed into new keystrokes.
    textView.typingAttributes = baseAttrs
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

  @discardableResult
  private func applyTextEdit(
    replacementRange: NSRange,
    replacement: String,
    selectedLocation: Int? = nil,
    actionName: String? = nil
  ) -> Bool {
    guard let storage = textView.textStorage else { return false }
    guard textView.shouldChangeText(in: replacementRange, replacementString: replacement) else { return false }
    if let actionName, let um = textView.undoManager {
      um.beginUndoGrouping()
      um.setActionName(actionName)
      defer { um.endUndoGrouping() }
      storage.replaceCharacters(in: replacementRange, with: replacement)
    } else {
      storage.replaceCharacters(in: replacementRange, with: replacement)
    }
    textView.didChangeText()
    if let selectedLocation {
      let clamped = max(0, min(selectedLocation, (textView.string as NSString).length))
      textView.setSelectedRange(NSRange(location: clamped, length: 0))
    }
    return true
  }

  private func replaceEntireDocumentWithUndo(_ content: String, actionName: String) {
    let current = textView.string as NSString
    _ = applyTextEdit(
      replacementRange: NSRange(location: 0, length: current.length),
      replacement: content,
      selectedLocation: (content as NSString).length,
      actionName: actionName
    )
    let fullRange = NSRange(location: 0, length: (content as NSString).length)
    applyStyling(forChangedRange: fullRange)
  }

  private func selectMatch(_ range: NSRange) {
    if isEditorFirstResponder() {
      textView.setSelectedRange(range)
    } else {
      textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }
    textView.scrollRangeToVisible(range)
    textView.showFindIndicator(for: range)
    highlightCurrentFindMatch(range)
  }

  private func updateFindAvoidanceInset() {
    findContainer.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    var insets = baseScrollInsets
    if !findContainer.isHidden {
      insets.top += findContainer.fittingSize.height + 4
    }
    scrollView.contentInsets = insets
    scrollView.scrollerInsets = NSEdgeInsets(top: insets.top, left: 0, bottom: 0, right: 0)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func clearAllFindHighlights() {
    guard let layout = textView.layoutManager else {
      allFindHighlightRanges.removeAll(keepingCapacity: true)
      return
    }
    let length = (textView.string as NSString).length
    for range in allFindHighlightRanges {
      let safe = NSIntersectionRange(range, NSRange(location: 0, length: length))
      guard safe.length > 0 else { continue }
      layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safe)
    }
    allFindHighlightRanges.removeAll(keepingCapacity: true)
  }

  private func clearCurrentFindHighlight() {
    guard let layout = textView.layoutManager, let range = activeFindHighlightRange else {
      activeFindHighlightRange = nil
      return
    }
    let length = (textView.string as NSString).length
    let safe = NSIntersectionRange(range, NSRange(location: 0, length: length))
    if safe.length > 0 {
      layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safe)
      layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: safe)
    }
    activeFindHighlightRange = nil
  }

  private func highlightCurrentFindMatch(_ range: NSRange) {
    clearCurrentFindHighlight()
    guard let layout = textView.layoutManager else { return }
    let bg = NSColor(calibratedRed: 1.0, green: 0.93, blue: 0.08, alpha: 0.96)
    layout.addTemporaryAttributes([
      .backgroundColor: bg,
      .foregroundColor: NSColor.black,
    ], forCharacterRange: range)
    activeFindHighlightRange = range
  }

  private func updateAllFindHighlights() {
    clearAllFindHighlights()
    guard !findContainer.isHidden, let layout = textView.layoutManager else { return }
    guard let summary = TextSearchEngine.summarizeMatches(
      in: textView.string,
      query: findField.stringValue,
      options: currentSearchOptions(),
      captureLimit: maxVisibleFindHighlights
    ) else { return }
    if summary.ranges.isEmpty { return }
    let bg = colorTheme.highlight.withAlphaComponent(colorTheme.isDark ? 0.22 : 0.15)
    for range in summary.ranges {
      layout.addTemporaryAttributes([.backgroundColor: bg], forCharacterRange: range)
      allFindHighlightRanges.append(range)
    }
  }

  private func updateCurrentFindHighlight() {
    guard !findContainer.isHidden else {
      clearAllFindHighlights()
      clearCurrentFindHighlight()
      restoreDefaultSelectionTheme()
      return
    }
    applyFindSelectionTheme()
    updateAllFindHighlights()
    if let active = activeFindHighlightRange, selectedRangeMatchesQuery(active) {
      if !isEditorFirstResponder() {
        textView.setSelectedRange(NSRange(location: active.location, length: 0))
      }
      highlightCurrentFindMatch(active)
      return
    }
    let current = textView.selectedRange()
    if selectedRangeMatchesQuery(current) {
      highlightCurrentFindMatch(current)
      return
    }
    if allFindHighlightRanges.isEmpty {
      clearCurrentFindHighlight()
      return
    }

    // If editor selection is broader than a single match (or find field has focus),
    // keep one "current" match pinned near the caret/selection anchor.
    let anchor = current.location
    if let containing = allFindHighlightRanges.first(where: {
      NSIntersectionRange($0, current).length > 0 || NSLocationInRange(anchor, $0)
    }) {
      if !isEditorFirstResponder() {
        textView.setSelectedRange(NSRange(location: containing.location, length: 0))
      }
      highlightCurrentFindMatch(containing)
      return
    }
    if let next = allFindHighlightRanges.first(where: { $0.location >= anchor }) {
      if !isEditorFirstResponder() {
        textView.setSelectedRange(NSRange(location: next.location, length: 0))
      }
      highlightCurrentFindMatch(next)
      return
    }
    if !isEditorFirstResponder() {
      textView.setSelectedRange(NSRange(location: allFindHighlightRanges[0].location, length: 0))
    }
    highlightCurrentFindMatch(allFindHighlightRanges[0])
  }

  private func applyFindSelectionTheme() {
    #if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    if defaultSelectedTextAttributes == nil {
      defaultSelectedTextAttributes = textView.selectedTextAttributes
    }
    textView.selectedTextAttributes = [
      .backgroundColor: NSColor(calibratedRed: 1.0, green: 0.93, blue: 0.12, alpha: 0.96),
      .foregroundColor: NSColor.black,
    ]
    #endif
  }

  private func restoreDefaultSelectionTheme() {
    #if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    if let attrs = defaultSelectedTextAttributes {
      textView.selectedTextAttributes = attrs
    }
    #endif
  }

  private func applyFindControlTintTheme() {
    let inactive = colorTheme.secondaryText.withAlphaComponent(0.92)
    let active = colorTheme.link
    for button in [
      findPrevButton, findNextButton, toggleReplaceButton, closeFindButton, replaceButton, replaceAllButton,
    ] {
      button.contentTintColor = inactive
    }
    matchCaseButton.contentTintColor = (matchCaseButton.state == .on) ? active : inactive
    wholeWordButton.contentTintColor = (wholeWordButton.state == .on) ? active : inactive
    regexButton.contentTintColor = (regexButton.state == .on) ? active : inactive
  }

  private func selectedRangeMatchesQuery(_ range: NSRange) -> Bool {
    guard range.length > 0, let re = findRegularExpression() else { return false }
    let source = textView.string
    guard let match = re.firstMatch(in: source, range: range) else { return false }
    return match.range == range
  }

  private func currentSearchOptions() -> TextSearchOptions {
    TextSearchOptions(
      caseSensitive: findCaseSensitive,
      wholeWord: findWholeWord,
      regexEnabled: findRegexEnabled
    )
  }

  private func findMatch(forward: Bool) -> NSRange? {
    let query = findField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      showFind(replace: false)
      return nil
    }
    guard let re = findRegularExpression() else { return nil }
    let source = textView.string
    let matches = re.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
    guard !matches.isEmpty else { return nil }

    let selected = textView.selectedRange()
    let active = (activeFindHighlightRange != nil && selectedRangeMatchesQuery(activeFindHighlightRange!)) ? activeFindHighlightRange! : nil

    if forward {
      let anchor = (active != nil) ? (active!.location + active!.length) : (selected.location + selected.length)
      if let next = matches.first(where: { $0.range.location >= anchor }) {
        return next.range
      }
      return matches.first?.range
    } else {
      let anchor = (active != nil) ? active!.location : selected.location
      if let prev = matches.last(where: { $0.range.location < anchor }) {
        return prev.range
      }
      return matches.last?.range
    }
  }

  private func findRegularExpression() -> NSRegularExpression? {
    TextSearchEngine.makeRegex(query: findField.stringValue, options: currentSearchOptions())
  }

  private func replacementString(for range: NSRange, in source: String) -> String {
    TextSearchEngine.replacementForMatch(
      in: source,
      range: range,
      query: findField.stringValue,
      replacementTemplate: replaceField.stringValue,
      options: currentSearchOptions()
    ) ?? replaceField.stringValue
  }

  private func updateFindCountLabel() {
    let query = findField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      findCountLabel.stringValue = ""
      return
    }
    guard let summary = TextSearchEngine.summarizeMatches(
      in: textView.string,
      query: query,
      options: currentSearchOptions(),
      captureLimit: 0
    ) else {
      findCountLabel.stringValue = findRegexEnabled ? "Invalid regex" : ""
      return
    }
    let count = summary.totalCount
    findCountLabel.stringValue = "\(count) match\(count == 1 ? "" : "es")"
  }

  private func showFindFeedback(_ message: String, durationMs: UInt64 = 1200) {
    findFeedbackTask?.cancel()
    findCountLabel.stringValue = message
    findFeedbackTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: durationMs * 1_000_000)
      await MainActor.run {
        self?.updateFindCountLabel()
      }
    }
  }

  @objc private func findFieldSubmitted(_ sender: Any?) {
    let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
    if shift {
      findPrevious()
    } else {
      findNext()
    }
  }

  @objc private func replaceFieldSubmitted(_ sender: Any?) {
    replaceNext()
  }

  @objc private func findFieldChanged(_ note: Notification) {
    guard note.object as? NSSearchField === findField else { return }
    updateFindCountLabel()
    updateCurrentFindHighlight()
  }

  @objc private func findPreviousAction(_ sender: Any?) { findPrevious() }
  @objc private func findNextAction(_ sender: Any?) { findNext() }
  @objc private func toggleReplaceAction(_ sender: Any?) {
    let show = replaceRow.isHidden
    replaceRow.isHidden = !show
    toggleReplaceButton.title = show ? "Hide Replace" : "Replace"
    updateFindAvoidanceInset()
    DispatchQueue.main.async { [weak self] in
      self?.updateFindAvoidanceInset()
    }
    applyFindControlTintTheme()
    if show {
      view.window?.makeFirstResponder(replaceField)
    } else {
      view.window?.makeFirstResponder(findField)
    }
  }
  @objc private func toggleMatchCaseAction(_ sender: Any?) {
    findCaseSensitive = (matchCaseButton.state == .on)
    updateFindCountLabel()
    updateCurrentFindHighlight()
    applyFindControlTintTheme()
  }
  @objc private func toggleWholeWordAction(_ sender: Any?) {
    findWholeWord = (wholeWordButton.state == .on)
    updateFindCountLabel()
    updateCurrentFindHighlight()
    applyFindControlTintTheme()
  }
  @objc private func toggleRegexAction(_ sender: Any?) {
    findRegexEnabled = (regexButton.state == .on)
    updateFindCountLabel()
    updateCurrentFindHighlight()
    applyFindControlTintTheme()
  }
  @objc private func replaceNextAction(_ sender: Any?) { replaceNext() }
  @objc private func replaceAllAction(_ sender: Any?) { replaceAll() }
  @objc private func closeFindAction(_ sender: Any?) { hideFind() }

  private func restoreFromBanner() async {
    guard let snapId = banner.snapshotId else { return }
    if let info = await session.restoreSnapshot(id: snapId) {
      replaceEntireDocumentWithUndo(info.content, actionName: "Restore Previous Buffer")
      breakUndoCoalescingBoundary()
      banner.set(message: info.bannerMessage, snapshotId: info.conflictSnapshotId)
      banner.isHidden = (info.bannerMessage == nil)
      pruneUnreferencedAttachedImages(using: info.content)
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

    let oldTitle = agentButton.title
    agentButton.title = "Improving..."
    agentButton.isEnabled = false
    agentRunning = true
    banner.set(message: "Running prompt engineer...", snapshotId: nil)
    banner.isHidden = false

    Task {
      // Wait for any pending background image conversion to finish.
      if let pending = imageConversionTask {
        await pending.value
        imageConversionTask = nil
      }
      let resolved = await MainActor.run { self.promptAndImagesForAgent(from: basePrompt) }
      do {
        await flushAutosaveNow(reason: "agent_preflight")
        let draft = try await adapter.draft(prompt: resolved.prompt, instruction: instruction, images: resolved.images, cwd: self.sessionCwd)

        let currentText = await MainActor.run { self.textView.string }
        await session.updateBufferContent(currentText)
        let restoreId = await session.snapshot(reason: "before_agent_apply")
        await MainActor.run {
          self.replaceEntireDocumentWithUndo(draft, actionName: "Improve Prompt")
          self.breakUndoCoalescingBoundary()
          self.banner.set(message: "Applied agent output. You can restore your previous buffer.", snapshotId: restoreId)
          self.banner.isHidden = false
          self.pruneUnreferencedAttachedImages(using: self.textView.string)
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
    for url in attachedImages.values { try? FileManager.default.removeItem(at: url) }
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
      saveStatus.textColor = colorTheme.secondaryText.withAlphaComponent(0.7)
    case .unsaved:
      saveStatus.stringValue = "Edited"
      saveStatus.textColor = colorTheme.secondaryText
    case .saving:
      saveStatus.stringValue = "Saving..."
      saveStatus.textColor = colorTheme.secondaryText.withAlphaComponent(0.7)
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
    case .claude:
      return ClaudePromptEngineerAdapter(
        command: agentConfig.command,
        model: agentConfig.model,
        timeoutMs: agentConfig.timeoutMs,
        promptProfile: agentConfig.promptProfile.rawValue,
        reasoningEffort: agentConfig.reasoningEffort.rawValue,
        extraArgs: agentConfig.args
      )
    }
  }
}

#if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
extension EditorViewController: NSSearchFieldDelegate, NSTextFieldDelegate {
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      hideFind()
      return true
    }
    return false
  }
}

extension EditorViewController: NSTextViewDelegate {
  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    guard textView === self.textView else { return false }

    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      let selected = textView.selectedRange()
      guard let edit = MarkdownEnterBehavior.editForEnter(in: textView.string, selection: selected) else {
        return false
      }
      guard applyTextEdit(
        replacementRange: edit.replaceRange,
        replacement: edit.replacement,
        selectedLocation: edit.selectedLocation,
        actionName: "Insert Newline"
      ) else {
        return false
      }
      renumberOrderedListAroundCursor()
      return true
    }

    if commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
      let selected = textView.selectedRange()
      if isCursorInMarkdownListLine(selected.location, text: textView.string) {
        return applyTextEdit(
          replacementRange: selected,
          replacement: "\n",
          selectedLocation: selected.location + 1,
          actionName: "Insert Line Break"
        )
      }
      return false
    }

    if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
      if handleSmartListBackspace() {
        renumberOrderedListAroundCursor()
        return true
      }
      return false
    }

    if commandSelector == #selector(NSResponder.insertTab(_:)) {
      if shiftSelectedListLines(direction: .right) {
        renumberOrderedListAroundCursor()
        return true
      }
      return false
    }

    if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
      if shiftSelectedListLines(direction: .left) {
        renumberOrderedListAroundCursor()
        return true
      }
      return false
    }

    return false
  }

  func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
    guard textView === self.textView else { return true }
    guard affectedCharRange.length == 0, replacementString == " " else { return true }
    return !handleTaskCheckboxToggle(at: affectedCharRange.location)
  }

  private enum ShiftDirection {
    case left
    case right
  }

  private func isCursorInMarkdownListLine(_ cursor: Int, text: String) -> Bool {
    let ns = text as NSString
    let safeCursor = max(0, min(cursor, ns.length))
    let line = ns.lineRange(for: NSRange(location: safeCursor, length: 0))
    let content = ns.substring(with: trimTrailingNewline(in: line, text: ns))
    let full = NSRange(location: 0, length: (content as NSString).length)
    return listPrefixRegex.firstMatch(in: content, range: full) != nil
  }

  private func handleSmartListBackspace() -> Bool {
    let sel = textView.selectedRange()
    guard sel.length == 0 else { return false }

    let text = textView.string
    let ns = text as NSString
    guard sel.location > 0, sel.location <= ns.length else { return false }
    let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
    let contentRange = trimTrailingNewline(in: lineRange, text: ns)
    let line = ns.substring(with: contentRange)
    let lineNS = line as NSString
    let full = NSRange(location: 0, length: lineNS.length)

    guard let prefixMatch = listPrefixRegex.firstMatch(in: line, range: full) else {
      return false
    }
    let prefixLen = prefixMatch.range.length
    let cursorInLine = sel.location - contentRange.location
    guard cursorInLine == prefixLen else { return false }

    let prefix = lineNS.substring(with: prefixMatch.range)
    let body = lineNS.substring(from: prefixLen)

    if let outdented = outdentedPrefix(prefix), !outdented.isEmpty {
      let replacement = outdented + body
      return applyTextEdit(
        replacementRange: contentRange,
        replacement: replacement,
        selectedLocation: contentRange.location + (outdented as NSString).length,
        actionName: "Outdent List Item"
      )
    }

    return applyTextEdit(
      replacementRange: NSRange(location: contentRange.location, length: prefixLen),
      replacement: "",
      selectedLocation: contentRange.location,
      actionName: "Remove List Marker"
    )
  }

  private func shiftSelectedListLines(direction: ShiftDirection) -> Bool {
    let selection = textView.selectedRange()
    let text = textView.string
    let ns = text as NSString
    let docLen = ns.length
    if docLen == 0 { return false }

    let safeStart = max(0, min(selection.location, docLen))
    let safeEnd = max(safeStart, min(selection.location + selection.length, docLen))
    let startLine = ns.lineRange(for: NSRange(location: safeStart, length: 0)).location
    let endLineRange = ns.lineRange(for: NSRange(location: max(0, safeEnd == docLen ? docLen : safeEnd), length: 0))
    let blockEnd = NSMaxRange(endLineRange)
    let blockRange = NSRange(location: startLine, length: blockEnd - startLine)
    var block = ns.substring(with: blockRange)

    let lines = block.components(separatedBy: "\n")
    var changed = false
    let adjusted = lines.map { line -> String in
      let lineNS = line as NSString
      let full = NSRange(location: 0, length: lineNS.length)
      guard listPrefixRegex.firstMatch(in: line, range: full) != nil else { return line }
      switch direction {
      case .right:
        changed = true
        return "  " + line
      case .left:
        if line.hasPrefix("\t") {
          changed = true
          return String(line.dropFirst())
        }
        if line.hasPrefix("  ") {
          changed = true
          return String(line.dropFirst(2))
        }
        if line.hasPrefix(" ") {
          changed = true
          return String(line.dropFirst())
        }
        return line
      }
    }

    guard changed else { return false }
    block = adjusted.joined(separator: "\n")
    let delta = (block as NSString).length - blockRange.length
    let newSelection = NSRange(location: selection.location, length: max(0, selection.length + delta))
    return applyTextEdit(
      replacementRange: blockRange,
      replacement: block,
      selectedLocation: newSelection.location + newSelection.length,
      actionName: direction == .right ? "Indent List Items" : "Outdent List Items"
    )
  }

  private func outdentedPrefix(_ prefix: String) -> String? {
    guard !prefix.isEmpty else { return nil }
    if prefix.hasPrefix("\t") {
      return String(prefix.dropFirst())
    }
    if prefix.hasPrefix("  ") {
      return String(prefix.dropFirst(2))
    }
    if prefix.hasPrefix(" ") {
      return String(prefix.dropFirst())
    }
    return nil
  }

  private func trimTrailingNewline(in range: NSRange, text: NSString) -> NSRange {
    var trimmed = range
    if trimmed.length > 0, text.character(at: NSMaxRange(trimmed) - 1) == 0x0A {
      trimmed.length -= 1
    }
    if trimmed.length > 0, text.character(at: NSMaxRange(trimmed) - 1) == 0x0D {
      trimmed.length -= 1
    }
    return trimmed
  }

  private func renumberOrderedListAroundCursor() {
    let current = textView.string
    let cursor = textView.selectedRange().location
    guard let renumbered = MarkdownOrderedListRenumbering.renumber(document: current, around: cursor),
          renumbered != current
    else { return }

    let oldSelection = textView.selectedRange()
    _ = applyTextEdit(
      replacementRange: NSRange(location: 0, length: (current as NSString).length),
      replacement: renumbered,
      selectedLocation: oldSelection.location,
      actionName: "Renumber List"
    )
  }

  private func handleTaskCheckboxToggle(at location: Int) -> Bool {
    let text = textView.string
    let ns = text as NSString
    guard location >= 0, location <= ns.length else { return false }
    let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
    let contentRange = trimTrailingNewline(in: lineRange, text: ns)
    let line = ns.substring(with: contentRange)
    let lineNS = line as NSString
    let full = NSRange(location: 0, length: lineNS.length)
    guard let m = taskCheckboxRegex.firstMatch(in: line, range: full) else { return false }

    let checkboxLoc = contentRange.location + m.range(at: 4).location
    guard location == checkboxLoc || location == checkboxLoc + 1 else { return false }

    let current = lineNS.substring(with: m.range(at: 4)).lowercased()
    let replacement = current == "x" ? " " : "x"
    return applyTextEdit(
      replacementRange: NSRange(location: checkboxLoc, length: 1),
      replacement: replacement,
      selectedLocation: checkboxLoc + 1,
      actionName: "Toggle Checkbox"
    )
  }

  /// Shared image insertion logic for paste and drag-and-drop.
  /// Inserts `[image-XXXX]` placeholders immediately, converts TIFF→PNG in background.
  private func insertImages(_ images: [NSImage]) {
    var ids: [String] = []
    for _ in images {
      let id = UUID().uuidString.prefix(8).lowercased()
      ids.append(String(id))
      textView.insertText("[image-\(id)]", replacementRange: textView.selectedRange())
    }
    let imagesToConvert = images
    let converter = Task.detached(priority: .utility) { [ids, imagesToConvert] in
      var pairs: [(String, URL)] = []
      for (i, image) in imagesToConvert.enumerated() {
        if let url = Self.saveTempImageBackground(image) {
          pairs.append((ids[i], url))
        }
      }
      return pairs
    }
    imageConversionTask = Task { [weak self] in
      let pairs = await converter.value
      guard let self else { return }
      for (id, url) in pairs {
        self.attachedImages[id] = url
      }
    }
  }

  private nonisolated static func saveTempImageBackground(_ image: NSImage) -> URL? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { return nil }
    let imagesDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/TurboDraft/images", isDirectory: true)
    try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    let url = imagesDir.appendingPathComponent("turbodraft-img-\(UUID().uuidString).png")
    do {
      try png.write(to: url)
    } catch {
      return nil
    }
    return url
  }
}
#endif

#if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
/// Thin NSTextView subclass that adds drag-and-drop and paste support for images.
/// Non-image drags/pastes fall through to NSTextView's default behavior.
final class EditorTextView: NSTextView {
  var onImageDrop: (([NSImage]) -> Void)?
  var onCommandEnter: (() -> Void)?
  var onShowFind: (() -> Void)?
  var onShowReplace: (() -> Void)?
  var onFindNext: (() -> Void)?
  var onFindPrevious: (() -> Void)?
  var onUseSelectionForFind: (() -> Void)?
  var onCloseFind: (() -> Bool)?

  private static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "webp", "heic",
  ]

  override init(frame: NSRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    registerForDraggedTypes([.fileURL])
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([.fileURL])
  }

  // MARK: - Paste (Cmd+V / Ctrl+V)

  /// Intercept Cmd+V before the menu system to check for image content.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let chars = event.charactersIgnoringModifiers ?? ""

    if mods == .command && (event.keyCode == 36 || event.keyCode == 76) {
      onCommandEnter?()
      return true
    }

    // Explicit find/replace key routing for reliability in custom text view.
    if mods == .command, chars == "f" {
      onShowFind?()
      return true
    }
    if mods == [.command, .option], chars == "f" {
      onShowReplace?()
      return true
    }
    if mods == .command, chars == "g" {
      onFindNext?()
      return true
    }
    if mods == [.command, .shift], chars == "g" {
      onFindPrevious?()
      return true
    }
    if mods == .command, chars == "e" {
      onUseSelectionForFind?()
      return true
    }

    if mods == .command, chars == "v" {
      if handleImagePaste() { return true }
      if handleFileURLPasteAsPaths(excludingImageFiles: true) { return true }
      if handleURLPasteAsMarkdownLink() { return true }
    }
    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if mods.isEmpty, event.keyCode == 53, onCloseFind?() == true {  // Esc
      return
    }

    let chars = event.charactersIgnoringModifiers ?? ""
    if mods == .control, chars == "v" {
      if handleImagePaste() { return }
      if handleFileURLPasteAsPaths(excludingImageFiles: true) { return }
      if handleURLPasteAsMarkdownLink() { return }
    }
    super.keyDown(with: event)
  }

  /// Also override paste: for programmatic paste calls and Edit menu.
  override func paste(_ sender: Any?) {
    if handleImagePaste() { return }
    if handleFileURLPasteAsPaths(excludingImageFiles: true) { return }
    if handleURLPasteAsMarkdownLink() { return }
    pasteAsPlainText(sender)
  }

  private func handleImagePaste() -> Bool {
    let pb = NSPasteboard.general

    // 1. Try raw TIFF/PNG data from clipboard (screenshots, copied image data).
    for type in [NSPasteboard.PasteboardType.tiff, .png] {
      if let data = pb.data(forType: type), let image = NSImage(data: data) {
        onImageDrop?([image])
        return true
      }
    }

    // 2. Try file URLs from clipboard (Cmd+C on files in Finder).
    if let urls = pb.readObjects(
         forClasses: [NSURL.self],
         options: [.urlReadingFileURLsOnly: true]
       ) as? [URL] {
      let imageURLs = urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
      if !imageURLs.isEmpty {
        let images = imageURLs.compactMap { NSImage(contentsOf: $0) }
        if !images.isEmpty {
          onImageDrop?(images)
          return true
        }
      }
    }

    return false
  }

  private func handleURLPasteAsMarkdownLink() -> Bool {
    let selected = selectedRange()
    guard selected.length > 0 else { return false }
    guard let raw = NSPasteboard.general.string(forType: .string)?
      .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
    else { return false }
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
    else { return false }

    let ns = string as NSString
    let labelRaw = ns.substring(with: selected)
    let label = labelRaw.replacingOccurrences(of: "]", with: "\\]")
    let replacement = "[\(label)](\(raw))"
    insertText(replacement, replacementRange: selected)
    return true
  }

  private func handleFileURLPasteAsPaths(excludingImageFiles: Bool) -> Bool {
    let pb = NSPasteboard.general
    guard let urls = pb.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL], !urls.isEmpty else { return false }

    let filtered: [URL]
    if excludingImageFiles {
      filtered = urls.filter { !Self.imageExtensions.contains($0.pathExtension.lowercased()) }
    } else {
      filtered = urls
    }
    guard !filtered.isEmpty else { return false }
    let text = filtered.map(\.path).joined(separator: "\n")
    insertText(text, replacementRange: selectedRange())
    return true
  }

  // MARK: - Drag and Drop

  private func imageURLs(from sender: NSDraggingInfo) -> [URL] {
    guard let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] else { return [] }
    return urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    if !imageURLs(from: sender).isEmpty { return .copy }
    return super.draggingEntered(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    if !imageURLs(from: sender).isEmpty { return .copy }
    return super.draggingUpdated(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls = imageURLs(from: sender)
    guard !urls.isEmpty else { return super.performDragOperation(sender) }
    let images = urls.compactMap { NSImage(contentsOf: $0) }
    guard !images.isEmpty else { return super.performDragOperation(sender) }
    onImageDrop?(images)
    return true
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
    applyTheme(with: nil)
  }

  func applyTheme(with theme: EditorColorTheme? = nil) {
    let t = theme ?? .defaultTheme
    layer?.backgroundColor = t.banner.cgColor
    label.textColor = t.secondaryText
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

#if DEBUG
@MainActor
extension EditorViewController {
  private func _testingBreakUndoCoalescing() {
    #if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    textView.breakUndoCoalescing()
    #endif
  }

  func _testingSetDocumentText(_ text: String, actionName: String? = nil) {
    if textView.string == text { return }
    if let window = view.window {
      _ = window.makeFirstResponder(textView)
    }
    let current = self.textView.string as NSString
    let applied = applyTextEdit(
      replacementRange: NSRange(location: 0, length: current.length),
      replacement: text,
      selectedLocation: (text as NSString).length,
      actionName: actionName
    )
    if !applied {
      isApplyingProgrammaticUpdate = true
      textView.string = text
      isApplyingProgrammaticUpdate = false
      textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }
    let full = NSRange(location: 0, length: (text as NSString).length)
    applyStyling(forChangedRange: full)
    _testingBreakUndoCoalescing()
  }

  func _testingTypeText(_ text: String) {
    guard !text.isEmpty else { return }
    if let window = view.window {
      _ = window.makeFirstResponder(textView)
    }
    let end = (textView.string as NSString).length
    textView.setSelectedRange(NSRange(location: end, length: 0))
    #if TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    textView.insertText(text)
    #else
    textView.insertText(text, replacementRange: textView.selectedRange())
    #endif
    let full = NSRange(location: 0, length: (textView.string as NSString).length)
    applyStyling(forChangedRange: full)
    _testingBreakUndoCoalescing()
  }

  func _testingDocumentText() -> String { textView.string }
  func _testingSetSelection(_ range: NSRange) {
    textView.setSelectedRange(range)
  }
  func _testingSelection() -> NSRange { textView.selectedRange() }

  func _testingShowFind(replace: Bool) { showFind(replace: replace) }
  func _testingHideFind() { hideFind() }
  func _testingSetFindQuery(_ text: String) {
    findField.stringValue = text
    updateFindCountLabel()
    updateCurrentFindHighlight()
  }
  func _testingSetReplaceText(_ text: String) { replaceField.stringValue = text }
  func _testingFindNext() { findNext() }
  func _testingFindPrevious() { findPrevious() }
  func _testingReplaceAll() { replaceAll() }
  func _testingFindVisible() -> Bool { !findContainer.isHidden }
  func _testingReplaceVisible() -> Bool { !replaceRow.isHidden }
  func _testingFindContainerHeight() -> CGFloat { findContainer.fittingSize.height }
  func _testingScrollTopInset() -> CGFloat { scrollView.contentInsets.top }
  func _testingFindStatusText() -> String { findCountLabel.stringValue }
  func _testingFindFieldFirstResponder() -> Bool {
    guard let w = view.window, let r = w.firstResponder else { return false }
    return r === findField.currentEditor()
  }
  func _testingFocusFindField() {
    view.window?.makeFirstResponder(findField)
    updateCurrentFindHighlight()
  }
  func _testingFocusEditor() {
    focusEditor()
    updateCurrentFindHighlight()
  }
  func _testingActiveFindRange() -> NSRange? { activeFindHighlightRange }
  func _testingAllFindRangeCount() -> Int { allFindHighlightRanges.count }
  func _testingActiveHighlightBackgroundColor() -> NSColor? {
    guard let layout = textView.layoutManager, let range = activeFindHighlightRange, range.length > 0 else { return nil }
    return layout.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor
  }
  func _testingActiveHighlightForegroundColor() -> NSColor? {
    guard let layout = textView.layoutManager, let range = activeFindHighlightRange, range.length > 0 else { return nil }
    return layout.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor
  }

  func _testingSetSearchOptions(caseSensitive: Bool, wholeWord: Bool, regexEnabled: Bool) {
    findCaseSensitive = caseSensitive
    findWholeWord = wholeWord
    findRegexEnabled = regexEnabled
    matchCaseButton.state = caseSensitive ? .on : .off
    wholeWordButton.state = wholeWord ? .on : .off
    regexButton.state = regexEnabled ? .on : .off
    updateFindCountLabel()
    updateCurrentFindHighlight()
  }

  func _testingUndo() {
    textView.undoManager?.undo()
    updateCurrentFindHighlight()
  }
  func _testingRedo() {
    textView.undoManager?.redo()
    updateCurrentFindHighlight()
  }
  func _testingResetUndoHistory() {
    textView.undoManager?.removeAllActions()
  }

  func _testingApplyImprovedDraft(_ draft: String) async -> String? {
    if let window = view.window {
      _ = window.makeFirstResponder(textView)
    }
    let current = textView.string
    await session.updateBufferContent(current)
    let restoreId = await session.snapshot(reason: "before_agent_apply")
    replaceEntireDocumentWithUndo(draft, actionName: "Improve Prompt")
    banner.set(message: "Applied agent output. You can restore your previous buffer.", snapshotId: restoreId)
    banner.isHidden = false
    pruneUnreferencedAttachedImages(using: textView.string)
    _testingBreakUndoCoalescing()
    return restoreId
  }

  func _testingRestoreFromBanner() async {
    await restoreFromBanner()
  }

  func _testingAttachImage(id: String, url: URL) {
    attachedImages[id] = url
  }

  func _testingResolvePromptAndImages(_ text: String) -> (String, [URL]) {
    let resolved = promptAndImagesForAgent(from: text)
    return (resolved.prompt, resolved.images)
  }

  #if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
  @discardableResult
  func _testingInsertNewline() -> Bool {
    self.textView(self.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
  }

  @discardableResult
  func _testingInsertLineBreak() -> Bool {
    self.textView(self.textView, doCommandBy: #selector(NSResponder.insertLineBreak(_:)))
  }

  @discardableResult
  func _testingDeleteBackward() -> Bool {
    self.textView(self.textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
  }

  @discardableResult
  func _testingInsertTab() -> Bool {
    self.textView(self.textView, doCommandBy: #selector(NSResponder.insertTab(_:)))
  }

  @discardableResult
  func _testingInsertBacktab() -> Bool {
    self.textView(self.textView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
  }

  @discardableResult
  func _testingToggleCheckboxWithSpace() -> Bool {
    let sel = textView.selectedRange()
    let shouldInsert = self.textView(self.textView, shouldChangeTextIn: sel, replacementString: " ")
    return !shouldInsert
  }
  #endif
}
#endif
