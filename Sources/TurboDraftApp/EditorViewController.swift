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
  private var externalSessionQueuesConfig: TurboDraftConfig.ExternalSessionQueues

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
  private let queueWatcherDebouncer = AsyncDebouncer()
  private var autosaveMaxFlushTask: Task<Void, Never>?
  private var autosavePending = false
  private var autosaveInFlight = false

  private var watcher: DirectoryWatcher?
  private var queueWatcher: DirectoryWatcher?
  private var queueLoadTask: Task<Void, Never>?
  private var queueSaveTask: Task<Void, Never>?
  private var queueLoadGeneration = 0
  private var queueSaveGeneration = 0
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
  private let chatButton = NSButton(title: "Chat Refine", target: nil, action: nil)
  private let queueButton = NSButton(title: "Queue", target: nil, action: nil)
  private let agentRowSpacer = NSView(frame: .zero)
  private let saveStatus = NSTextField(labelWithString: "Saved")
  private let draftingSidebar = NSVisualEffectView()
  private let draftingSidebarResizeHandle = SidebarResizeHandleView()
  private let draftingSidebarStack = NSStackView()
  private let draftingSidebarModeControl = NSSegmentedControl(labels: ["Chat", "Queue"], trackingMode: .selectOne, target: nil, action: nil)
  private let draftingChatContentStack = NSStackView()
  private let queueContentStack = NSStackView()
  private let draftingChatTitle = NSTextField(labelWithString: "Drafting Chat")
  private let draftingChatSubtitle = NSTextField(labelWithString: "Chat with drafting_agent, or add notes and improve.")
  private let draftingChatScroll = NSScrollView()
  private let draftingChatTranscript = NSTextView()
  private let draftingChatInputScroll = NSScrollView()
  private let draftingChatInput = SidebarComposerTextView(frame: .zero)
  private let draftingChatAttachmentRow = NSStackView()
  private let draftingChatAttachmentSummary = NSTextField(labelWithString: "No attachments")
  private let draftingChatAttachButton = NSButton(title: "Attach…", target: nil, action: nil)
  private let draftingChatClearAttachmentsButton = NSButton(title: "Clear", target: nil, action: nil)
  private let draftingAnnotationTypePicker = NSPopUpButton(frame: .zero, pullsDown: false)
  private let draftingChatContextButton = NSButton(title: "Context", target: nil, action: nil)
  private let draftingChatDiffButton = NSButton(title: "Diff", target: nil, action: nil)
  private let draftingChatSendButton = NSButton(title: "Send", target: nil, action: nil)
  private let draftingChatAddImproveButton = NSButton(title: "Add + Improve", target: nil, action: nil)
  private let draftingChatAddNoteButton = NSButton(title: "Add Note", target: nil, action: nil)
  private let draftingChatApplySuggestionButton = NSButton(title: "Apply Suggestion", target: nil, action: nil)
  private let draftingChatCloseButton = NSButton(title: "Close", target: nil, action: nil)
  private let draftingContextScroll = NSScrollView()
  private let draftingContextView = NSTextView()
  private let draftingDiffScroll = NSScrollView()
  private let draftingDiffView = NSTextView()
  private let queueTitle = NSTextField(labelWithString: "Queued Prompts")
  private let queueSubtitle = NSTextField(labelWithString: "Shared external session queue")
  private let queueTableScroll = NSScrollView()
  private let queueTableView = NSTableView()
  private let queueEditorScroll = NSScrollView()
  private let queueEditor = NSTextView()
  private let queueStatusLabel = NSTextField(labelWithString: "No external session queue attached.")
  private let queueNewButton = NSButton(title: "New", target: nil, action: nil)
  private let queueDeleteButton = NSButton(title: "Delete", target: nil, action: nil)
  private let queueReloadButton = NSButton(title: "Reload", target: nil, action: nil)
  private let queueSaveButton = NSButton(title: "Save Queue", target: nil, action: nil)
  private let queueCloseButton = NSButton(title: "Close", target: nil, action: nil)
  private let draftingChatInputMinHeight: CGFloat = 72
  private let draftingChatInputMaxHeight: CGFloat = 140
  private var draftingChatMessages: [String] = []
  private var draftingStreamingLineIndex: Int?
  private var draftingSidebarPendingAttachmentRefs: [String] = []
  private var draftingSidebarPendingAttachmentRefSet: Set<String> = []
  private var draftingSidebarPendingAttachmentDisplay: [String] = []
  private var draftingContextVisible = false
  private var draftingDiffVisible = false
  private var draftingLastSentContext = ""
  private var draftingLastDiffPreview = ""
  private var draftingSidebarSuggestedDraft: String?
  private var draftingSidebarVisible = false
  private var draftingSidebarMode: DraftingSidebarMode = .chat
  private var draftingSidebarPreferredWidth: CGFloat = 360
  private let draftingSidebarResizeHandleWidth: CGFloat = 8
  private var mainStackTrailingConstraint: NSLayoutConstraint?
  private var draftingSidebarWidthConstraint: NSLayoutConstraint?
  private var draftingSidebarDragStartWindowX: CGFloat?
  private var draftingSidebarDragStartWidth: CGFloat = 0
  private var draftingChatInputHeightConstraint: NSLayoutConstraint?
  private var draftingContextHeightConstraint: NSLayoutConstraint?
  private var draftingDiffHeightConstraint: NSLayoutConstraint?
  private var queueEditorHeightConstraint: NSLayoutConstraint?
  private var agentAdapter: AgentAdapting?
  private var draftingSidebarChatAdapter: AgentSidebarChatAdapting?
  private var agentRunning = false
  private var draftingChatRunning = false
  private var sessionCwd: String?
  private var externalQueueAttachment: ExternalQueueAttachment?
  private var externalSessionContextAttachment: ExternalSessionContextAttachment?
  private var externalSessionContextSnapshot: ExternalSessionContextSnapshot?
  private var externalSessionContextLoadTask: Task<Void, Never>?
  private var queueItems: [SharedQueueItem] = []
  private var queueSelectedLocalID: String?
  private var queueFingerprint: String?
  private var queueObservedDiskState = QueueDiskState(absent: true, fileSize: nil, modifiedAt: nil)
  private var queueActiveAttachmentPath: String?
  private var queueDirty = false
  private var isApplyingQueueEditorUpdate = false
  private var attachedImages: [String: URL] = [:]
  private var imageConversionTask: Task<Void, Never>?
  private var _typingLatencies: [Double] = []

  private enum DraftingSidebarMode: Int {
    case chat = 0
    case queue = 1
  }

  private struct QueueDiskState: Equatable {
    var absent: Bool
    var fileSize: Int?
    var modifiedAt: Date?
  }
  private var sessionOpenStartNs: UInt64?
  private var sessionOpenToReadyMsValue: Double?
  private let imagePlaceholderRegex = try! NSRegularExpression(pattern: #"\[image-([a-f0-9]{8})\]"#)
  private let draftingAnnotationRegex = try! NSRegularExpression(
    pattern: #"<!--\s*@td\((note|question|constraint|decision|context)\)\s*:\s*([\s\S]*?)\s*-->"#,
    options: [.caseInsensitive]
  )
  private let draftingAnnotationLineRegex = try! NSRegularExpression(
    pattern: #"(?m)^[ \t]*@@(?:\s*(note|question|constraint|decision|context)\s*:)?\s*(.+)$"#,
    options: [.caseInsensitive]
  )
  private let listPrefixRegex = try! NSRegularExpression(
    pattern: #"^([ \t]*(?:>[ \t]*)*)(?:[-+*][ \t]+(?:\[[ xX]\][ \t]+)?|\d{1,9}[.)][ \t]+)"#
  )
  private let taskCheckboxRegex = try! NSRegularExpression(
    pattern: #"^([ \t]*(?:>[ \t]*)*)([-+*])([ \t]+)\[([ xX])\]([ \t]+)(.*)$"#
  )
  private static let fencedCodeBlockRegex = try! NSRegularExpression(
    pattern: #"```([A-Za-z0-9_+\-]*)[ \t]*\n([\s\S]*?)\n```"#
  )
  private static let supportedImageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "webp", "heic",
  ]

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

  private enum DraftingAnnotationType: String, CaseIterable {
    case note
    case question
    case constraint
    case decision
    case context

    var menuTitle: String {
      switch self {
      case .note: return "Note"
      case .question: return "Question"
      case .constraint: return "Constraint"
      case .decision: return "Decision"
      case .context: return "Context"
      }
    }
  }

  private var saveState: SaveState = .saved

  init(session: EditorSession, config: TurboDraftConfig) {
    self.session = session
    self.config = config
    self.editorMode = config.editorMode
    self.agentConfig = config.agent
    self.externalSessionQueuesConfig = config.externalSessionQueues
    let initialFontSize = CGFloat(max(11, min(config.fontSize, 72)))
    #if TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    self.textView = TextView(
      string: "",
      font: NSFont.monospacedSystemFont(ofSize: initialFontSize, weight: .regular),
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

  private func applyModernScrollerStyle(to scrollView: NSScrollView) {
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.verticalScroller?.controlSize = .small
    scrollView.horizontalScroller?.controlSize = .small
  }

  deinit {
    autosaveDebouncer.cancel()
    styleDebouncer.cancel()
    openStyleDebouncer.cancel()
    fullOpenStyleDebouncer.cancel()
    watcherDebouncer.cancel()
    queueWatcherDebouncer.cancel()
    autosaveMaxFlushTask?.cancel()
    findFeedbackTask?.cancel()
    watcher?.stop()
    queueWatcher?.stop()
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
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = false
    scrollView.documentView = textView
    applyModernScrollerStyle(to: scrollView)
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
    textView.onOpenDraftingChat = { [weak self] in
      self?.openDraftingChatFromMenu()
    }
    textView.onInsertDraftingAnnotation = { [weak self] in
      self?.insertDraftingAnnotation(type: "note")
    }
    textView.onCloseFind = { [weak self] in
      guard let self, !self.findContainer.isHidden else { return false }
      self.hideFind()
      return true
    }
    textView.onCloseDraftingSidebar = { [weak self] in
      guard let self, self.draftingSidebarVisible else { return false }
      self.setDraftingSidebarVisible(false)
      return true
    }
    textView.onEscape = { [weak self] in
      guard let window = self?.view.window else { return false }
      window.performClose(nil)
      return true
    }
    textView.font = NSFont.monospacedSystemFont(
      ofSize: CGFloat(max(11, min(config.fontSize, 72))),
      weight: .regular
    )
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
    let findFieldMinWidthConstraint = findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 170)
    findFieldMinWidthConstraint.priority = .defaultLow
    let replaceFieldMinWidthConstraint = replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 170)
    replaceFieldMinWidthConstraint.priority = .defaultLow
    NSLayoutConstraint.activate([
      findStack.leadingAnchor.constraint(equalTo: findContainer.leadingAnchor),
      findStack.trailingAnchor.constraint(equalTo: findContainer.trailingAnchor),
      findStack.topAnchor.constraint(equalTo: findContainer.topAnchor),
      findStack.bottomAnchor.constraint(equalTo: findContainer.bottomAnchor),
      findFieldMinWidthConstraint,
      replaceFieldMinWidthConstraint,
    ])

    agentRow.orientation = .horizontal
    agentRow.alignment = .centerY
    agentRow.distribution = .fill
    agentRow.spacing = 10
    agentRow.translatesAutoresizingMaskIntoConstraints = false
    agentRow.detachesHiddenViews = true
    agentRow.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 6, right: 18)

    saveStatus.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    saveStatus.lineBreakMode = .byTruncatingTail
    saveStatus.alignment = .left
    saveStatus.translatesAutoresizingMaskIntoConstraints = false
    saveStatus.setContentHuggingPriority(.required, for: .horizontal)
    saveStatus.setContentCompressionResistancePriority(.required, for: .horizontal)

    agentButton.target = self
    agentButton.action = #selector(runAgent)
    agentButton.refusesFirstResponder = true
    agentButton.controlSize = .regular
    agentButton.bezelStyle = .rounded
    agentRow.addArrangedSubview(saveStatus)
    agentRow.addArrangedSubview(agentRowSpacer)
    agentRow.addArrangedSubview(agentButton)
    agentButton.setContentHuggingPriority(.required, for: .horizontal)
    chatButton.target = self
    chatButton.action = #selector(openDraftingChat)
    chatButton.refusesFirstResponder = true
    chatButton.controlSize = .regular
    chatButton.bezelStyle = .rounded
    agentRow.addArrangedSubview(chatButton)
    chatButton.setContentHuggingPriority(.required, for: .horizontal)
    queueButton.target = self
    queueButton.action = #selector(openQueuePanel)
    queueButton.refusesFirstResponder = true
    queueButton.controlSize = .regular
    queueButton.bezelStyle = .rounded
    queueButton.isHidden = true
    agentRow.addArrangedSubview(queueButton)
    queueButton.setContentHuggingPriority(.required, for: .horizontal)
    agentRowSpacer.translatesAutoresizingMaskIntoConstraints = false
    agentRowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    agentRowSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    draftingSidebar.material = .hudWindow
    draftingSidebar.blendingMode = .withinWindow
    draftingSidebar.state = .active
    draftingSidebar.translatesAutoresizingMaskIntoConstraints = false
    draftingSidebar.wantsLayer = true
    draftingSidebar.layer?.borderWidth = 1
    draftingSidebar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
    draftingSidebar.isHidden = true

    draftingSidebarResizeHandle.translatesAutoresizingMaskIntoConstraints = false
    draftingSidebarResizeHandle.wantsLayer = true
    draftingSidebarResizeHandle.isHidden = true
    draftingSidebarResizeHandle.onDragBegan = { [weak self] windowX in
      self?.beginDraftingSidebarResize(at: windowX)
    }
    draftingSidebarResizeHandle.onDragChanged = { [weak self] windowX in
      self?.updateDraftingSidebarResize(at: windowX)
    }
    draftingSidebarResizeHandle.onDragEnded = { [weak self] in
      self?.endDraftingSidebarResize()
    }

    draftingSidebarStack.orientation = .vertical
    draftingSidebarStack.spacing = 8
    draftingSidebarStack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 12, right: 12)
    draftingSidebarStack.translatesAutoresizingMaskIntoConstraints = false

    draftingSidebarModeControl.target = self
    draftingSidebarModeControl.action = #selector(draftingSidebarModeChanged(_:))
    draftingSidebarModeControl.selectedSegment = DraftingSidebarMode.chat.rawValue
    draftingSidebarModeControl.segmentStyle = .rounded
    draftingSidebarModeControl.controlSize = .small
    draftingSidebarModeControl.isHidden = true
    draftingSidebarModeControl.setContentHuggingPriority(.required, for: .vertical)

    draftingChatTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    draftingChatSubtitle.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    draftingChatSubtitle.lineBreakMode = .byWordWrapping
    draftingChatSubtitle.maximumNumberOfLines = 0

    draftingChatTranscript.isEditable = false
    draftingChatTranscript.isSelectable = true
    draftingChatTranscript.drawsBackground = false
    let sidebarFontSize = max(12, CGFloat(max(11, min(config.fontSize, 72))) - 1)
    draftingChatTranscript.font = NSFont.monospacedSystemFont(ofSize: sidebarFontSize, weight: .regular)
    draftingChatTranscript.textColor = colorTheme.foreground
    draftingChatTranscript.textContainerInset = NSSize(width: 6, height: 6)
    draftingChatTranscript.string = ""

    draftingChatScroll.drawsBackground = false
    draftingChatScroll.borderType = .noBorder
    draftingChatScroll.hasVerticalScroller = true
    draftingChatScroll.documentView = draftingChatTranscript
    applyModernScrollerStyle(to: draftingChatScroll)

    draftingChatInput.isEditable = true
    draftingChatInput.isSelectable = true
    draftingChatInput.drawsBackground = true
    draftingChatInput.font = NSFont.monospacedSystemFont(ofSize: sidebarFontSize, weight: .regular)
    draftingChatInput.textContainerInset = NSSize(width: 6, height: 6)
    draftingChatInput.isVerticallyResizable = true
    draftingChatInput.isHorizontallyResizable = false
    draftingChatInput.delegate = self
    draftingChatInput.textContainer?.widthTracksTextView = true
    draftingChatInput.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    draftingChatInput.string = ""
    draftingChatInput.onSubmit = { [weak self] in
      _ = self?.sendDraftingChatMessage()
    }
    draftingChatInput.onCancel = { [weak self] in
      guard let self, self.draftingSidebarVisible else { return }
      self.setDraftingSidebarVisible(false)
    }
    draftingChatInput.onImageDrop = { [weak self] images in
      self?.enqueueDraftingSidebarImages(images)
    }
    draftingChatInput.onFileDrop = { [weak self] urls in
      self?.enqueueDraftingSidebarFiles(urls)
    }
    draftingChatInput.onTextChanged = { [weak self] in
      self?.updateDraftingChatInputHeight()
    }

    draftingChatInputScroll.drawsBackground = false
    draftingChatInputScroll.borderType = .noBorder
    draftingChatInputScroll.hasVerticalScroller = true
    draftingChatInputScroll.documentView = draftingChatInput
    applyModernScrollerStyle(to: draftingChatInputScroll)
    draftingChatInputScroll.wantsLayer = true
    draftingChatInputScroll.layer?.cornerRadius = 6
    draftingChatInputScroll.layer?.borderWidth = 0.8

    draftingChatAttachmentSummary.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    draftingChatAttachmentSummary.lineBreakMode = .byTruncatingTail
    draftingChatAttachmentSummary.stringValue = "No attachments"
    draftingChatAttachmentSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    draftingChatAttachButton.target = self
    draftingChatAttachButton.action = #selector(draftingChatAttachAction(_:))
    draftingChatAttachButton.controlSize = .small
    draftingChatAttachButton.bezelStyle = .texturedRounded
    draftingChatAttachButton.refusesFirstResponder = true

    draftingChatClearAttachmentsButton.target = self
    draftingChatClearAttachmentsButton.action = #selector(draftingChatClearAttachmentsAction(_:))
    draftingChatClearAttachmentsButton.controlSize = .small
    draftingChatClearAttachmentsButton.bezelStyle = .texturedRounded
    draftingChatClearAttachmentsButton.refusesFirstResponder = true
    draftingChatClearAttachmentsButton.isEnabled = false

    draftingChatAttachmentRow.orientation = .horizontal
    draftingChatAttachmentRow.spacing = 8
    draftingChatAttachmentRow.alignment = .centerY
    draftingChatAttachmentRow.distribution = .fill
    draftingChatAttachmentRow.addArrangedSubview(draftingChatAttachmentSummary)
    draftingChatAttachmentRow.addArrangedSubview(draftingChatAttachButton)
    draftingChatAttachmentRow.addArrangedSubview(draftingChatClearAttachmentsButton)

    draftingAnnotationTypePicker.removeAllItems()
    draftingAnnotationTypePicker.addItems(withTitles: DraftingAnnotationType.allCases.map(\.menuTitle))
    draftingAnnotationTypePicker.selectItem(withTitle: DraftingAnnotationType.note.menuTitle)
    draftingAnnotationTypePicker.controlSize = .small
    draftingAnnotationTypePicker.setContentHuggingPriority(.required, for: .horizontal)
    draftingAnnotationTypePicker.setContentCompressionResistancePriority(.required, for: .horizontal)

    draftingChatContextButton.target = self
    draftingChatContextButton.action = #selector(draftingChatToggleContextAction(_:))
    draftingChatContextButton.controlSize = .small
    draftingChatContextButton.bezelStyle = .texturedRounded
    draftingChatContextButton.refusesFirstResponder = true

    draftingChatDiffButton.target = self
    draftingChatDiffButton.action = #selector(draftingChatToggleDiffAction(_:))
    draftingChatDiffButton.controlSize = .small
    draftingChatDiffButton.bezelStyle = .texturedRounded
    draftingChatDiffButton.refusesFirstResponder = true

    draftingChatAddImproveButton.target = self
    draftingChatAddImproveButton.action = #selector(draftingChatAddImproveAction(_:))
    draftingChatAddImproveButton.controlSize = .small
    draftingChatAddImproveButton.bezelStyle = .texturedRounded
    draftingChatAddImproveButton.refusesFirstResponder = true

    draftingChatSendButton.target = self
    draftingChatSendButton.action = #selector(draftingChatSendAction(_:))
    draftingChatSendButton.controlSize = .small
    draftingChatSendButton.bezelStyle = .texturedRounded
    draftingChatSendButton.refusesFirstResponder = true

    draftingChatAddNoteButton.target = self
    draftingChatAddNoteButton.action = #selector(draftingChatAddNoteAction(_:))
    draftingChatAddNoteButton.controlSize = .small
    draftingChatAddNoteButton.bezelStyle = .texturedRounded
    draftingChatAddNoteButton.refusesFirstResponder = true

    draftingChatApplySuggestionButton.target = self
    draftingChatApplySuggestionButton.action = #selector(draftingChatApplySuggestionAction(_:))
    draftingChatApplySuggestionButton.controlSize = .small
    draftingChatApplySuggestionButton.bezelStyle = .texturedRounded
    draftingChatApplySuggestionButton.refusesFirstResponder = true
    draftingChatApplySuggestionButton.isEnabled = false

    draftingChatCloseButton.target = self
    draftingChatCloseButton.action = #selector(draftingChatCloseAction(_:))
    draftingChatCloseButton.controlSize = .small
    draftingChatCloseButton.bezelStyle = .texturedRounded
    draftingChatCloseButton.refusesFirstResponder = true

    draftingContextView.isEditable = false
    draftingContextView.isSelectable = true
    draftingContextView.drawsBackground = false
    draftingContextView.font = NSFont.monospacedSystemFont(ofSize: max(11, sidebarFontSize - 1), weight: .regular)
    draftingContextView.textContainerInset = NSSize(width: 6, height: 6)
    draftingContextView.string = "No sent context yet."
    draftingContextScroll.drawsBackground = false
    draftingContextScroll.borderType = .noBorder
    draftingContextScroll.hasVerticalScroller = true
    draftingContextScroll.documentView = draftingContextView
    applyModernScrollerStyle(to: draftingContextScroll)
    draftingContextScroll.wantsLayer = true
    draftingContextScroll.layer?.cornerRadius = 6
    draftingContextScroll.layer?.borderWidth = 0.8
    draftingContextScroll.isHidden = true

    draftingDiffView.isEditable = false
    draftingDiffView.isSelectable = true
    draftingDiffView.drawsBackground = false
    draftingDiffView.font = NSFont.monospacedSystemFont(ofSize: max(11, sidebarFontSize - 1), weight: .regular)
    draftingDiffView.textContainerInset = NSSize(width: 6, height: 6)
    draftingDiffView.string = "No suggestion diff yet."
    draftingDiffScroll.drawsBackground = false
    draftingDiffScroll.borderType = .noBorder
    draftingDiffScroll.hasVerticalScroller = true
    draftingDiffScroll.documentView = draftingDiffView
    applyModernScrollerStyle(to: draftingDiffScroll)
    draftingDiffScroll.wantsLayer = true
    draftingDiffScroll.layer?.cornerRadius = 6
    draftingDiffScroll.layer?.borderWidth = 0.8
    draftingDiffScroll.isHidden = true

    queueTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    queueSubtitle.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    queueSubtitle.lineBreakMode = .byWordWrapping
    queueSubtitle.maximumNumberOfLines = 0

    let queueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("prompt"))
    queueColumn.title = "Prompt"
    queueTableView.addTableColumn(queueColumn)
    queueTableView.headerView = nil
    queueTableView.usesAlternatingRowBackgroundColors = false
    queueTableView.selectionHighlightStyle = .regular
    queueTableView.allowsEmptySelection = true
    queueTableView.delegate = self
    queueTableView.dataSource = self
    queueTableView.target = self
    queueTableView.action = #selector(queueSelectionDidChange(_:))
    queueTableView.rowHeight = 28

    queueTableScroll.drawsBackground = false
    queueTableScroll.borderType = .noBorder
    queueTableScroll.hasVerticalScroller = true
    queueTableScroll.documentView = queueTableView
    applyModernScrollerStyle(to: queueTableScroll)
    queueTableScroll.wantsLayer = true
    queueTableScroll.layer?.cornerRadius = 6
    queueTableScroll.layer?.borderWidth = 0.8

    queueEditor.isEditable = true
    queueEditor.isSelectable = true
    queueEditor.drawsBackground = false
    queueEditor.isVerticallyResizable = true
    queueEditor.isHorizontallyResizable = false
    queueEditor.textContainerInset = NSSize(width: 6, height: 6)
    queueEditor.textContainer?.widthTracksTextView = true
    queueEditor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    queueEditor.string = ""

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleTextDidChange(_:)),
      name: NSText.didChangeNotification,
      object: queueEditor
    )

    queueEditorScroll.drawsBackground = false
    queueEditorScroll.borderType = .noBorder
    queueEditorScroll.hasVerticalScroller = true
    queueEditorScroll.documentView = queueEditor
    applyModernScrollerStyle(to: queueEditorScroll)
    queueEditorScroll.wantsLayer = true
    queueEditorScroll.layer?.cornerRadius = 6
    queueEditorScroll.layer?.borderWidth = 0.8

    queueStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    queueStatusLabel.lineBreakMode = .byTruncatingTail
    queueStatusLabel.maximumNumberOfLines = 2

    for button in [queueNewButton, queueDeleteButton, queueReloadButton, queueSaveButton, queueCloseButton] {
      button.target = self
      button.controlSize = .small
      button.bezelStyle = .texturedRounded
      button.refusesFirstResponder = true
    }
    queueNewButton.action = #selector(queueNewAction(_:))
    queueDeleteButton.action = #selector(queueDeleteAction(_:))
    queueReloadButton.action = #selector(queueReloadAction(_:))
    queueSaveButton.action = #selector(queueSaveAction(_:))
    queueCloseButton.action = #selector(draftingChatCloseAction(_:))

    let draftingUtilityRow = NSStackView(
      views: [
        NSTextField(labelWithString: "Type"),
        draftingAnnotationTypePicker,
        draftingChatContextButton,
        draftingChatDiffButton,
        draftingChatApplySuggestionButton,
      ]
    )
    draftingUtilityRow.orientation = .horizontal
    draftingUtilityRow.spacing = 8
    draftingUtilityRow.alignment = .centerY
    draftingUtilityRow.distribution = .fill
    if let typeLabel = draftingUtilityRow.arrangedSubviews.first as? NSTextField {
      typeLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
      typeLabel.textColor = colorTheme.secondaryText
      typeLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    let draftingButtonsRow = NSStackView(
      views: [draftingChatSendButton, draftingChatAddImproveButton, draftingChatAddNoteButton, draftingChatCloseButton]
    )
    draftingButtonsRow.orientation = .horizontal
    draftingButtonsRow.spacing = 8
    draftingButtonsRow.alignment = .centerY
    draftingButtonsRow.distribution = .fillProportionally

    draftingChatContentStack.orientation = .vertical
    draftingChatContentStack.spacing = 8
    draftingChatContentStack.translatesAutoresizingMaskIntoConstraints = false
    draftingChatContentStack.addArrangedSubview(draftingChatTitle)
    draftingChatContentStack.addArrangedSubview(draftingChatSubtitle)
    draftingChatContentStack.addArrangedSubview(draftingChatScroll)
    draftingChatContentStack.addArrangedSubview(draftingContextScroll)
    draftingChatContentStack.addArrangedSubview(draftingDiffScroll)
    draftingChatContentStack.addArrangedSubview(draftingChatInputScroll)
    draftingChatContentStack.addArrangedSubview(draftingChatAttachmentRow)
    draftingChatContentStack.addArrangedSubview(draftingUtilityRow)
    draftingChatContentStack.addArrangedSubview(draftingButtonsRow)
    draftingChatScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    draftingChatScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    queueContentStack.orientation = .vertical
    queueContentStack.spacing = 8
    queueContentStack.translatesAutoresizingMaskIntoConstraints = false
    queueContentStack.isHidden = true

    let queueButtonsRow = NSStackView(
      views: [queueNewButton, queueDeleteButton, queueReloadButton, queueSaveButton, queueCloseButton]
    )
    queueButtonsRow.orientation = .horizontal
    queueButtonsRow.spacing = 8
    queueButtonsRow.alignment = .centerY
    queueButtonsRow.distribution = .fillProportionally

    queueContentStack.addArrangedSubview(queueTitle)
    queueContentStack.addArrangedSubview(queueSubtitle)
    queueContentStack.addArrangedSubview(queueTableScroll)
    queueContentStack.addArrangedSubview(queueEditorScroll)
    queueContentStack.addArrangedSubview(queueStatusLabel)
    queueContentStack.addArrangedSubview(queueButtonsRow)
    queueTableScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    queueTableScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    queueEditorHeightConstraint = queueEditorScroll.heightAnchor.constraint(equalToConstant: 180)

    draftingSidebarStack.addArrangedSubview(draftingSidebarModeControl)
    draftingSidebarStack.addArrangedSubview(draftingChatContentStack)
    draftingSidebarStack.addArrangedSubview(queueContentStack)
    draftingSidebar.addSubview(draftingSidebarStack)
    draftingChatInputHeightConstraint = draftingChatInputScroll.heightAnchor.constraint(equalToConstant: draftingChatInputMinHeight)
    draftingContextHeightConstraint = draftingContextScroll.heightAnchor.constraint(equalToConstant: 0)
    draftingDiffHeightConstraint = draftingDiffScroll.heightAnchor.constraint(equalToConstant: 0)
    let draftingChatScrollMinHeightConstraint = draftingChatScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
    draftingChatScrollMinHeightConstraint.priority = .defaultLow
    let draftingChatInputMinHeightConstraint = draftingChatInputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: draftingChatInputMinHeight)
    draftingChatInputMinHeightConstraint.priority = .defaultLow
    let queueTableMinHeightConstraint = queueTableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
    queueTableMinHeightConstraint.priority = .defaultLow

    NSLayoutConstraint.activate([
      draftingSidebarStack.leadingAnchor.constraint(equalTo: draftingSidebar.leadingAnchor),
      draftingSidebarStack.trailingAnchor.constraint(equalTo: draftingSidebar.trailingAnchor),
      draftingSidebarStack.topAnchor.constraint(equalTo: draftingSidebar.topAnchor),
      draftingSidebarStack.bottomAnchor.constraint(equalTo: draftingSidebar.bottomAnchor),
      draftingChatScrollMinHeightConstraint,
      draftingContextHeightConstraint!,
      draftingDiffHeightConstraint!,
      draftingChatInputMinHeightConstraint,
      draftingChatInputScroll.heightAnchor.constraint(lessThanOrEqualToConstant: draftingChatInputMaxHeight),
      draftingChatInputHeightConstraint!,
      queueTableMinHeightConstraint,
      queueEditorHeightConstraint!,
    ])

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    stack.addArrangedSubview(banner)
    stack.addArrangedSubview(agentRow)
    stack.addArrangedSubview(scrollView)
    scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    draftingSidebar.setContentHuggingPriority(.defaultLow, for: .horizontal)
    draftingSidebar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.addSubview(stack)
    view.addSubview(draftingSidebarResizeHandle)
    view.addSubview(draftingSidebar)
    view.addSubview(findContainer)

    mainStackTrailingConstraint = stack.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    draftingSidebarWidthConstraint = draftingSidebar.widthAnchor.constraint(equalToConstant: 0)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      mainStackTrailingConstraint!,
      stack.topAnchor.constraint(equalTo: view.topAnchor),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      draftingSidebarResizeHandle.trailingAnchor.constraint(equalTo: draftingSidebar.leadingAnchor),
      draftingSidebarResizeHandle.widthAnchor.constraint(equalToConstant: draftingSidebarResizeHandleWidth),
      draftingSidebarResizeHandle.topAnchor.constraint(equalTo: view.topAnchor),
      draftingSidebarResizeHandle.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      draftingSidebar.topAnchor.constraint(equalTo: view.topAnchor),
      draftingSidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      draftingSidebar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      draftingSidebarWidthConstraint!,
      banner.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
      findContainer.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
      findContainer.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -12),
      findContainer.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 12),
      findContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
    ])

    applyAgentConfig()

    applyTheme()
    updateDraftingChatInputHeight()
    updateDraftingSidebarModeControls()
    updateDraftingSidebarControlState()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    setSaveState(saveState)
    focusEditor()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    guard draftingSidebarVisible else { return }
    let clampedWidth = clampedDraftingSidebarWidth(draftingSidebarPreferredWidth)
    if abs((draftingSidebarWidthConstraint?.constant ?? 0) - clampedWidth) > 0.5 {
      applyDraftingSidebarWidth(clampedWidth, animated: false)
    }
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
    queueWatcher?.stop()
    queueWatcher = nil
    queueWatcherDebouncer.cancel()
    queueLoadTask?.cancel()
    queueLoadTask = nil
    queueSaveTask?.cancel()
    queueSaveTask = nil
    externalQueueAttachment = nil
    externalSessionContextAttachment = nil
    externalSessionContextSnapshot = nil
    externalSessionContextLoadTask?.cancel()
    externalSessionContextLoadTask = nil
    queueItems.removeAll()
    queueSelectedLocalID = nil
    queueFingerprint = nil
    queueObservedDiskState = QueueDiskState(absent: true, fileSize: nil, modifiedAt: nil)
    queueDirty = false
    isApplyingQueueEditorUpdate = true
    queueEditor.string = ""
    isApplyingQueueEditorUpdate = false
    queueSubtitle.stringValue = "Shared external session queue"
    queueStatusLabel.stringValue = "No external session queue attached."
    queueTableView.reloadData()
    updateDraftingSidebarModeControls()
    updateDraftingSidebarControlState()
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
    if Task.isCancelled { return }

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
      if Task.isCancelled { return }
      await appendImageReferencesForClose()
    }

    if Task.isCancelled { return }
    if !autosavePending, let info = await session.currentInfo(), info.isDirty {
      autosavePending = true
    }
    if Task.isCancelled { return }
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

  private struct DraftingAnnotation {
    let type: String
    let content: String
  }

  private func parseDraftingAnnotations(in text: String) -> [DraftingAnnotation] {
    let ns = text as NSString
    var out: [DraftingAnnotation] = []
    let commentMatches = draftingAnnotationRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    out.reserveCapacity(commentMatches.count)
    for match in commentMatches {
      if let parsed = parseAnnotationMatch(match, in: ns) {
        out.append(parsed)
      }
    }

    // Also support lightweight inline annotation prefix:
    //   @@ note: tighten scope
    //   @@ question: should this include tests?
    let lineMatches = draftingAnnotationLineRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    for match in lineMatches {
      guard match.numberOfRanges >= 3 else { continue }
      let rawType: String
      if match.range(at: 1).location != NSNotFound {
        rawType = ns.substring(with: match.range(at: 1)).lowercased()
      } else {
        rawType = "note"
      }
      let rawContent = ns.substring(with: match.range(at: 2))
      let content = normalizeAnnotationContent(rawContent)
      guard !content.isEmpty else { continue }
      out.append(DraftingAnnotation(type: rawType, content: content))
    }
    return out
  }

  private func parseAnnotationMatch(_ match: NSTextCheckingResult, in ns: NSString) -> DraftingAnnotation? {
    guard match.numberOfRanges >= 3 else { return nil }
    let rawType = ns.substring(with: match.range(at: 1)).lowercased()
    let rawContent = ns.substring(with: match.range(at: 2))
    let content = normalizeAnnotationContent(rawContent)
    guard !content.isEmpty else { return nil }
    return DraftingAnnotation(type: rawType, content: content)
  }

  private func normalizeAnnotationContent(_ raw: String) -> String {
    raw
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private func insertDraftingAnnotation(type: String) {
    guard agentConfig.annotationEnabled else { return }
    let sel = textView.selectedRange()
    let ns = textView.string as NSString
    let selectedText = sel.length > 0 && sel.location + sel.length <= ns.length
      ? ns.substring(with: sel)
      : ""
    let templatePrefix = "<!-- @td(\(type)): "
    let replacement = "\(templatePrefix)\(selectedText) -->"
    let cursor = sel.location + templatePrefix.count + selectedText.count
    _ = applyTextEdit(
      replacementRange: sel,
      replacement: replacement,
      selectedLocation: cursor,
      actionName: "Insert Drafting Annotation"
    )
  }

  func insertDraftingAnnotationFromMenu() {
    insertDraftingAnnotation(type: "note")
  }

  @objc private func openDraftingChat() {
    guard isChatSidebarAvailable() else {
      NSSound.beep()
      return
    }
    if draftingSidebarVisible, draftingSidebarMode == .chat {
      setDraftingSidebarVisible(false)
      return
    }
    setDraftingSidebarMode(.chat)
    setDraftingSidebarVisible(true, focusInput: true)
  }

  @objc private func openQueuePanel() {
    guard isQueueSidebarAvailable() else {
      NSSound.beep()
      return
    }
    if draftingSidebarVisible, draftingSidebarMode == .queue {
      setDraftingSidebarVisible(false)
      return
    }
    setDraftingSidebarMode(.queue)
    setDraftingSidebarVisible(true, focusInput: false)
    if selectedQueueIndex() != nil {
      view.window?.makeFirstResponder(queueEditor)
    } else {
      view.window?.makeFirstResponder(queueTableView)
    }
  }

  private func isChatSidebarAvailable() -> Bool {
    agentConfig.enabled && agentConfig.chatPanelEnabled
  }

  private func isExternalQueueIntegrationEnabled() -> Bool {
    externalSessionQueuesConfig.enabled
  }

  private func isQueueSidebarAvailable() -> Bool {
    isExternalQueueIntegrationEnabled() && externalQueueAttachment?.isSupportedFormat == true
  }

  private func normalizedDraftingSidebarMode(_ requested: DraftingSidebarMode) -> DraftingSidebarMode? {
    switch requested {
    case .chat where isChatSidebarAvailable():
      return .chat
    case .queue where isQueueSidebarAvailable():
      return .queue
    default:
      if isChatSidebarAvailable() { return .chat }
      if isQueueSidebarAvailable() { return .queue }
      return nil
    }
  }

  private func setDraftingSidebarMode(_ mode: DraftingSidebarMode) {
    guard let resolved = normalizedDraftingSidebarMode(mode) else {
      draftingSidebarMode = .chat
      draftingChatContentStack.isHidden = true
      queueContentStack.isHidden = true
      draftingSidebarModeControl.isHidden = true
      return
    }
    draftingSidebarMode = resolved
    draftingSidebarModeControl.selectedSegment = resolved.rawValue
    draftingChatContentStack.isHidden = (resolved != .chat)
    queueContentStack.isHidden = (resolved != .queue)
    if resolved == .queue {
      activateQueueAttachmentIfNeeded(reason: "queue panel activated")
    }
    if resolved == .chat, draftingSidebarVisible, draftingChatMessages.isEmpty {
      appendDraftingChatTranscript("system: drafting sidebar ready")
    }
    updateDraftingSidebarModeControls()
    updateDraftingSidebarControlState()
  }

  private func updateDraftingSidebarModeControls() {
    let chatAvailable = isChatSidebarAvailable()
    let queueAvailable = isQueueSidebarAvailable()
    updateDraftingEntryButtons(chatAvailable: chatAvailable, queueAvailable: queueAvailable)
    draftingSidebarModeControl.isHidden = !(draftingSidebarVisible && chatAvailable && queueAvailable)
    draftingSidebarModeControl.setEnabled(chatAvailable, forSegment: DraftingSidebarMode.chat.rawValue)
    draftingSidebarModeControl.setEnabled(queueAvailable, forSegment: DraftingSidebarMode.queue.rawValue)

    if let resolved = normalizedDraftingSidebarMode(draftingSidebarMode) {
      draftingSidebarMode = resolved
      draftingSidebarModeControl.selectedSegment = resolved.rawValue
      draftingChatContentStack.isHidden = (resolved != .chat)
      queueContentStack.isHidden = (resolved != .queue)
    } else {
      draftingChatContentStack.isHidden = true
      queueContentStack.isHidden = true
      if draftingSidebarVisible {
        setDraftingSidebarVisible(false)
      }
    }
  }

  private func updateDraftingEntryButtons(chatAvailable: Bool, queueAvailable: Bool) {
    let chatActive = draftingSidebarVisible && draftingSidebarMode == .chat && chatAvailable
    let queueActive = draftingSidebarVisible && draftingSidebarMode == .queue && queueAvailable
    chatButton.isHidden = !chatAvailable
    queueButton.isHidden = !queueAvailable
    chatButton.title = chatActive ? "Hide Chat" : "Chat Refine"
    queueButton.title = queueActive ? "Hide Queue" : "Queue"
  }

  private func selectedDraftingAnnotationType() -> DraftingAnnotationType {
    guard let title = draftingAnnotationTypePicker.selectedItem?.title else { return .note }
    return DraftingAnnotationType.allCases.first { $0.menuTitle == title } ?? .note
  }

  private func setSelectedDraftingAnnotationType(_ type: DraftingAnnotationType) {
    draftingAnnotationTypePicker.selectItem(withTitle: type.menuTitle)
  }

  private func appendDraftingChatAnnotation(note: String, type: String = "question") -> Bool {
    let clean = normalizeAnnotationContent(note)
    guard !clean.isEmpty else { return false }
    let ns = textView.string as NSString
    let fullLen = ns.length
    var prefix = "\n"
    if fullLen == 0 {
      prefix = ""
    } else if textView.string.hasSuffix("\n") {
      prefix = ""
    }
    let snippet = "\(prefix)<!-- @td(\(type)): \(clean) -->\n"
    if applyTextEdit(
      replacementRange: NSRange(location: fullLen, length: 0),
      replacement: snippet,
      selectedLocation: fullLen + (snippet as NSString).length,
      actionName: "Add Drafting Note"
    ) {
      return true
    }

    // Fallback for edge cases where TextKit refuses the edit because the editor
    // is not current first responder (e.g. sidebar-focused submit paths).
    isApplyingProgrammaticUpdate = true
    textView.string += snippet
    isApplyingProgrammaticUpdate = false
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    applyStyling(forChangedRange: NSRange(location: 0, length: (textView.string as NSString).length))
    autosavePending = true
    return true
  }

  func openDraftingChatFromMenu() {
    openDraftingChat()
  }

  private func draftingSidebarWidthBounds() -> ClosedRange<CGFloat> {
    let minWidth: CGFloat = 0
    let maxWidth = max(minWidth, view.bounds.width)
    return minWidth...maxWidth
  }

  private func clampedDraftingSidebarWidth(_ width: CGFloat) -> CGFloat {
    let bounds = draftingSidebarWidthBounds()
    return min(max(width, bounds.lowerBound), bounds.upperBound)
  }

  private func applyDraftingSidebarWidth(_ width: CGFloat, animated: Bool) {
    let clampedWidth = clampedDraftingSidebarWidth(width)
    draftingSidebarPreferredWidth = clampedWidth
    draftingSidebarWidthConstraint?.constant = clampedWidth
    mainStackTrailingConstraint?.constant = draftingSidebarVisible ? -(clampedWidth + draftingSidebarResizeHandleWidth) : 0

    if animated {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.12
        view.layoutSubtreeIfNeeded()
        view.animator().layoutSubtreeIfNeeded()
      }
    } else {
      view.layoutSubtreeIfNeeded()
    }
  }

  private func beginDraftingSidebarResize(at windowX: CGFloat) {
    guard draftingSidebarVisible else { return }
    draftingSidebarDragStartWindowX = windowX
    draftingSidebarDragStartWidth = draftingSidebarWidthConstraint?.constant ?? draftingSidebarPreferredWidth
  }

  private func updateDraftingSidebarResize(at windowX: CGFloat) {
    guard draftingSidebarVisible, let startWindowX = draftingSidebarDragStartWindowX else { return }
    let deltaX = windowX - startWindowX
    let proposedWidth = draftingSidebarDragStartWidth - deltaX
    applyDraftingSidebarWidth(proposedWidth, animated: false)
  }

  private func endDraftingSidebarResize() {
    draftingSidebarDragStartWindowX = nil
    draftingSidebarDragStartWidth = 0
  }

  private func setDraftingSidebarVisible(_ visible: Bool, focusInput: Bool = false) {
    guard draftingSidebarVisible != visible || focusInput else { return }
    guard !visible || normalizedDraftingSidebarMode(draftingSidebarMode) != nil else { return }
    draftingSidebarVisible = visible

    if visible {
      if draftingSidebarMode == .chat, draftingChatMessages.isEmpty {
        appendDraftingChatTranscript("system: drafting sidebar ready")
      }
      draftingSidebar.isHidden = false
    } else {
      if draftingSidebarMode == .chat {
        draftingStreamingLineIndex = nil
        draftingContextVisible = false
        draftingDiffVisible = false
        draftingContextScroll.isHidden = true
        draftingDiffScroll.isHidden = true
        draftingContextHeightConstraint?.constant = 0
        draftingDiffHeightConstraint?.constant = 0
        draftingChatContextButton.title = "Context"
        draftingChatDiffButton.title = "Diff"
        clearDraftingSidebarPendingAttachments()
        (agentAdapter as? AgentSidebarChatAdapting)?.resetChatSession()
        draftingSidebarChatAdapter?.resetChatSession()
      }
      endDraftingSidebarResize()
    }

    if visible {
      draftingSidebarResizeHandle.isHidden = false
      draftingSidebarResizeHandle.layer?.backgroundColor = colorTheme.secondaryText.withAlphaComponent(0.14).cgColor
      applyDraftingSidebarWidth(draftingSidebarPreferredWidth, animated: true)
    } else {
      draftingSidebarResizeHandle.isHidden = true
      draftingSidebarResizeHandle.layer?.backgroundColor = colorTheme.secondaryText.withAlphaComponent(0.0).cgColor
      mainStackTrailingConstraint?.constant = 0
      draftingSidebarWidthConstraint?.constant = 0
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.12
        view.layoutSubtreeIfNeeded()
        view.animator().layoutSubtreeIfNeeded()
      }
    }

    updateDraftingSidebarModeControls()
    updateDraftingSidebarControlState()

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if !visible {
        self.draftingSidebar.isHidden = true
      }
      if focusInput, visible, self.draftingSidebarMode == .chat {
        self.view.window?.makeFirstResponder(self.draftingChatInput)
      } else if visible, self.draftingSidebarMode == .queue {
        if self.selectedQueueIndex() != nil {
          self.view.window?.makeFirstResponder(self.queueEditor)
        } else {
          self.view.window?.makeFirstResponder(self.queueTableView)
        }
      } else if !visible {
        self.view.window?.makeFirstResponder(self.textView)
      }
    }
  }

  private func renderDraftingChatTranscript() {
    let joined = draftingChatMessages.joined(separator: "\n") + (draftingChatMessages.isEmpty ? "" : "\n")
    draftingChatTranscript.string = joined
    let end = (joined as NSString).length
    draftingChatTranscript.scrollRangeToVisible(NSRange(location: end, length: 0))
  }

  private func appendDraftingChatTranscript(_ line: String) {
    draftingChatMessages.append(line)
    renderDraftingChatTranscript()
  }

  private func beginDraftingAssistantStreamingLine() {
    if draftingStreamingLineIndex == nil {
      draftingStreamingLineIndex = draftingChatMessages.count
      draftingChatMessages.append("assistant: ")
      renderDraftingChatTranscript()
    }
  }

  private func appendDraftingAssistantStreamingDelta(_ delta: String) {
    guard !delta.isEmpty else { return }
    beginDraftingAssistantStreamingLine()
    guard let idx = draftingStreamingLineIndex, idx < draftingChatMessages.count else { return }
    draftingChatMessages[idx].append(delta)
    renderDraftingChatTranscript()
  }

  private func finalizeDraftingAssistantStreamingLine(finalText: String, routeLabel: String?) {
    let prefix: String = {
      if let routeLabel, !routeLabel.isEmpty {
        return "assistant (\(routeLabel)): "
      }
      return "assistant: "
    }()
    if let idx = draftingStreamingLineIndex, idx < draftingChatMessages.count {
      draftingChatMessages[idx] = "\(prefix)\(finalText)"
    } else {
      draftingChatMessages.append("\(prefix)\(finalText)")
    }
    draftingStreamingLineIndex = nil
    renderDraftingChatTranscript()
  }

  @objc private func draftingChatAddNoteAction(_ sender: Any?) {
    _ = submitDraftingChatNote(runImprove: false, annotationType: selectedDraftingAnnotationType())
  }

  @objc private func draftingChatAddImproveAction(_ sender: Any?) {
    _ = submitDraftingChatNote(runImprove: true, annotationType: selectedDraftingAnnotationType())
  }

  @objc private func draftingChatSendAction(_ sender: Any?) {
    _ = sendDraftingChatMessage()
  }

  @objc private func draftingChatCloseAction(_ sender: Any?) {
    setDraftingSidebarVisible(false)
  }

  @objc private func draftingChatToggleContextAction(_ sender: Any?) {
    draftingContextVisible.toggle()
    draftingContextScroll.isHidden = !draftingContextVisible
    draftingContextHeightConstraint?.constant = draftingContextVisible ? 140 : 0
    draftingChatContextButton.title = draftingContextVisible ? "Hide Context" : "Context"
    view.layoutSubtreeIfNeeded()
  }

  @objc private func draftingChatToggleDiffAction(_ sender: Any?) {
    draftingDiffVisible.toggle()
    draftingDiffScroll.isHidden = !draftingDiffVisible
    draftingDiffHeightConstraint?.constant = draftingDiffVisible ? 170 : 0
    draftingChatDiffButton.title = draftingDiffVisible ? "Hide Diff" : "Diff"
    view.layoutSubtreeIfNeeded()
  }

  @objc private func draftingChatApplySuggestionAction(_ sender: Any?) {
    guard let suggestion = draftingSidebarSuggestedDraft else {
      NSSound.beep()
      return
    }
    let current = textView.string
    guard current != suggestion else {
      banner.set(message: "Suggestion already matches current draft.", snapshotId: nil)
      banner.isHidden = false
      return
    }
    let diffSummary = lineDiffSummary(from: current, to: suggestion)
    replaceEntireDocumentWithUndo(suggestion, actionName: "Apply Drafting Suggestion")
    breakUndoCoalescingBoundary()
    pruneUnreferencedAttachedImages(using: textView.string)
    draftingSidebarSuggestedDraft = nil
    draftingLastDiffPreview = "Suggestion applied."
    draftingDiffView.string = draftingLastDiffPreview
    updateDraftingSidebarControlState()
    banner.set(message: "Applied sidebar suggestion.", snapshotId: nil)
    banner.isHidden = false
    appendDraftingChatTranscript("assistant: applied sidebar suggestion (Δ +\(diffSummary.insertions)/-\(diffSummary.removals) lines)")
  }

  @objc private func draftingChatAttachAction(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Attach"
    if let window = view.window ?? NSApp.mainWindow {
      panel.beginSheetModal(for: window) { [weak self] response in
        guard response == .OK else { return }
        self?.enqueueDraftingSidebarFiles(panel.urls)
      }
    } else {
      let response = panel.runModal()
      guard response == .OK else { return }
      enqueueDraftingSidebarFiles(panel.urls)
    }
  }

  @objc private func draftingChatClearAttachmentsAction(_ sender: Any?) {
    clearDraftingSidebarPendingAttachments()
  }

  private func draftingChatInputText() -> String {
    draftingChatInput.textStorage?.string ?? draftingChatInput.string
  }

  private func setDraftingChatInputText(_ text: String) {
    let existing = draftingChatInputText()
    let ns = existing as NSString
    draftingChatInput.setSelectedRange(NSRange(location: ns.length, length: 0))
    draftingChatInput.insertText(
      text,
      replacementRange: NSRange(location: 0, length: ns.length)
    )
    updateDraftingChatInputHeight()
  }

  private func updateDraftingSidebarControlState() {
    let busy = agentRunning || draftingChatRunning
    agentButton.isEnabled = !busy
    draftingChatSendButton.isEnabled = !busy
    draftingChatAddImproveButton.isEnabled = !busy
    draftingChatAddNoteButton.isEnabled = !busy
    draftingChatAttachButton.isEnabled = !busy
    draftingAnnotationTypePicker.isEnabled = !busy
    draftingChatContextButton.isEnabled = true
    draftingChatDiffButton.isEnabled = true
    draftingChatApplySuggestionButton.isEnabled = !busy && draftingSidebarSuggestedDraft != nil
    draftingChatClearAttachmentsButton.isEnabled = !busy && !draftingSidebarPendingAttachmentDisplay.isEmpty
    let queueAttached = isQueueSidebarAvailable()
    let hasSelection = selectedQueueIndex() != nil
    queueButton.isEnabled = queueAttached
    queueNewButton.isEnabled = queueAttached
    queueDeleteButton.isEnabled = queueAttached && hasSelection
    queueReloadButton.isEnabled = queueAttached
    queueSaveButton.isEnabled = queueAttached && queueDirty
    queueEditor.isEditable = queueAttached && hasSelection
  }

  nonisolated private func reportedRouteLabel(from adapter: AgentAdapting?) -> String? {
    reportedRouteLabel(from: adapter as? AgentRouteReporting)
  }

  nonisolated private func reportedRouteLabel(from reporting: AgentRouteReporting?) -> String? {
    guard let route = reporting?.lastRouteLabel.trimmingCharacters(in: .whitespacesAndNewlines),
          !route.isEmpty else { return nil }
    return route
  }

  nonisolated private func routeSuffix(_ routeLabel: String?) -> String {
    guard let routeLabel, !routeLabel.isEmpty else { return "" }
    return " via \(routeLabel)"
  }

  private func presentDraftingBusyMessage(for action: String) {
    let message: String
    if draftingChatRunning {
      message = "Drafting chat is already running. Wait for it to finish before \(action)."
    } else {
      message = "Drafting agent is already running. Wait for it to finish before \(action)."
    }
    banner.set(message: message, snapshotId: nil)
    banner.isHidden = false
    NSSound.beep()
  }

  private func updateDraftingChatInputHeight() {
    guard let textContainer = draftingChatInput.textContainer else { return }
    draftingChatInput.layoutManager?.ensureLayout(for: textContainer)
    let used = draftingChatInput.layoutManager?.usedRect(for: textContainer).height ?? 0
    let inset = draftingChatInput.textContainerInset
    let desired = ceil(used + inset.height * 2 + 2)
    let clamped = max(draftingChatInputMinHeight, min(draftingChatInputMaxHeight, desired))
    draftingChatInputHeightConstraint?.constant = clamped
    draftingChatInputScroll.hasVerticalScroller = desired > draftingChatInputMaxHeight
  }

  @discardableResult
  private func submitDraftingChatNote(runImprove: Bool, annotationType: DraftingAnnotationType) -> Bool {
    let note = draftingChatInputText().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    guard !note.isEmpty else {
      NSSound.beep()
      return false
    }
    var noteWithAttachments = note
    if !draftingSidebarPendingAttachmentRefs.isEmpty {
      noteWithAttachments += "\n" + draftingSidebarPendingAttachmentRefs.joined(separator: "\n")
    }

    let window = view.window
    let previousResponder = window?.firstResponder
    if let window {
      _ = window.makeFirstResponder(textView)
    }
    guard appendDraftingChatAnnotation(note: noteWithAttachments, type: annotationType.rawValue) else {
      if let window, draftingSidebarVisible {
        _ = window.makeFirstResponder(previousResponder)
      }
      NSSound.beep()
      return false
    }
    let attachmentSummary = draftingSidebarPendingAttachmentDisplay.isEmpty
      ? ""
      : " [\(draftingSidebarPendingAttachmentDisplay.count) attachment\(draftingSidebarPendingAttachmentDisplay.count == 1 ? "" : "s")]"
    appendDraftingChatTranscript("you: \(normalizeAnnotationContent(note))\(attachmentSummary)")
    setDraftingChatInputText("")
    clearDraftingSidebarPendingAttachments()

    if runImprove {
      appendDraftingChatTranscript("system: running drafting_agent improve")
      runAgent()
    } else {
      banner.set(message: "Added drafting \(annotationType.rawValue) annotation.", snapshotId: nil)
      banner.isHidden = false
    }
    if let window, draftingSidebarVisible {
      _ = window.makeFirstResponder(draftingChatInput)
    }
    return true
  }

  @discardableResult
  private func sendDraftingChatMessage() -> Bool {
    guard !draftingChatRunning, !agentRunning else {
      presentDraftingBusyMessage(for: "sending another chat message")
      return false
    }
    guard agentConfig.enabled else {
      banner.set(
        message: "Drafting agent is disabled. Added note instead.",
        snapshotId: nil
      )
      banner.isHidden = false
      return submitDraftingChatNote(runImprove: false, annotationType: selectedDraftingAnnotationType())
    }
    if agentAdapter == nil {
      agentAdapter = makeAgentAdapter()
    }
    guard let adapter = agentAdapter else {
      banner.set(
        message: "Drafting agent is not configured. Added note instead.",
        snapshotId: nil
      )
      banner.isHidden = false
      return submitDraftingChatNote(runImprove: false, annotationType: selectedDraftingAnnotationType())
    }
    guard let chatAdapter = makeSidebarChatAdapter() ?? (adapter as? AgentSidebarChatAdapting) else {
      banner.set(message: "Sidebar chat unavailable for backend \(agentConfig.backend.rawValue). Added note instead.", snapshotId: nil)
      banner.isHidden = false
      return submitDraftingChatNote(runImprove: false, annotationType: selectedDraftingAnnotationType())
    }

    let note = draftingChatInputText().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !note.isEmpty else {
      NSSound.beep()
      return false
    }
    var messageWithAttachments = note
    if !draftingSidebarPendingAttachmentRefs.isEmpty {
      messageWithAttachments += "\n" + draftingSidebarPendingAttachmentRefs.joined(separator: "\n")
    }

    let resolvedMessage = promptAndImagesForAgent(from: messageWithAttachments)
    let currentDraft = textView.string
    updateDraftingContextInspector(
      rawMessage: note,
      resolvedMessage: resolvedMessage.prompt,
      draftSnapshot: currentDraft,
      images: resolvedMessage.images,
      cwd: sessionCwd
    )
    resetDraftingDiffPreview()
    let attachmentSummary = draftingSidebarPendingAttachmentDisplay.isEmpty
      ? ""
      : " [\(draftingSidebarPendingAttachmentDisplay.count) attachment\(draftingSidebarPendingAttachmentDisplay.count == 1 ? "" : "s")]"
    appendDraftingChatTranscript("you: \(normalizeAnnotationContent(note))\(attachmentSummary)")
    setDraftingChatInputText("")
    clearDraftingSidebarPendingAttachments()

    draftingChatRunning = true
    updateDraftingSidebarControlState()
    appendDraftingChatTranscript("system: drafting_agent is thinking…")

    Task.detached(priority: .userInitiated) { [weak self, adapter, chatAdapter, resolvedMessage, currentDraft] in
      guard let self else { return }
      do {
        let reply: String
        if let streamingAdapter = chatAdapter as? AgentSidebarStreamingChatAdapting {
          reply = try await streamingAdapter.chat(
            message: resolvedMessage.prompt,
            draft: currentDraft,
            images: resolvedMessage.images,
            cwd: self.sessionCwd,
            onDelta: { [weak self] delta in
              guard !delta.isEmpty else { return }
              Task { @MainActor in
                self?.appendDraftingAssistantStreamingDelta(delta)
              }
            }
          )
        } else {
          reply = try await chatAdapter.chat(
            message: resolvedMessage.prompt,
            draft: currentDraft,
            images: resolvedMessage.images,
            cwd: self.sessionCwd
          )
        }
        await MainActor.run {
          let route = (chatAdapter as? AgentRouteReporting)?.lastRouteLabel
            ?? (adapter as? AgentRouteReporting)?.lastRouteLabel
          self.finalizeDraftingAssistantStreamingLine(finalText: reply, routeLabel: route)
          self.updateDraftingDiffPreview(fromAssistantReply: reply, draftSnapshot: currentDraft)
        }
      } catch {
        await MainActor.run {
          let route = self.reportedRouteLabel(from: chatAdapter as? AgentRouteReporting)
            ?? self.reportedRouteLabel(from: adapter)
          self.finalizeDraftingAssistantStreamingLine(finalText: "failed (\(error))", routeLabel: route)
          self.banner.set(message: "Drafting chat failed\(self.routeSuffix(route)): \(error)", snapshotId: nil)
          self.banner.isHidden = false
        }
      }
      await MainActor.run {
        self.draftingChatRunning = false
        self.updateDraftingSidebarControlState()
      }
    }

    return true
  }

  private func updateDraftingContextInspector(
    rawMessage: String,
    resolvedMessage: String,
    draftSnapshot: String,
    images: [URL],
    cwd: String?
  ) {
    var lines: [String] = []
    lines.append("### Sent Context")
    lines.append("cwd: \(cwd ?? FileManager.default.currentDirectoryPath)")
    if images.isEmpty {
      lines.append("images: none")
    } else {
      lines.append("images (\(images.count)):")
      lines.append(contentsOf: images.map { "- \($0.path)" })
    }
    lines.append("")
    if let attachment = externalSessionContextAttachment {
      lines.append("## Received Session Context")
      lines.append("source: \(attachment.source ?? "unknown")")
      lines.append("path: \(attachment.contextPath)")
      if let snapshot = externalSessionContextSnapshot {
        lines.append("bytes: \(snapshot.byteCount)\(snapshot.wasTruncated ? " (truncated)" : "")")
        lines.append("")
        lines.append(snapshot.displayText)
      } else if attachment.isSupportedFormat {
        lines.append("status: pending or unavailable")
      } else {
        let version = attachment.contextFormatVersion ?? ExternalSessionContextAttachment.supportedFormatVersion
        lines.append("status: unsupported format v\(version)")
      }
      lines.append("")
    }
    lines.append("## Raw Message")
    lines.append(rawMessage)
    lines.append("")
    lines.append("## Resolved Message Sent To drafting_agent")
    lines.append(resolvedMessage)
    lines.append("")
    lines.append("## Draft Snapshot Sent")
    lines.append(draftSnapshot)
    draftingLastSentContext = lines.joined(separator: "\n")
    draftingContextView.string = draftingLastSentContext
  }

  private func externalSessionContextBlockForAgent() -> String? {
    guard let attachment = externalSessionContextAttachment,
          attachment.isSupportedFormat,
          let snapshot = externalSessionContextSnapshot,
          !snapshot.agentText.isEmpty else { return nil }
    return """
## Invoking Session Context (background only)
- Source: \(attachment.source ?? "unknown")
- Use this only as background context for rewriting the prompt.
- Do not copy this section verbatim into the final refined prompt unless directly relevant.

\(snapshot.agentText)
"""
  }

  private func resetDraftingDiffPreview() {
    draftingSidebarSuggestedDraft = nil
    draftingLastDiffPreview = "No suggestion diff yet."
    draftingDiffView.string = draftingLastDiffPreview
    updateDraftingSidebarControlState()
  }

  private func updateDraftingDiffPreview(fromAssistantReply reply: String, draftSnapshot: String) {
    if let diffBlock = Self.extractDiffCodeBlock(from: reply), !diffBlock.isEmpty {
      draftingSidebarSuggestedDraft = nil
      draftingLastDiffPreview = diffBlock
      draftingDiffView.string = diffBlock
      draftingDiffVisible = true
      draftingDiffScroll.isHidden = false
      draftingDiffHeightConstraint?.constant = 170
      draftingChatDiffButton.title = "Hide Diff"
      updateDraftingSidebarControlState()
      return
    }

    guard let suggestedDraft = Self.extractSuggestedDraft(from: reply),
          !suggestedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          suggestedDraft != draftSnapshot
    else {
      draftingSidebarSuggestedDraft = nil
      draftingLastDiffPreview = "No apply-ready suggested draft detected in assistant response."
      draftingDiffView.string = draftingLastDiffPreview
      updateDraftingSidebarControlState()
      return
    }

    let diffText = Self.unifiedLineDiff(from: draftSnapshot, to: suggestedDraft)
    draftingSidebarSuggestedDraft = suggestedDraft
    draftingLastDiffPreview = diffText
    draftingDiffView.string = diffText
    draftingDiffVisible = true
    draftingDiffScroll.isHidden = false
    draftingDiffHeightConstraint?.constant = 170
    draftingChatDiffButton.title = "Hide Diff"
    updateDraftingSidebarControlState()
  }

  private func enqueueDraftingSidebarImages(_ images: [NSImage]) {
    guard !images.isEmpty else { return }
    var added = 0
    for image in images {
      guard let url = Self.saveTempImageBackground(image) else { continue }
      let id = String(UUID().uuidString.prefix(8).lowercased())
      attachedImages[id] = url
      queueDraftingSidebarAttachment(
        ref: "[image-\(id)]",
        displayName: "image-\(id).png"
      )
      added += 1
    }
    if added > 0 {
      appendDraftingChatTranscript("system: queued \(added) image attachment\(added == 1 ? "" : "s")")
    } else {
      NSSound.beep()
    }
  }

  private func enqueueDraftingSidebarFiles(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    let imageURLs = urls.filter { Self.supportedImageExtensions.contains($0.pathExtension.lowercased()) }
    let fileURLs = urls.filter { !Self.supportedImageExtensions.contains($0.pathExtension.lowercased()) }

    if !imageURLs.isEmpty {
      let images = imageURLs.compactMap { NSImage(contentsOf: $0) }
      enqueueDraftingSidebarImages(images)
    }

    var addedFiles = 0
    for url in fileURLs {
      queueDraftingSidebarAttachment(ref: "@\(url.path)", displayName: url.lastPathComponent)
      addedFiles += 1
    }
    if addedFiles > 0 {
      appendDraftingChatTranscript("system: queued \(addedFiles) file attachment\(addedFiles == 1 ? "" : "s")")
    }
  }

  private func queueDraftingSidebarAttachment(ref: String, displayName: String) {
    guard !ref.isEmpty else { return }
    guard draftingSidebarPendingAttachmentRefSet.insert(ref).inserted else { return }
    draftingSidebarPendingAttachmentRefs.append(ref)
    draftingSidebarPendingAttachmentDisplay.append(displayName)
    updateDraftingSidebarAttachmentSummary()
  }

  private func clearDraftingSidebarPendingAttachments() {
    draftingSidebarPendingAttachmentRefs.removeAll()
    draftingSidebarPendingAttachmentRefSet.removeAll()
    draftingSidebarPendingAttachmentDisplay.removeAll()
    updateDraftingSidebarAttachmentSummary()
  }

  private func updateDraftingSidebarAttachmentSummary() {
    if draftingSidebarPendingAttachmentDisplay.isEmpty {
      draftingChatAttachmentSummary.stringValue = "No attachments"
      updateDraftingSidebarControlState()
      return
    }
    let preview = draftingSidebarPendingAttachmentDisplay.prefix(2).joined(separator: ", ")
    let extra = draftingSidebarPendingAttachmentDisplay.count > 2
      ? " +\(draftingSidebarPendingAttachmentDisplay.count - 2) more"
      : ""
    draftingChatAttachmentSummary.stringValue = "\(draftingSidebarPendingAttachmentDisplay.count) attached: \(preview)\(extra)"
    updateDraftingSidebarControlState()
  }

  private func promptAndImagesForAgent(from text: String) -> (prompt: String, images: [URL]) {
    let ns = text as NSString
    let matches = imagePlaceholderRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    var promptText = text
    var images: [URL] = []

    if !matches.isEmpty {
      let mutable = NSMutableString(string: text)
      var seen = Set<String>()
      for match in matches.reversed() {
        let id = ns.substring(with: match.range(at: 1))
        guard let url = attachedImages[id] else { continue }
        mutable.replaceCharacters(in: match.range, with: "@\(url.path)")
        if seen.insert(id).inserted {
          images.append(url)
        }
      }
      promptText = mutable as String
      images.reverse()
    }

    if agentConfig.annotationEnabled {
      let annotations = parseDraftingAnnotations(in: promptText)
      if !annotations.isEmpty {
        let lines = annotations.map { "- [\($0.type)] \($0.content)" }.joined(separator: "\n")
        promptText += "\n\n## Drafting Annotations\n\(lines)\n"
      }
    }

    if let contextBlock = externalSessionContextBlockForAgent() {
      promptText += "\n\n\(contextBlock)\n"
    }

    return (promptText, images)
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
    draftingSidebar.layer?.backgroundColor = t.banner.withAlphaComponent(0.97).cgColor
    draftingSidebar.layer?.borderColor = t.secondaryText.withAlphaComponent(0.28).cgColor
    draftingSidebarResizeHandle.layer?.backgroundColor = t.secondaryText.withAlphaComponent(draftingSidebarVisible ? 0.14 : 0.0).cgColor
    draftingChatTitle.textColor = t.foreground
    draftingChatSubtitle.textColor = t.secondaryText
    draftingChatTranscript.textColor = t.foreground
    draftingChatInput.textColor = t.foreground
    draftingChatInput.insertionPointColor = t.caret
    draftingChatInput.backgroundColor = t.background.withAlphaComponent(0.55)
    draftingChatInputScroll.layer?.backgroundColor = t.background.withAlphaComponent(0.42).cgColor
    draftingChatInputScroll.layer?.borderColor = t.secondaryText.withAlphaComponent(0.38).cgColor
    draftingContextView.textColor = t.foreground
    draftingContextScroll.layer?.backgroundColor = t.background.withAlphaComponent(0.42).cgColor
    draftingContextScroll.layer?.borderColor = t.secondaryText.withAlphaComponent(0.38).cgColor
    draftingDiffView.textColor = t.foreground
    draftingDiffScroll.layer?.backgroundColor = t.background.withAlphaComponent(0.42).cgColor
    draftingDiffScroll.layer?.borderColor = t.secondaryText.withAlphaComponent(0.38).cgColor
    queueTitle.textColor = t.foreground
    queueSubtitle.textColor = t.secondaryText
    queueStatusLabel.textColor = t.secondaryText
    queueEditor.textColor = t.foreground
    queueEditor.insertionPointColor = t.caret
    queueEditorScroll.layer?.backgroundColor = t.background.withAlphaComponent(0.42).cgColor
    queueEditorScroll.layer?.borderColor = t.secondaryText.withAlphaComponent(0.38).cgColor
    queueTableScroll.layer?.backgroundColor = t.background.withAlphaComponent(0.42).cgColor
    queueTableScroll.layer?.borderColor = t.secondaryText.withAlphaComponent(0.38).cgColor
    queueNewButton.contentTintColor = t.link
    queueDeleteButton.contentTintColor = t.secondaryText.withAlphaComponent(0.95)
    queueReloadButton.contentTintColor = t.link
    queueSaveButton.contentTintColor = t.link
    queueCloseButton.contentTintColor = t.secondaryText.withAlphaComponent(0.95)
    draftingChatAttachmentSummary.textColor = t.secondaryText
    draftingChatAttachButton.contentTintColor = t.link
    draftingChatClearAttachmentsButton.contentTintColor = t.secondaryText.withAlphaComponent(0.95)
    draftingChatContextButton.contentTintColor = t.link
    draftingChatDiffButton.contentTintColor = t.link
    draftingChatAddImproveButton.contentTintColor = t.link
    draftingChatAddNoteButton.contentTintColor = t.secondaryText.withAlphaComponent(0.95)
    draftingChatApplySuggestionButton.contentTintColor = t.link
    draftingChatCloseButton.contentTintColor = t.secondaryText.withAlphaComponent(0.95)
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
    let sidebarSize = max(12, sz - 1)
    draftingChatTranscript.font = NSFont.monospacedSystemFont(ofSize: sidebarSize, weight: .regular)
    draftingChatInput.font = NSFont.monospacedSystemFont(ofSize: sidebarSize, weight: .regular)
    draftingContextView.font = NSFont.monospacedSystemFont(ofSize: max(11, sidebarSize - 1), weight: .regular)
    draftingDiffView.font = NSFont.monospacedSystemFont(ofSize: max(11, sidebarSize - 1), weight: .regular)
    queueEditor.font = NSFont.monospacedSystemFont(ofSize: sidebarSize, weight: .regular)
    let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
    if fullRange.length > 0 {
      applyStyling(forChangedRange: fullRange)
    }
  }

  func focusEditor() {
    guard view.window != nil else { return }
    if isEditorFirstResponder() {
      recordSessionReadyIfNeeded()
      return
    }
    guard let window = view.window, window.isVisible else { return }
    guard NSApp.isActive, window.isKeyWindow else { return }
    guard window.firstResponder !== textView else {
      recordSessionReadyIfNeeded()
      return
    }

    _ = window.makeFirstResponder(textView)
    #if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
    let len = (textView.string as NSString).length
    var sel = textView.selectedRange()
    if sel.location == NSNotFound {
      sel = NSRange(location: len, length: 0)
    } else {
      sel = NSRange(location: min(sel.location, len), length: 0)
    }
    textView.setSelectedRange(sel)
    textView.scrollRangeToVisible(sel)
    #endif
    recordSessionReadyIfNeeded()
  }

  func waitUntilEditorReady(timeoutMs: Int = 320) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, timeoutMs)) * 1_000_000
    var nextFocusAttemptNs = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if isEditorFirstResponder() {
        recordSessionReadyIfNeeded()
        return true
      }
      let now = DispatchTime.now().uptimeNanoseconds
      if now >= nextFocusAttemptNs {
        focusEditor()
        nextFocusAttemptNs = now + 24_000_000
      }
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

  func setExternalQueueAttachment(_ attachment: ExternalQueueAttachment?) {
    let oldPath = externalQueueAttachment?.queuePath
    queueLoadTask?.cancel()
    queueLoadTask = nil
    queueSaveTask?.cancel()
    queueSaveTask = nil
    queueWatcherDebouncer.cancel()
    externalQueueAttachment = attachment
    if oldPath != attachment?.queuePath {
      queueWatcher?.stop()
      queueWatcher = nil
      queueActiveAttachmentPath = nil
      queueDirty = false
      queueFingerprint = nil
      queueObservedDiskState = QueueDiskState(absent: true, fileSize: nil, modifiedAt: nil)
    }

    refreshQueueAttachmentPresentation()
    reconcileQueueAttachmentState(
      reason: "queue attachment changed",
      allowAutoReveal: externalSessionQueuesConfig.autoRevealOnAttach
    )
    updateDraftingSidebarModeControls()
    updateDraftingSidebarControlState()
  }

  func setExternalSessionQueues(_ settings: TurboDraftConfig.ExternalSessionQueues) {
    let old = externalSessionQueuesConfig
    externalSessionQueuesConfig = settings
    refreshQueueAttachmentPresentation()
    let allowAutoReveal = settings.enabled && settings.autoRevealOnAttach
      && (!old.enabled || (!old.autoRevealOnAttach && settings.autoRevealOnAttach))
    reconcileQueueAttachmentState(reason: "queue settings changed", allowAutoReveal: allowAutoReveal)
    updateDraftingSidebarModeControls()
    updateDraftingSidebarControlState()
  }

  func setExternalSessionContextAttachment(_ attachment: ExternalSessionContextAttachment?) {
    externalSessionContextLoadTask?.cancel()
    externalSessionContextLoadTask = nil
    externalSessionContextAttachment = attachment
    externalSessionContextSnapshot = nil

    guard let attachment, attachment.isSupportedFormat else { return }

    externalSessionContextLoadTask = Task { @MainActor [weak self, attachment] in
      let snapshot = try? await Task.detached(priority: .utility) {
        try ExternalSessionContextSnapshot.load(from: attachment)
      }.value
      guard let self else { return }
      guard self.externalSessionContextAttachment == attachment else { return }
      self.externalSessionContextSnapshot = snapshot
      self.externalSessionContextLoadTask = nil
    }
  }

  @objc private func draftingSidebarModeChanged(_ sender: NSSegmentedControl) {
    guard let mode = DraftingSidebarMode(rawValue: sender.selectedSegment) else { return }
    guard normalizedDraftingSidebarMode(mode) != nil else {
      NSSound.beep()
      updateDraftingSidebarModeControls()
      return
    }
    setDraftingSidebarMode(mode)
    if draftingSidebarVisible {
      setDraftingSidebarVisible(true, focusInput: mode == .chat)
    }
  }

  @objc private func queueSelectionDidChange(_ sender: Any?) {
    let row = queueTableView.selectedRow
    if row >= 0, row < queueItems.count {
      selectQueueItem(localID: queueItems[row].localID, focusEditor: false)
    } else {
      selectQueueItem(localID: nil, focusEditor: false)
    }
  }

  @objc private func queueNewAction(_ sender: Any?) {
    guard isQueueSidebarAvailable() else {
      NSSound.beep()
      return
    }
    activateQueueAttachmentIfNeeded(reason: "queue new")
    commitQueueEditorToSelection()
    let seedPrompt = selectedEditorTextForQueueSeed() ?? ""
    let item = SharedQueueItem.newItem(prompt: seedPrompt)
    queueItems.append(item)
    queueDirty = true
    queueTableView.reloadData()
    selectQueueItem(localID: item.localID, focusEditor: true)
    queueStatusLabel.stringValue = seedPrompt.isEmpty
      ? "Added empty queued prompt. Save to persist."
      : "Added queued prompt from current selection. Save to persist."
    updateDraftingSidebarControlState()
  }

  @objc private func queueDeleteAction(_ sender: Any?) {
    activateQueueAttachmentIfNeeded(reason: "queue delete")
    guard let index = selectedQueueIndex() else {
      NSSound.beep()
      return
    }
    queueItems.remove(at: index)
    queueDirty = true
    queueTableView.reloadData()
    let nextSelection = min(index, queueItems.count - 1)
    if nextSelection >= 0, nextSelection < queueItems.count {
      selectQueueItem(localID: queueItems[nextSelection].localID, focusEditor: false)
    } else {
      selectQueueItem(localID: nil, focusEditor: false)
    }
    queueStatusLabel.stringValue = queueItems.isEmpty
      ? "Queue cleared locally. Save to remove the shared queue file."
      : "Deleted queued prompt locally. Save to persist."
    updateDraftingSidebarControlState()
  }

  @objc private func queueReloadAction(_ sender: Any?) {
    activateQueueAttachmentIfNeeded(reason: "queue reload")
    reloadQueueFromDisk(force: true, reason: "queue reloaded")
  }

  @objc private func queueSaveAction(_ sender: Any?) {
    activateQueueAttachmentIfNeeded(reason: "queue save")
    saveQueueToDisk()
  }

  private func queueFileURL() -> URL? {
    guard isQueueSidebarAvailable(),
          let attachment = externalQueueAttachment,
          attachment.isSupportedFormat else { return nil }
    let path = attachment.queuePath
    guard !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path)
  }

  private func resetQueueState(statusMessage: String) {
    queueWatcher?.stop()
    queueWatcher = nil
    queueActiveAttachmentPath = nil
    queueItems.removeAll()
    queueSelectedLocalID = nil
    queueFingerprint = nil
    queueObservedDiskState = QueueDiskState(absent: true, fileSize: nil, modifiedAt: nil)
    queueDirty = false
    isApplyingQueueEditorUpdate = true
    queueEditor.string = ""
    isApplyingQueueEditorUpdate = false
    queueTableView.reloadData()
    queueStatusLabel.stringValue = statusMessage
  }

  private func refreshQueueAttachmentPresentation() {
    guard let attachment = externalQueueAttachment else {
      queueSubtitle.stringValue = "Shared external session queue"
      return
    }
    var parts: [String] = []
    if let source = attachment.source {
      parts.append(source)
    }
    if let key = attachment.queueKey {
      parts.append("key: \(key)")
    }
    let version = attachment.queueFormatVersion ?? ExternalQueueAttachment.supportedFormatVersion
    parts.append("format v\(version)")
    if !isExternalQueueIntegrationEnabled() {
      parts.append("disabled in settings")
    }
    queueSubtitle.stringValue = parts.joined(separator: " • ")
  }

  private func unsupportedQueueStatus(for attachment: ExternalQueueAttachment) -> String {
    let version = attachment.queueFormatVersion ?? -1
    return "Unsupported shared queue format v\(version). TurboDraft supports v\(ExternalQueueAttachment.supportedFormatVersion)."
  }

  private func disabledQueueStatus() -> String {
    "External session queues are disabled in settings."
  }

  private func fallbackFromQueueSidebarIfNeeded() {
    guard draftingSidebarMode == .queue else { return }
    if isChatSidebarAvailable() {
      setDraftingSidebarMode(.chat)
    } else {
      setDraftingSidebarVisible(false)
    }
  }

  private func reconcileQueueAttachmentState(reason: String, allowAutoReveal: Bool) {
    guard let attachment = externalQueueAttachment else {
      resetQueueState(statusMessage: unattachedQueueStatus())
      fallbackFromQueueSidebarIfNeeded()
      return
    }

    guard isExternalQueueIntegrationEnabled() else {
      resetQueueState(statusMessage: disabledQueueStatus())
      fallbackFromQueueSidebarIfNeeded()
      return
    }

    guard attachment.isSupportedFormat else {
      resetQueueState(statusMessage: unsupportedQueueStatus(for: attachment))
      fallbackFromQueueSidebarIfNeeded()
      return
    }

    if allowAutoReveal {
      setDraftingSidebarMode(.queue)
      setDraftingSidebarVisible(true, focusInput: false)
      return
    }

    if draftingSidebarVisible, draftingSidebarMode == .queue {
      activateQueueAttachmentIfNeeded(reason: reason)
    } else if queueFingerprint == nil {
      queueStatusLabel.stringValue = "Queue attached. Open Queue to load."
    }
  }

  private func unattachedQueueStatus() -> String {
    if externalQueueAttachment != nil && !isExternalQueueIntegrationEnabled() {
      return disabledQueueStatus()
    }
    return "No external session queue attached."
  }

  private func currentQueueDiskState(for url: URL) -> QueueDiskState {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path),
          let attrs = try? fm.attributesOfItem(atPath: url.path) else {
      return QueueDiskState(absent: true, fileSize: nil, modifiedAt: nil)
    }
    return QueueDiskState(
      absent: false,
      fileSize: attrs[.size] as? Int,
      modifiedAt: attrs[.modificationDate] as? Date
    )
  }

  private func attachQueueWatcher(for attachment: ExternalQueueAttachment) {
    queueWatcher?.stop()
    queueWatcher = nil
    let url = URL(fileURLWithPath: attachment.queuePath)
    let watchURL = url.deletingLastPathComponent()
    queueObservedDiskState = currentQueueDiskState(for: url)
    do {
      let watcher = try DirectoryWatcher(directoryURL: watchURL)
      queueWatcher = watcher
      queueActiveAttachmentPath = attachment.queuePath
      watcher.start { [weak self] in
        guard let self else { return }
        Task { @MainActor in
          self.handleQueueWatcherEvent()
        }
      }
    } catch {
      queueStatusLabel.stringValue = "Queue watcher unavailable: \(error.localizedDescription)"
    }
  }

  private func activateQueueAttachmentIfNeeded(reason: String) {
    guard isQueueSidebarAvailable(),
          let attachment = externalQueueAttachment,
          attachment.isSupportedFormat
    else { return }

    if queueActiveAttachmentPath != attachment.queuePath || queueWatcher == nil {
      attachQueueWatcher(for: attachment)
    }

    if queueActiveAttachmentPath != attachment.queuePath || queueFingerprint == nil {
      reloadQueueFromDisk(force: true, reason: reason)
    }
  }

  private func handleQueueWatcherEvent() {
    guard let url = queueFileURL() else { return }
    let diskState = currentQueueDiskState(for: url)
    guard diskState != queueObservedDiskState else { return }
    queueObservedDiskState = diskState
    queueWatcherDebouncer.schedule(delayMs: 120) { [weak self] in
      guard let self else { return }
      await MainActor.run {
        self.reloadQueueFromDisk(force: false, reason: "queue changed on disk")
      }
    }
  }

  private func reloadQueueFromDisk(force: Bool, reason: String) {
    queueLoadTask?.cancel()
    queueLoadGeneration += 1
    let generation = queueLoadGeneration
    guard let url = queueFileURL() else {
      queueStatusLabel.stringValue = unattachedQueueStatus()
      queueItems.removeAll()
      queueSelectedLocalID = nil
      queueFingerprint = nil
      queueObservedDiskState = QueueDiskState(absent: true, fileSize: nil, modifiedAt: nil)
      queueDirty = false
      queueTableView.reloadData()
      updateQueueEditorFromSelection()
      updateDraftingSidebarControlState()
      return
    }
    guard let attachment = externalQueueAttachment else { return }
    let currentPath = attachment.queuePath
    let currentFingerprint = queueFingerprint
    let dirtyAtStart = queueDirty
    queueStatusLabel.stringValue = reason == "queue attached" ? "Loading shared queue…" : queueStatusLabel.stringValue

    queueLoadTask = Task { @MainActor [weak self] in
      let result = await Task.detached(priority: .utility) { () -> Result<SharedQueueFileSnapshot, Error> in
        Result { try SharedQueueFileStore.load(from: url) }
      }.value
      guard let self else { return }
      defer {
        if self.queueLoadGeneration == generation {
          self.queueLoadTask = nil
        }
      }
      guard !Task.isCancelled else { return }
      guard self.externalQueueAttachment?.queuePath == currentPath else { return }

      switch result {
      case let .success(snapshot):
        self.queueObservedDiskState = self.currentQueueDiskState(for: url)
        if !force, dirtyAtStart, snapshot.fingerprint != currentFingerprint {
          self.queueStatusLabel.stringValue = "Queue changed on disk. Reload to compare before saving."
        } else if !force, snapshot.fingerprint != currentFingerprint || currentFingerprint == nil {
          self.applyQueueSnapshot(snapshot, statusMessage: self.loadedQueueStatus(for: snapshot))
        } else if force {
          self.applyQueueSnapshot(snapshot, statusMessage: self.loadedQueueStatus(for: snapshot))
        }
      case let .failure(error):
        self.queueStatusLabel.stringValue = "Failed to load queue: \(error.localizedDescription)"
        NSSound.beep()
      }
    }
  }

  private func saveQueueToDisk() {
    guard let url = queueFileURL() else {
      NSSound.beep()
      queueStatusLabel.stringValue = unattachedQueueStatus()
      return
    }
    guard queueSaveTask == nil else {
      queueStatusLabel.stringValue = "Queue save already in progress."
      return
    }
    queueSaveGeneration += 1
    let generation = queueSaveGeneration

    commitQueueEditorToSelection()
    guard let attachment = externalQueueAttachment else { return }
    let currentPath = attachment.queuePath
    let itemsToSave = queueItems
    let expectedFingerprint = queueFingerprint
    queueStatusLabel.stringValue = "Saving shared queue…"

    queueSaveTask = Task { @MainActor [weak self] in
      let result = await Task.detached(priority: .utility) { () -> Result<SharedQueueFileSnapshot, Error> in
        Result {
          try SharedQueueFileStore.write(
            itemsToSave,
            to: url,
            expectedFingerprint: expectedFingerprint,
            enforceFingerprint: true
          )
        }
      }.value
      guard let self else { return }
      defer {
        if self.queueSaveGeneration == generation {
          self.queueSaveTask = nil
        }
      }
      guard !Task.isCancelled else { return }
      guard self.externalQueueAttachment?.queuePath == currentPath else { return }

      switch result {
      case let .success(saved):
        self.queueObservedDiskState = self.currentQueueDiskState(for: url)
        let message: String
        if saved.items.isEmpty {
          message = "Saved empty queue. Shared queue file removed."
        } else {
          message = "Saved \(saved.items.count) queued prompt\(saved.items.count == 1 ? "" : "s")."
        }
        self.applyQueueSnapshot(saved, statusMessage: message)
      case .failure(SharedQueueFileStoreError.conflict(expected: _, actual: _)):
        self.queueObservedDiskState = self.currentQueueDiskState(for: url)
        self.queueStatusLabel.stringValue = "Queue changed on disk. Reload before saving."
        NSSound.beep()
      case let .failure(error):
        self.queueStatusLabel.stringValue = "Failed to save queue: \(error.localizedDescription)"
        NSSound.beep()
      }
    }
  }

  private func applyQueueSnapshot(_ snapshot: SharedQueueFileSnapshot, statusMessage: String) {
    let previousSelection = queueSelectedLocalID
    queueItems = snapshot.items
    queueFingerprint = snapshot.fingerprint
    queueDirty = false
    queueTableView.reloadData()
    if let previousSelection, snapshot.items.contains(where: { $0.localID == previousSelection }) {
      selectQueueItem(localID: previousSelection, focusEditor: false)
    } else if let first = snapshot.items.first {
      selectQueueItem(localID: first.localID, focusEditor: false)
    } else {
      selectQueueItem(localID: nil, focusEditor: false)
    }
    queueStatusLabel.stringValue = statusMessage
    updateDraftingSidebarControlState()
  }

  private func loadedQueueStatus(for snapshot: SharedQueueFileSnapshot) -> String {
    if snapshot.items.isEmpty {
      return "Queue is empty."
    }
    return "Loaded \(snapshot.items.count) queued prompt\(snapshot.items.count == 1 ? "" : "s")."
  }

  private func selectedQueueIndex() -> Int? {
    guard let localID = queueSelectedLocalID else { return nil }
    return queueItems.firstIndex(where: { $0.localID == localID })
  }

  private func selectQueueItem(localID: String?, focusEditor: Bool) {
    queueSelectedLocalID = localID
    let row = selectedQueueIndex()
    let rowIndex = row ?? -1
    if queueTableView.selectedRow != rowIndex {
      if let row {
        queueTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      } else {
        queueTableView.deselectAll(nil)
      }
    }
    updateQueueEditorFromSelection()
    if focusEditor, draftingSidebarVisible, draftingSidebarMode == .queue, row != nil {
      view.window?.makeFirstResponder(queueEditor)
    }
    updateDraftingSidebarControlState()
  }

  private func updateQueueEditorFromSelection() {
    let prompt = selectedQueueIndex().map { queueItems[$0].prompt } ?? ""
    isApplyingQueueEditorUpdate = true
    queueEditor.string = prompt
    isApplyingQueueEditorUpdate = false
    queueEditorScroll.hasVerticalScroller = true
  }

  private func selectedEditorTextForQueueSeed() -> String? {
    let selection = textView.selectedRange()
    guard selection.length > 0 else { return nil }
    let ns = textView.string as NSString
    guard selection.location >= 0, selection.location + selection.length <= ns.length else { return nil }
    let selectedText = ns.substring(with: selection)
    return selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : selectedText
  }

  private func commitQueueEditorToSelection() {
    guard !isApplyingQueueEditorUpdate, let index = selectedQueueIndex() else { return }
    let newPrompt = queueEditor.string
    if queueItems[index].prompt != newPrompt {
      queueItems[index].prompt = newPrompt
      queueDirty = true
      queueTableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }
  }

  private func handleQueueEditorTextDidChange() {
    guard !isApplyingQueueEditorUpdate, let index = selectedQueueIndex() else { return }
    let newPrompt = queueEditor.string
    if queueItems[index].prompt != newPrompt {
      queueItems[index].prompt = newPrompt
      queueDirty = true
      queueStatusLabel.stringValue = "Queue edited locally. Save to persist."
      queueTableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
      updateDraftingSidebarControlState()
    }
  }

  private func queuePreviewText(for item: SharedQueueItem) -> String {
    let trimmed = item.prompt
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isNewline)
      .first
      .map(String.init) ?? ""
    return trimmed.isEmpty ? "(empty prompt)" : trimmed
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
    if let changedTextView = note.object as? NSTextView, changedTextView === queueEditor {
      handleQueueEditorTextDidChange()
      return
    }
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
    editorFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
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
    guard !agentRunning, !draftingChatRunning else {
      presentDraftingBusyMessage(for: "improving the prompt")
      return
    }
    guard agentConfig.enabled else {
      banner.set(message: "Drafting agent is disabled. Enable it from the Drafting menu.", snapshotId: nil)
      banner.isHidden = false
      return
    }

    if agentAdapter == nil {
      agentAdapter = makeAgentAdapter()
    }

    guard let adapter = agentAdapter else {
      banner.set(message: "Drafting agent is not configured (install Codex/Claude CLI and ensure command is in PATH).", snapshotId: nil)
      banner.isHidden = false
      return
    }

    let instruction = draftingAdditionalInstruction()
    let basePrompt = textView.string

    let oldTitle = agentButton.title
    agentButton.title = "Improving..."
    agentButton.isEnabled = false
    agentRunning = true
    updateDraftingSidebarControlState()
    banner.set(message: "Running drafting agent...", snapshotId: nil)
    banner.isHidden = false
    appendDraftingChatTranscript("system: running drafting_agent improve")

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
        let route = reportedRouteLabel(from: adapter)

        let currentText = await MainActor.run { self.textView.string }
        if draft == currentText {
          await MainActor.run {
            self.appendDraftingChatTranscript("assistant: no changes suggested\(self.routeSuffix(route))")
            self.banner.set(message: "Drafting agent returned no changes\(self.routeSuffix(route)).", snapshotId: nil)
            self.banner.isHidden = false
          }
          return
        }
        let diffSummary = lineDiffSummary(from: currentText, to: draft)
        await session.updateBufferContent(currentText)
        let restoreId = await session.snapshot(reason: "before_agent_apply")
        await MainActor.run {
          let diffLabel = "Δ +\(diffSummary.insertions)/-\(diffSummary.removals) lines"
          if let route {
            self.appendDraftingChatTranscript("assistant: applied improved draft (\(route), \(diffLabel))")
          } else {
            self.appendDraftingChatTranscript("assistant: applied improved draft (\(diffLabel))")
          }
          self.replaceEntireDocumentWithUndo(draft, actionName: "Improve Prompt")
          self.breakUndoCoalescingBoundary()
          self.banner.set(message: "Applied agent output\(self.routeSuffix(route)). You can restore your previous buffer.", snapshotId: restoreId)
          self.banner.isHidden = false
          self.pruneUnreferencedAttachedImages(using: self.textView.string)
        }
      } catch {
        await MainActor.run {
          let route = self.reportedRouteLabel(from: adapter)
          self.appendDraftingChatTranscript("assistant: failed\(self.routeSuffix(route)) (\(error))")
          self.banner.set(message: "Agent failed\(self.routeSuffix(route)): \(error)", snapshotId: nil)
          self.banner.isHidden = false
        }
      }

      await MainActor.run {
        self.agentButton.title = oldTitle
        self.agentButton.isEnabled = true
        self.agentRunning = false
        self.updateDraftingSidebarControlState()
      }
    }
  }

  private func cleanUpAttachedImages() {
    for url in attachedImages.values { try? FileManager.default.removeItem(at: url) }
    attachedImages.removeAll()
  }

  private nonisolated func lineDiffSummary(from old: String, to new: String) -> (insertions: Int, removals: Int) {
    let oldLines = old.components(separatedBy: "\n")
    let newLines = new.components(separatedBy: "\n")
    let diff = newLines.difference(from: oldLines)
    var insertions = 0
    var removals = 0
    for change in diff {
      switch change {
      case .insert:
        insertions += 1
      case .remove:
        removals += 1
      }
    }
    return (insertions, removals)
  }

  static func extractSuggestedDraft(from assistantReply: String) -> String? {
    let blocks = fencedCodeBlocks(in: assistantReply)
    let preferred = blocks
      .filter { block in
        let lang = block.language.lowercased()
        if lang == "diff" || lang == "patch" { return false }
        if lang.isEmpty { return true }
        return ["markdown", "md", "text", "txt", "prompt"].contains(lang)
      }
      .sorted { $0.content.count > $1.content.count }
    if let first = preferred.first {
      let trimmed = first.content.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }

    let fallback = assistantReply.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fallback.isEmpty else { return nil }
    if fallback.hasPrefix("#") || fallback.hasPrefix("- ") || fallback.hasPrefix("1. ") {
      return fallback
    }
    return nil
  }

  static func extractDiffCodeBlock(from assistantReply: String) -> String? {
    let blocks = fencedCodeBlocks(in: assistantReply)
    if let diff = blocks.first(where: { ["diff", "patch"].contains($0.language.lowercased()) }) {
      let trimmed = diff.content.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    let trimmed = assistantReply.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("--- ") && trimmed.contains("\n+++ ") {
      return trimmed
    }
    return nil
  }

  static func unifiedLineDiff(from old: String, to new: String) -> String {
    if old == new {
      return "No line changes."
    }

    let oldLines = old.components(separatedBy: "\n")
    let newLines = new.components(separatedBy: "\n")
    let diff = newLines.difference(from: oldLines)
    struct Operation {
      let offset: Int
      let priority: Int
      let line: String
    }
    var ops: [Operation] = []
    ops.reserveCapacity(diff.count)
    for change in diff {
      switch change {
      case let .remove(offset, element, _):
        ops.append(Operation(offset: offset, priority: 0, line: "-\(element)"))
      case let .insert(offset, element, _):
        ops.append(Operation(offset: offset, priority: 1, line: "+\(element)"))
      }
    }
    ops.sort {
      if $0.offset == $1.offset { return $0.priority < $1.priority }
      return $0.offset < $1.offset
    }

    var lines: [String] = ["--- current", "+++ suggested", "@@"]
    lines.append(contentsOf: ops.map(\.line))
    return lines.joined(separator: "\n")
  }

  private static func fencedCodeBlocks(in text: String) -> [(language: String, content: String)] {
    let ns = text as NSString
    let matches = fencedCodeBlockRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    var out: [(language: String, content: String)] = []
    out.reserveCapacity(matches.count)
    for match in matches {
      guard match.numberOfRanges >= 3 else { continue }
      let language = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
      let content = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
      out.append((language: language, content: content))
    }
    return out
  }

  private func draftingAdditionalInstruction() -> String {
    var lines: [String] = []
    let preset = agentConfig.draftingPreset
    let isPivotPreset: Bool = {
      switch preset {
      case .pivotKrEnTranslate, .pivotKrEnReasonKo, .pivotKrEnOptimizeKo:
        return true
      default:
        return false
      }
    }()

    lines.append("- In the final refined prompt text, do not mention drafting_agent or execution_agent.")

    switch agentConfig.pluginPolicy {
    case .denyAll:
      lines.append("- Plugin/tool usage policy for drafting_agent: do not use any plugins/tools.")
    case .allowAll:
      lines.append("- Plugin/tool usage policy for drafting_agent: plugin/tool usage is allowed if necessary.")
    case .curatedAllowlist:
      if agentConfig.pluginAllowlist.isEmpty {
        lines.append("- Plugin/tool usage policy for drafting_agent: default deny (no plugins allowed unless explicitly listed).")
      } else {
        let safeAllowlist = agentConfig.pluginAllowlist.map { Self.sanitizeInstructionToken($0) }
        lines.append("- Plugin/tool usage policy for drafting_agent: allow only [\(safeAllowlist.joined(separator: ", "))].")
      }
    }

    if agentConfig.askQuestionScope == .refinementOnly {
      lines.append("- If you need clarification, ask only prompt-refinement questions, never task-execution questions.")
    }

    if agentConfig.taskInstructionMode == .abstract && !isPivotPreset {
      lines.append("- Include a task-planning instruction that tells the downstream model to create/manage a checklist or task list while executing.")
    }

    return lines.joined(separator: "\n")
  }

  private static func sanitizeInstructionToken(_ value: String) -> String {
    let collapsed = value
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed
  }

  private func applyAgentConfig() {
    agentRow.isHidden = false
    agentButton.isHidden = !agentConfig.enabled
    if !isChatSidebarAvailable(), draftingSidebarMode == .chat {
      if isQueueSidebarAvailable() {
        setDraftingSidebarMode(.queue)
      } else {
        setDraftingSidebarVisible(false)
      }
    }
    agentAdapter = agentConfig.enabled ? makeAgentAdapter() : nil
    draftingSidebarChatAdapter = nil
    updateDraftingSidebarModeControls()
    updateDraftingSidebarControlState()
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
      if agentConfig.providerBackend == .litellm {
        let primary = makeCodexExecAdapter(
          timeoutMs: agentConfig.timeoutMs,
          environmentOverrides: [:],
          routeLabel: "codex exec (direct)"
        )
        let fallback = makeCodexExecAdapter(
          timeoutMs: agentConfig.timeoutMs,
          environmentOverrides: liteLLMEnvironmentOverrides(),
          routeLabel: "codex exec (litellm)"
        )
        return FallbackPromptEngineerAdapter(
          primary: primary,
          fallback: fallback,
          primaryLabel: "codex exec (direct)",
          fallbackLabel: "codex exec (litellm)"
        )
      }
      return makeCodexExecAdapter(
        timeoutMs: agentConfig.timeoutMs,
        environmentOverrides: [:],
        routeLabel: "codex exec (direct)"
      )
    case .appServer:
      if agentConfig.command == "codex" {
        return makeCodexAdaptiveDraftingAdapter(preferredBackend: .appServer)
      }
      return makeCodexAppServerAdapter(
        timeoutMs: agentConfig.timeoutMs,
        environmentOverrides: agentConfig.providerBackend == .litellm ? liteLLMEnvironmentOverrides() : [:],
        routeLabel: agentConfig.providerBackend == .litellm ? "codex app-server (litellm)" : "codex app-server (direct)"
      )
    case .claude:
      return ClaudePromptEngineerAdapter(
        command: agentConfig.command,
        model: agentConfig.model,
        timeoutMs: agentConfig.timeoutMs,
        promptProfile: agentConfig.promptProfile.rawValue,
        draftingPreset: agentConfig.draftingPreset.rawValue,
        reasoningEffort: agentConfig.reasoningEffort.rawValue,
        extraArgs: agentConfig.args
      )
    }
  }

  private func makeSidebarChatAdapter() -> AgentSidebarChatAdapting? {
    if let existing = draftingSidebarChatAdapter {
      return existing
    }
    if agentAdapter == nil {
      agentAdapter = makeAgentAdapter()
    }
    if let existing = agentAdapter as? AgentSidebarChatAdapting {
      draftingSidebarChatAdapter = existing
      return existing
    }

    // Preserve strict exec behavior for Improve Prompt while keeping Codex
    // sidebar chat actionable through the app-server route.
    guard agentConfig.command == "codex",
          agentConfig.backend == .exec,
          agentConfig.backend != .claude
    else {
      return nil
    }
    let envOverrides = agentConfig.providerBackend == .litellm ? liteLLMEnvironmentOverrides() : [:]
    let routeLabel = agentConfig.providerBackend == .litellm
      ? "codex app-server (litellm)"
      : "codex app-server (direct)"
    guard let chatAdapter = makeCodexAppServerAdapter(
      timeoutMs: Self.codexAdaptivePrimaryTimeoutMs(configuredTimeoutMs: agentConfig.timeoutMs),
      environmentOverrides: envOverrides,
      routeLabel: routeLabel
    ) as? AgentSidebarChatAdapting else {
      return nil
    }
    draftingSidebarChatAdapter = chatAdapter
    appendDraftingChatTranscript("system: backend is forced to exec; using codex app-server for sidebar chat")
    return chatAdapter
  }

  private func makeCodexAppServerAdapter(
    timeoutMs: Int,
    environmentOverrides: [String: String],
    routeLabel: String
  ) -> AgentAdapting {
    CodexAppServerPromptEngineerAdapter(
      command: agentConfig.command,
      model: agentConfig.model,
      timeoutMs: timeoutMs,
      webSearch: agentConfig.webSearch.rawValue,
      promptProfile: agentConfig.promptProfile.rawValue,
      draftingPreset: agentConfig.draftingPreset.rawValue,
      reasoningEffort: agentConfig.reasoningEffort.rawValue,
      reasoningSummary: agentConfig.reasoningSummary.rawValue,
      extraArgs: agentConfig.args,
      environmentOverrides: environmentOverrides,
      routeLabel: routeLabel
    )
  }

  private func makeCodexExecAdapter(
    timeoutMs: Int,
    environmentOverrides: [String: String],
    routeLabel: String
  ) -> AgentAdapting {
    CodexPromptEngineerAdapter(
      command: agentConfig.command,
      model: agentConfig.model,
      timeoutMs: timeoutMs,
      webSearch: agentConfig.webSearch.rawValue,
      promptProfile: agentConfig.promptProfile.rawValue,
      draftingPreset: agentConfig.draftingPreset.rawValue,
      reasoningEffort: agentConfig.reasoningEffort.rawValue,
      reasoningSummary: agentConfig.reasoningSummary.rawValue,
      extraArgs: agentConfig.args,
      environmentOverrides: environmentOverrides,
      routeLabel: routeLabel
    )
  }

  nonisolated static func codexAdaptiveTimeoutBudget(configuredTimeoutMs: Int) -> (primaryMs: Int, fallbackMs: Int) {
    let configured = max(2_000, configuredTimeoutMs)
    let maxPrimary = max(1_000, configured - 1_000)
    let desiredPrimary = max(2_000, min(6_000, configured / 5))
    let primary = min(maxPrimary, desiredPrimary)
    let fallback = max(1_000, configured - primary)
    return (primaryMs: primary, fallbackMs: fallback)
  }

  nonisolated static func codexAdaptivePrimaryTimeoutMs(configuredTimeoutMs: Int) -> Int {
    codexAdaptiveTimeoutBudget(configuredTimeoutMs: configuredTimeoutMs).primaryMs
  }

  private func makeCodexAdaptiveDraftingAdapter(
    preferredBackend: TurboDraftConfig.Agent.Backend
  ) -> AgentAdapting {
    let direct = makeCodexAdaptiveProviderAdapter(
      preferredBackend: preferredBackend,
      environmentOverrides: [:],
      providerLabel: "direct"
    )
    guard agentConfig.providerBackend == .litellm else {
      return direct
    }
    let liteLLM = makeCodexAdaptiveProviderAdapter(
      preferredBackend: preferredBackend,
      environmentOverrides: liteLLMEnvironmentOverrides(),
      providerLabel: "litellm"
    )
    return FallbackPromptEngineerAdapter(
      primary: direct,
      fallback: liteLLM,
      primaryLabel: "codex direct",
      fallbackLabel: "codex litellm",
      shouldFallback: { error in
        Self.shouldFallbackBetweenCodexRoutes(error)
      }
    )
  }

  private func makeCodexAdaptiveProviderAdapter(
    preferredBackend: TurboDraftConfig.Agent.Backend,
    environmentOverrides: [String: String],
    providerLabel: String
  ) -> AgentAdapting {
    let timeoutBudget = Self.codexAdaptiveTimeoutBudget(configuredTimeoutMs: agentConfig.timeoutMs)
    switch preferredBackend {
    case .exec:
      let primary = makeCodexExecAdapter(
        timeoutMs: timeoutBudget.primaryMs,
        environmentOverrides: environmentOverrides,
        routeLabel: "codex exec (\(providerLabel))"
      )
      let fallback = makeCodexAppServerAdapter(
        timeoutMs: timeoutBudget.fallbackMs,
        environmentOverrides: environmentOverrides,
        routeLabel: "codex app-server (\(providerLabel))"
      )
      return FallbackPromptEngineerAdapter(
        primary: primary,
        fallback: fallback,
        primaryLabel: "codex exec (\(providerLabel))",
        fallbackLabel: "codex app-server (\(providerLabel))",
        shouldFallback: { error in
          Self.shouldFallbackBetweenCodexRoutes(error)
        }
      )
    case .appServer:
      let primary = makeCodexAppServerAdapter(
        timeoutMs: timeoutBudget.primaryMs,
        environmentOverrides: environmentOverrides,
        routeLabel: "codex app-server (\(providerLabel))"
      )
      let fallback = makeCodexExecAdapter(
        timeoutMs: timeoutBudget.fallbackMs,
        environmentOverrides: environmentOverrides,
        routeLabel: "codex exec (\(providerLabel))"
      )
      return FallbackPromptEngineerAdapter(
        primary: primary,
        fallback: fallback,
        primaryLabel: "codex app-server (\(providerLabel))",
        fallbackLabel: "codex exec (\(providerLabel))",
        shouldFallback: { error in
          Self.shouldFallbackBetweenCodexRoutes(error)
        }
      )
    case .claude:
      return makeCodexAppServerAdapter(
        timeoutMs: agentConfig.timeoutMs,
        environmentOverrides: environmentOverrides,
        routeLabel: "codex app-server (\(providerLabel))"
      )
    }
  }

  nonisolated private static func shouldFallbackBetweenCodexRoutes(_ error: Error) -> Bool {
    switch error {
    case is CancellationError:
      return false
    case let err as CodexPromptEngineerError:
      switch err {
      case .invalidOutput, .outputTooLarge:
        return false
      case .commandNotFound, .spawnFailed, .timedOut, .nonZeroExit, .missingOutputFile:
        return true
      }
    case let err as CodexAppServerPromptEngineerError:
      switch err {
      case .invalidOutput, .outputTooLarge:
        return false
      case .commandNotFound, .spawnFailed, .writeFailed, .timedOut, .serverClosed, .protocolError, .nonZeroExit, .missingAgentMessage:
        return true
      }
    case let err as FallbackPromptEngineerError:
      switch err {
      case .chatNotSupported:
        return true
      case .primaryAndFallbackFailed:
        return false
      }
    default:
      return true
    }
  }

  private func liteLLMEnvironmentOverrides() -> [String: String] {
    guard agentConfig.providerBackend == .litellm else { return [:] }
    let env = ProcessInfo.processInfo.environment
    let baseURL = env["TURBODRAFT_LITELLM_BASE_URL"]
      ?? env["LITELLM_BASE_URL"]
      ?? "http://127.0.0.1:4000"
    var out: [String: String] = [
      "OPENAI_BASE_URL": baseURL,
      "TURBODRAFT_PROVIDER_BACKEND": "litellm",
    ]
    if let key = env["TURBODRAFT_LITELLM_API_KEY"] ?? env["LITELLM_API_KEY"], !key.isEmpty {
      out["OPENAI_API_KEY"] = key
    }
    return out
  }
}

