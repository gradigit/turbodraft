import AppKit
import TurboDraftConfig

@MainActor
enum SettingsAction {
  case setThemeMode(TurboDraftConfig.ThemeMode)
  case setEditorMode(TurboDraftConfig.EditorMode)
  case setColorTheme(String)
  case setFontSize(Int)
  case setFontFamily(String)
  case setAgentEnabled(Bool)
  case setAgentBackend(TurboDraftConfig.Agent.Backend)
  case setAgentModel(String)
  case setPromptProfile(TurboDraftConfig.Agent.PromptProfile)
  case setDraftingPreset(TurboDraftConfig.Agent.DraftingPreset)
  case setWebSearchMode(TurboDraftConfig.Agent.WebSearchMode)
  case setReasoningEffort(TurboDraftConfig.Agent.ReasoningEffort)
  case setReasoningSummary(TurboDraftConfig.Agent.ReasoningSummary)
  case setExternalQueuesEnabled(Bool)
  case setExternalQueuesAutoReveal(Bool)
  case setChatPanelEnabled(Bool)
  case setAnnotationEnabled(Bool)
}

@MainActor
final class SettingsViewController: NSViewController, NSTextFieldDelegate {
  typealias FontPreset = (title: String, family: String)

  private var config: TurboDraftConfig
  private var colorThemes: [EditorColorTheme]
  private var modelPresets: [String]
  private var fontPresets: [FontPreset]
  private let applyAction: (SettingsAction) -> TurboDraftConfig
  private var isRefreshingControls = false

  private let scrollView = NSScrollView()
  private let contentStack = NSStackView()

  private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let colorThemePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let fontFamilyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let fontSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let editorModePopup = NSPopUpButton(frame: .zero, pullsDown: false)

  private let agentEnabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  private let backendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let modelField = NSTextField(frame: .zero)
  private let promptProfilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let draftingPresetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let webSearchPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let reasoningEffortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let reasoningSummaryPopup = NSPopUpButton(frame: .zero, pullsDown: false)