#if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
extension EditorViewController: NSSearchFieldDelegate, NSTextFieldDelegate {
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      if !findContainer.isHidden {
        hideFind()
        return true
      }
    }
    return false
  }
}

extension EditorViewController: NSTextViewDelegate {
  override func cancelOperation(_ sender: Any?) {
    if !findContainer.isHidden {
      hideFind()
      return
    }
    if draftingSidebarVisible {
      setDraftingSidebarVisible(false)
      return
    }
    super.cancelOperation(sender)
  }

  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if textView === draftingChatInput {
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        return sendDraftingChatMessage()
      }
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        guard draftingSidebarVisible else { return false }
        setDraftingSidebarVisible(false)
        return true
      }
      return false
    }

    if textView === queueEditor {
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        guard draftingSidebarVisible else { return false }
        setDraftingSidebarVisible(false)
        return true
      }
      return false
    }

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

extension EditorViewController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int {
    guard tableView === queueTableView else { return 0 }
    return queueItems.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard tableView === queueTableView, row >= 0, row < queueItems.count else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("QueuePromptCell")
    let cellView: NSTableCellView
    if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
      cellView = existing
    } else {
      let textField = NSTextField(labelWithString: "")
      textField.translatesAutoresizingMaskIntoConstraints = false
      textField.lineBreakMode = .byTruncatingTail
      textField.maximumNumberOfLines = 1
      let created = NSTableCellView()
      created.identifier = identifier
      created.textField = textField
      created.addSubview(textField)
      NSLayoutConstraint.activate([
        textField.leadingAnchor.constraint(equalTo: created.leadingAnchor, constant: 6),
        textField.trailingAnchor.constraint(equalTo: created.trailingAnchor, constant: -6),
        textField.centerYAnchor.constraint(equalTo: created.centerYAnchor),
      ])
      cellView = created
    }
    cellView.textField?.stringValue = queuePreviewText(for: queueItems[row])
    cellView.textField?.textColor = colorTheme.foreground
    return cellView
  }
}