  private let queuesEnabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  private let queueAutoRevealButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)

  private let chatPanelEnabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  private let annotationEnabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)

  init(
    config: TurboDraftConfig,
    colorThemes: [EditorColorTheme],
    modelPresets: [String],
    fontPresets: [FontPreset],
    applyAction: @escaping (SettingsAction) -> TurboDraftConfig
  ) {
    self.config = config
    self.colorThemes = colorThemes
    self.modelPresets = modelPresets
    self.fontPresets = fontPresets
    self.applyAction = applyAction
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let root = NSView()
    root.translatesAutoresizingMaskIntoConstraints = false

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay

    let contentView = NSView()
    contentView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = contentView

    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 18
    contentStack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(contentStack)

    contentStack.addArrangedSubview(makeAppearanceSection())
    contentStack.addArrangedSubview(makeDraftingSection())
    contentStack.addArrangedSubview(makeQueueSection())
    contentStack.addArrangedSubview(makeAdvancedSection())
    contentStack.addArrangedSubview(makeFooterNote())

    root.addSubview(scrollView)
    view = root

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: root.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

      contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      contentStack.topAnchor.constraint(equalTo: contentView.topAnchor),
      contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      contentStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
    ])

    configureTargets()
    refresh(config: config, colorThemes: colorThemes, modelPresets: modelPresets, fontPresets: fontPresets)
  }

  func refresh(
    config: TurboDraftConfig,
    colorThemes: [EditorColorTheme],
    modelPresets: [String],
    fontPresets: [FontPreset]
  ) {
    self.config = config
    self.colorThemes = colorThemes
    self.modelPresets = modelPresets
    self.fontPresets = fontPresets
    syncControlsFromConfig()
  }

  private func configureTargets() {
    [themePopup, colorThemePopup, fontFamilyPopup, fontSizePopup, editorModePopup,
     backendPopup, promptProfilePopup, draftingPresetPopup, webSearchPopup,
     reasoningEffortPopup, reasoningSummaryPopup].forEach {
      $0.target = self
    }

    themePopup.action = #selector(themeChanged(_:))
    colorThemePopup.action = #selector(colorThemeChanged(_:))
    fontFamilyPopup.action = #selector(fontFamilyChanged(_:))
    fontSizePopup.action = #selector(fontSizeChanged(_:))
    editorModePopup.action = #selector(editorModeChanged(_:))
    backendPopup.action = #selector(backendChanged(_:))
    promptProfilePopup.action = #selector(promptProfileChanged(_:))
    draftingPresetPopup.action = #selector(draftingPresetChanged(_:))
    webSearchPopup.action = #selector(webSearchChanged(_:))
    reasoningEffortPopup.action = #selector(reasoningEffortChanged(_:))
    reasoningSummaryPopup.action = #selector(reasoningSummaryChanged(_:))

    [agentEnabledButton, queuesEnabledButton, queueAutoRevealButton,
     chatPanelEnabledButton, annotationEnabledButton].forEach {
      $0.target = self
    }

    agentEnabledButton.action = #selector(agentEnabledChanged(_:))
    queuesEnabledButton.action = #selector(queuesEnabledChanged(_:))
    queueAutoRevealButton.action = #selector(queueAutoRevealChanged(_:))
    chatPanelEnabledButton.action = #selector(chatPanelEnabledChanged(_:))
    annotationEnabledButton.action = #selector(annotationEnabledChanged(_:))

    modelField.delegate = self
    modelField.placeholderString = "gpt-5.3-codex-spark"
    modelField.lineBreakMode = .byTruncatingTail
  }

  private func syncControlsFromConfig() {
    isRefreshingControls = true
    defer {
      isRefreshingControls = false
      updateDependentControlState()
    }

    syncThemePopup()
    syncColorThemePopup()
    syncFontFamilyPopup()
    syncFontSizePopup()
    syncEditorModePopup()
    syncBackendPopup()
    syncPromptProfilePopup()
    syncDraftingPresetPopup()
    syncWebSearchPopup()
    syncReasoningEffortPopup()
    syncReasoningSummaryPopup()

    agentEnabledButton.state = config.agent.enabled ? .on : .off
    modelField.stringValue = config.agent.model
    queuesEnabledButton.state = config.externalSessionQueues.enabled ? .on : .off
    queueAutoRevealButton.state = config.externalSessionQueues.autoRevealOnAttach ? .on : .off
    chatPanelEnabledButton.state = config.agent.chatPanelEnabled ? .on : .off
    annotationEnabledButton.state = config.agent.annotationEnabled ? .on : .off
  }

  private func updateDependentControlState() {
    queueAutoRevealButton.isEnabled = queuesEnabledButton.state == .on
  }

  private func apply(_ action: SettingsAction) {
    guard !isRefreshingControls else { return }
    let newConfig = applyAction(action)
    refresh(config: newConfig, colorThemes: colorThemes, modelPresets: modelPresets, fontPresets: fontPresets)
  }

  private func makeAppearanceSection() -> NSView {
    makeSection(
      title: "Appearance",
      description: "Common editor appearance settings.",
      rows: [
        ("Theme", themePopup),
        ("Color Theme", colorThemePopup),
        ("Font Family", fontFamilyPopup),
        ("Font Size", fontSizePopup),
        ("Editor Mode", editorModePopup),
      ]
    )
  }

  private func makeDraftingSection() -> NSView {
    makeSection(
      title: "Drafting",
      description: "Common drafting_agent configuration.",
      rows: [
        ("Enable Drafting Agent", agentEnabledButton),
        ("Backend", backendPopup),
        ("Model", modelField),
        ("Drafting Preset", draftingPresetPopup),
        ("Prompt Profile", promptProfilePopup),
        ("Web Search", webSearchPopup),
        ("Reasoning Effort", reasoningEffortPopup),
        ("Reasoning Summary", reasoningSummaryPopup),
      ]
    )
  }

  private func makeQueueSection() -> NSView {
    makeSection(
      title: "External Queues",
      description: "Controls the optional attached queue panel for external session queues.",
      rows: [
        ("Enable External Queues", queuesEnabledButton),
        ("Auto Reveal Queue On Attach", queueAutoRevealButton),
      ]
    )
  }

  private func makeAdvancedSection() -> NSView {
    makeSection(
      title: "Advanced Drafting",
      description: "Visible drafting surfaces that are still useful to toggle without editing JSON.",
      rows: [
        ("Enable Chat Refine Panel", chatPanelEnabledButton),
        ("Enable Drafting Annotations", annotationEnabledButton),
      ]
    )
  }

  private func makeFooterNote() -> NSView {
    let label = NSTextField(wrappingLabelWithString: "Advanced transport, plugin, and experimental settings remain in config.json for now.")
    label.textColor = .secondaryLabelColor
    label.font = NSFont.systemFont(ofSize: 11)
    label.maximumNumberOfLines = 0
    return label
  }

  private func makeSection(title: String, description: String, rows: [(String, NSView)]) -> NSView {
    let container = NSStackView()
    container.orientation = .vertical
    container.alignment = .leading
    container.spacing = 8
    container.translatesAutoresizingMaskIntoConstraints = false

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)

    let descLabel = NSTextField(wrappingLabelWithString: description)
    descLabel.font = NSFont.systemFont(ofSize: 11)
    descLabel.textColor = .secondaryLabelColor
    descLabel.maximumNumberOfLines = 0

    let gridRows = rows.map { row -> [NSView] in
      let label = NSTextField(labelWithString: row.0)
      label.font = NSFont.systemFont(ofSize: 12)
      label.alignment = .right
      row.1.translatesAutoresizingMaskIntoConstraints = false
      if let textField = row.1 as? NSTextField {
        textField.controlSize = .regular
      }
      if let popup = row.1 as? NSPopUpButton {
        popup.controlSize = .regular
      }
      return [label, row.1]
    }
    let grid = NSGridView(views: gridRows)
    grid.rowSpacing = 8
    grid.columnSpacing = 12
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 1).xPlacement = .fill
    grid.column(at: 1).width = 280

    container.addArrangedSubview(titleLabel)
    container.addArrangedSubview(descLabel)
    container.addArrangedSubview(grid)
    container.setCustomSpacing(4, after: titleLabel)

    return container
  }

  private func syncThemePopup() {
    let items: [(String, TurboDraftConfig.ThemeMode)] = [
      ("System", .system),
      ("Light", .light),
      ("Dark", .dark),
    ]
    configurePopup(themePopup, items: items, selectedRawValue: config.theme.rawValue)
  }

  private func syncEditorModePopup() {
    let items: [(String, TurboDraftConfig.EditorMode)] = [
      ("Reliable", .reliable),
      ("Ultra Fast", .ultraFast),
    ]
    configurePopup(editorModePopup, items: items, selectedRawValue: config.editorMode.rawValue)
  }

  private func syncColorThemePopup() {
    colorThemePopup.removeAllItems()
    for theme in colorThemes {
      colorThemePopup.addItem(withTitle: theme.displayName)
      colorThemePopup.lastItem?.representedObject = theme.id
    }
    selectPopup(colorThemePopup, rawValue: config.colorTheme)
  }

  private func syncFontFamilyPopup() {
    fontFamilyPopup.removeAllItems()
    for preset in fontPresets {
      fontFamilyPopup.addItem(withTitle: preset.title)
      fontFamilyPopup.lastItem?.representedObject = preset.family
    }
    selectPopup(fontFamilyPopup, rawValue: config.fontFamily)
  }

  private func syncFontSizePopup() {
    let sizes = [11, 12, 13, 14, 15, 16, 18, 20]
    fontSizePopup.removeAllItems()
    for size in sizes {
      fontSizePopup.addItem(withTitle: "\(size)")
      fontSizePopup.lastItem?.representedObject = size
    }
    if let index = fontSizePopup.itemArray.firstIndex(where: { ($0.representedObject as? Int) == config.fontSize }) {
      fontSizePopup.selectItem(at: index)
    } else if let fallback = sizes.firstIndex(of: 15) {
      fontSizePopup.selectItem(at: fallback)
    }
  }

  private func syncBackendPopup() {
    let items: [(String, TurboDraftConfig.Agent.Backend)] = [
      ("Exec (Spawn)", .exec),
      ("App Server (Warm)", .appServer),
      ("Claude CLI", .claude),
    ]
    configurePopup(backendPopup, items: items, selectedRawValue: config.agent.backend.rawValue)
  }

  private func syncPromptProfilePopup() {
    let items: [(String, TurboDraftConfig.Agent.PromptProfile)] = [
      ("Core", .core),
      ("Large (Optimized)", .largeOpt),
      ("Extended", .extended),
    ]
    configurePopup(promptProfilePopup, items: items, selectedRawValue: config.agent.promptProfile.rawValue)
  }

  private func syncDraftingPresetPopup() {
    let items: [(String, TurboDraftConfig.Agent.DraftingPreset)] = [
      ("Legacy", .legacy),
      ("Research", .research),
      ("Coding", .coding),
      ("Refactor", .refactor),
      ("Review", .review),
      ("Brainstorm", .brainstorm),
      ("Pivot KR→EN Translate", .pivotKrEnTranslate),
      ("Pivot KR→EN Reason→KO", .pivotKrEnReasonKo),
      ("Pivot KR→EN Optimize→KO", .pivotKrEnOptimizeKo),
    ]
    configurePopup(draftingPresetPopup, items: items, selectedRawValue: config.agent.draftingPreset.rawValue)
  }

  private func syncWebSearchPopup() {
    let items: [(String, TurboDraftConfig.Agent.WebSearchMode)] = [
      ("Disabled", .disabled),
      ("Cached", .cached),
      ("Live", .live),
    ]
    configurePopup(webSearchPopup, items: items, selectedRawValue: config.agent.webSearch.rawValue)
  }

  private func syncReasoningEffortPopup() {
    let items: [(String, TurboDraftConfig.Agent.ReasoningEffort)] = [
      ("Minimal", .minimal),
      ("Low", .low),
      ("Medium", .medium),
      ("High", .high),
      ("XHigh", .xhigh),
    ]
    configurePopup(reasoningEffortPopup, items: items, selectedRawValue: config.agent.reasoningEffort.rawValue)
  }

  private func syncReasoningSummaryPopup() {
    let items: [(String, TurboDraftConfig.Agent.ReasoningSummary)] = [
      ("Auto", .auto),
      ("Concise", .concise),
      ("Detailed", .detailed),
      ("None", .none),
    ]
    configurePopup(reasoningSummaryPopup, items: items, selectedRawValue: config.agent.reasoningSummary.rawValue)
  }

  private func configurePopup<T: RawRepresentable>(
    _ popup: NSPopUpButton,
    items: [(String, T)],
    selectedRawValue: String
  ) where T.RawValue == String {
    popup.removeAllItems()
    for item in items {
      popup.addItem(withTitle: item.0)
      popup.lastItem?.representedObject = item.1.rawValue
    }
    selectPopup(popup, rawValue: selectedRawValue)
  }

  private func selectPopup(_ popup: NSPopUpButton, rawValue: String) {
    if let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == rawValue }) {
      popup.selectItem(at: index)
    } else if popup.numberOfItems > 0 {
      popup.selectItem(at: 0)
    }
  }

  @objc private func themeChanged(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? String,
          let value = TurboDraftConfig.ThemeMode(rawValue: raw) else { return }
    apply(.setThemeMode(value))
  }

  @objc private func colorThemeChanged(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? String else { return }
    apply(.setColorTheme(raw))
  }

  @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? String else { return }
    apply(.setFontFamily(raw))
  }

  @objc private func fontSizeChanged(_ sender: NSPopUpButton) {
    guard let value = sender.selectedItem?.representedObject as? Int else { return }
    apply(.setFontSize(value))
  }

  @objc private func editorModeChanged(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? String,
          let value = TurboDraftConfig.EditorMode(rawValue: raw) else { return }
    apply(.setEditorMode(value))
  }

  @objc private func agentEnabledChanged(_ sender: NSButton) {
    apply(.setAgentEnabled(sender.state == .on))
  }

  @objc private func backendChanged(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? String,
          let value = TurboDraftConfig.Agent.Backend(rawValue: raw) else { return }
    apply(.setAgentBackend(value))
  }

  @objc private func promptProfileChanged(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? String,
          let value = TurboDraftConfig.Agent.PromptProfile(rawValue: raw) else { return }
    apply(.setPromptProfile(value))
  }

  @objc private func draftingPresetChanged(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? String,
          let value = TurboDraftConfig.Agent.DraftingPreset(rawValue: raw) else { return }
    apply(.setDraftingPreset(value))
  }

  @objc private func webSearchChanged(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? String,
          let value = TurboDraftConfig.Agent.WebSearchMode(rawValue: raw) else { return }
    apply(.setWebSearchMode(value))
  }

  @objc private func reasoningEffortChanged(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? String,
          let value = TurboDraftConfig.Agent.ReasoningEffort(rawValue: raw) else { return }
    apply(.setReasoningEffort(value))
  }

  @objc private func reasoningSummaryChanged(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? String,
          let value = TurboDraftConfig.Agent.ReasoningSummary(rawValue: raw) else { return }
    apply(.setReasoningSummary(value))
  }

  @objc private func queuesEnabledChanged(_ sender: NSButton) {
    apply(.setExternalQueuesEnabled(sender.state == .on))
  }

  @objc private func queueAutoRevealChanged(_ sender: NSButton) {
    apply(.setExternalQueuesAutoReveal(sender.state == .on))
  }

  @objc private func chatPanelEnabledChanged(_ sender: NSButton) {
    apply(.setChatPanelEnabled(sender.state == .on))
  }

  @objc private func annotationEnabledChanged(_ sender: NSButton) {
    apply(.setAnnotationEnabled(sender.state == .on))
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    guard !isRefreshingControls else { return }
    guard let field = obj.object as? NSTextField, field === modelField else { return }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      modelField.stringValue = config.agent.model
      return
    }
    apply(.setAgentModel(value))
  }

  func _testingSelectedThemeRawValue() -> String? {
    themePopup.selectedItem?.representedObject as? String
  }

  func _testingSelectedDraftingPresetRawValue() -> String? {
    draftingPresetPopup.selectedItem?.representedObject as? String
  }

  func _testingQueuesEnabledState() -> NSControl.StateValue {
    queuesEnabledButton.state
  }

  func _testingQueueAutoRevealEnabled() -> Bool {
    queueAutoRevealButton.isEnabled
  }

  func _testingModelText() -> String {
    modelField.stringValue
  }

  func _testingSetModelTextAndCommit(_ text: String) {
    modelField.stringValue = text
    controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: modelField))
  }
}