#if !TURBODRAFT_USE_CODEEDIT_TEXTVIEW
final class SidebarComposerTextView: NSTextView {
  var onSubmit: (() -> Void)?
  var onCancel: (() -> Void)?
  var onImageDrop: (([NSImage]) -> Void)?
  var onFileDrop: (([URL]) -> Void)?
  var onTextChanged: (() -> Void)?

  private static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "webp", "heic",
  ]

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    commonInit()
  }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
    commonInit()
  }

  private func commonInit() {
    registerForDraggedTypes([.fileURL])
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isAutomaticSpellingCorrectionEnabled = false
    isContinuousSpellCheckingEnabled = false
    isAutomaticLinkDetectionEnabled = false
    smartInsertDeleteEnabled = false
    importsGraphics = false
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    commonInit()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let chars = event.charactersIgnoringModifiers ?? ""
    if mods == .command, chars == "v", handlePaste() {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let normalizedMods = mods.subtracting([.numericPad])
    let chars = event.charactersIgnoringModifiers ?? ""

    if normalizedMods == .control, chars == "v", handlePaste() {
      return
    }
    if normalizedMods.isEmpty, event.keyCode == 53 {
      onCancel?()
      return
    }
    if (event.keyCode == 36 || event.keyCode == 76),
       (normalizedMods.isEmpty || normalizedMods == .command)
    {
      onSubmit?()
      return
    }
    super.keyDown(with: event)
  }

  override func paste(_ sender: Any?) {
    if handlePaste() { return }
    super.paste(sender)
  }

  override func didChangeText() {
    super.didChangeText()
    onTextChanged?()
  }

  private func handlePaste() -> Bool {
    let pb = NSPasteboard.general
    var handled = false

    for type in [NSPasteboard.PasteboardType.tiff, .png] {
      if let data = pb.data(forType: type), let image = NSImage(data: data) {
        onImageDrop?([image])
        handled = true
      }
    }

    if let urls = pb.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL], !urls.isEmpty {
      let imageURLs = urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
      let fileURLs = urls.filter { !Self.imageExtensions.contains($0.pathExtension.lowercased()) }
      if !imageURLs.isEmpty {
        let images = imageURLs.compactMap { NSImage(contentsOf: $0) }
        if !images.isEmpty {
          onImageDrop?(images)
          handled = true
        }
      }
      if !fileURLs.isEmpty {
        onFileDrop?(fileURLs)
        handled = true
      }
    }

    return handled
  }

  private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
    guard let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] else { return [] }
    return urls
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    if !fileURLs(from: sender).isEmpty { return .copy }
    return super.draggingEntered(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    if !fileURLs(from: sender).isEmpty { return .copy }
    return super.draggingUpdated(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls = fileURLs(from: sender)
    guard !urls.isEmpty else { return super.performDragOperation(sender) }
    let imageURLs = urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
    let fileURLs = urls.filter { !Self.imageExtensions.contains($0.pathExtension.lowercased()) }
    var handled = false
    if !imageURLs.isEmpty {
      let images = imageURLs.compactMap { NSImage(contentsOf: $0) }
      if !images.isEmpty {
        onImageDrop?(images)
        handled = true
      }
    }
    if !fileURLs.isEmpty {
      onFileDrop?(fileURLs)
      handled = true
    }
    return handled || super.performDragOperation(sender)
  }
}

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
  var onOpenDraftingChat: (() -> Void)?
  var onInsertDraftingAnnotation: (() -> Void)?
  var onCloseFind: (() -> Bool)?
  var onCloseDraftingSidebar: (() -> Bool)?
  var onEscape: (() -> Bool)?

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
    if mods == [.command, .shift], chars.lowercased() == "a" {
      onInsertDraftingAnnotation?()
      return true
    }
    if mods == [.command, .option], chars.lowercased() == "r" {
      onOpenDraftingChat?()
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
    if mods.isEmpty, event.keyCode == 53 {  // Esc
      if onCloseFind?() == true { return }
      if onCloseDraftingSidebar?() == true { return }
      if onEscape?() == true { return }
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

  func _testingMessage() -> String { label.stringValue }

  @objc private func tapped() { onRestore?() }
}

final class AppearanceTrackingView: NSView {
  var onAppearanceChange: (() -> Void)?

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onAppearanceChange?()
  }
}

final class SidebarResizeHandleView: NSView {
  var onDragBegan: ((CGFloat) -> Void)?
  var onDragChanged: ((CGFloat) -> Void)?
  var onDragEnded: (() -> Void)?

  override var acceptsFirstResponder: Bool { false }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  override func mouseDown(with event: NSEvent) {
    onDragBegan?(event.locationInWindow.x)
  }

  override func mouseDragged(with event: NSEvent) {
    onDragChanged?(event.locationInWindow.x)
  }

  override func mouseUp(with event: NSEvent) {
    onDragChanged?(event.locationInWindow.x)
    onDragEnded?()
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
  func _testingExternalQueueAttachment() -> ExternalQueueAttachment? { externalQueueAttachment }
  func _testingExternalSessionQueuesConfig() -> TurboDraftConfig.ExternalSessionQueues { externalSessionQueuesConfig }
  func _testingExternalSessionContextAttachment() -> ExternalSessionContextAttachment? { externalSessionContextAttachment }
  func _testingExternalSessionContextSnapshot() -> ExternalSessionContextSnapshot? { externalSessionContextSnapshot }
  func _testingPromptForDraftingAgent(from text: String) -> String { promptAndImagesForAgent(from: text).prompt }
  func _testingOpenQueuePanel() { openQueuePanel() }
  func _testingIsQueueSidebarVisible() -> Bool {
    draftingSidebarVisible && !draftingSidebar.isHidden && draftingSidebarMode == .queue
  }
  func _testingQueueItemCount() -> Int { queueItems.count }
  func _testingQueueStatusText() -> String { queueStatusLabel.stringValue }
  func _testingQueueSelectedPrompt() -> String? {
    selectedQueueIndex().map { queueItems[$0].prompt }
  }
  func _testingQueueSelectedRow() -> Int { queueTableView.selectedRow }
  func _testingQueueEditorText() -> String { queueEditor.string }
  func _testingSetQueueEditorText(_ text: String) {
    queueEditor.string = text
    handleQueueEditorTextDidChange()
  }
  func _testingQueueSelectRow(_ row: Int) {
    guard row >= 0, row < queueItems.count else {
      queueTableView.deselectAll(nil)
      queueSelectionDidChange(nil)
      return
    }
    queueTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    queueSelectionDidChange(nil)
  }
  func _testingQueueNewItem() { queueNewAction(nil) }
  func _testingDeleteQueueSelection() { queueDeleteAction(nil) }
  func _testingSaveQueue() { queueSaveAction(nil) }
  func _testingReloadQueue() { queueReloadAction(nil) }
  func _testingSetSelection(_ range: NSRange) {
    textView.setSelectedRange(range)
  }
  func _testingSelection() -> NSRange { textView.selectedRange() }
  func _testingSetExternalSessionQueues(_ settings: TurboDraftConfig.ExternalSessionQueues) {
    setExternalSessionQueues(settings)
  }

  func _testingShowFind(replace: Bool) { showFind(replace: replace) }
  func _testingHideFind() { hideFind() }
  func _testingOpenDraftingChat() { openDraftingChatFromMenu() }
  func _testingCloseDraftingSidebar() { setDraftingSidebarVisible(false) }
  func _testingIsDraftingSidebarVisible() -> Bool { draftingSidebarVisible && !draftingSidebar.isHidden }
  func _testingDraftingChatInputHeight() -> CGFloat { draftingChatInputHeightConstraint?.constant ?? 0 }
  func _testingSetDraftingChatInput(_ text: String) { setDraftingChatInputText(text) }
  func _testingDraftingChatInput() -> String { draftingChatInputText() }
  func _testingDraftingChatTranscript() -> String { draftingChatTranscript.string }
  func _testingSetDraftingAnnotationType(_ rawType: String) {
    if let type = DraftingAnnotationType(rawValue: rawType.lowercased()) {
      setSelectedDraftingAnnotationType(type)
    }
  }
  func _testingDraftingContextText() -> String { draftingContextView.string }
  func _testingDraftingDiffText() -> String { draftingDiffView.string }
  func _testingHasDraftingSuggestedDraft() -> Bool { draftingSidebarSuggestedDraft != nil }
  func _testingIsDraftingChatRunning() -> Bool { draftingChatRunning }
  func _testingIsAgentRunning() -> Bool { agentRunning }
  func _testingRunAgent() { runAgent() }
  func _testingBannerMessage() -> String { banner._testingMessage() }
  func _testingIsAgentButtonEnabled() -> Bool { agentButton.isEnabled }
  func _testingIsChatButtonHidden() -> Bool { chatButton.isHidden }
  func _testingChatButtonFrameInView() -> NSRect {
    view.layoutSubtreeIfNeeded()
    return chatButton.superview?.convert(chatButton.frame, to: view) ?? .zero
  }
  func _testingDraftingSidebarFrameInView() -> NSRect {
    view.layoutSubtreeIfNeeded()
    return draftingSidebar.superview?.convert(draftingSidebar.frame, to: view) ?? .zero
  }
  func _testingApplyDraftingSuggestion() { draftingChatApplySuggestionAction(nil) }
  func _testingToggleDraftingContextPanel() { draftingChatToggleContextAction(nil) }
  func _testingToggleDraftingDiffPanel() { draftingChatToggleDiffAction(nil) }
  func _testingIsDraftingContextVisible() -> Bool { draftingContextVisible && !draftingContextScroll.isHidden }
  func _testingIsDraftingDiffVisible() -> Bool { draftingDiffVisible && !draftingDiffScroll.isHidden }
  func _testingIsQueueButtonHidden() -> Bool { queueButton.isHidden }
  func _testingChatButtonTitle() -> String { chatButton.title }
  func _testingQueueButtonTitle() -> String { queueButton.title }
  func _testingSetAgentAdapter(_ adapter: AgentAdapting?) {
    agentAdapter = adapter
    draftingSidebarChatAdapter = nil
  }
  @discardableResult
  func _testingSubmitDraftingChatNote(runImprove: Bool = false) -> Bool {
    submitDraftingChatNote(runImprove: runImprove, annotationType: selectedDraftingAnnotationType())
  }
  @discardableResult
  func _testingSendDraftingChatMessage() -> Bool {
    sendDraftingChatMessage()
  }
  @discardableResult
  func _testingSidebarDoCommand(_ selector: Selector) -> Bool {
    self.textView(draftingChatInput, doCommandBy: selector)
  }
  @discardableResult
  func _testingQueueEditorDoCommand(_ selector: Selector) -> Bool {
    self.textView(queueEditor, doCommandBy: selector)
  }
  func _testingQueueFocusEditor() {
    view.window?.makeFirstResponder(queueEditor)
  }
  func _testingClickQueueNewButton() {
    queueNewButton.performClick(nil)
  }
  func _testingQueueDraftingSidebarFileAttachment(url: URL) {
    enqueueDraftingSidebarFiles([url])
  }
  func _testingQueueDraftingSidebarImageAttachment(id: String, url: URL) {
    attachedImages[id] = url
    queueDraftingSidebarAttachment(ref: "[image-\(id)]", displayName: "image-\(id).png")
  }
  func _testingDraftingSidebarPendingAttachmentRefs() -> [String] {
    draftingSidebarPendingAttachmentRefs
  }
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

  func _testingInsertDraftingAnnotation(type: String = "note") {
    insertDraftingAnnotation(type: type)
  }

  func _testingAppendDraftingChatNote(_ note: String, type: String = "question") -> Bool {
    appendDraftingChatAnnotation(note: note, type: type)
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
