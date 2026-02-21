import Foundation

public struct TurboDraftConfig: Codable, Sendable, Equatable {
  private static let allowedAgentCommands: Set<String> = ["codex", "claude"]

  public enum EditorMode: String, Codable, Sendable, Equatable {
    case reliable
    case ultraFast = "ultra_fast"
  }

  public enum ThemeMode: String, Codable, Sendable, Equatable {
    case system
    case light
    case dark
  }

  public struct Agent: Codable, Sendable, Equatable {
    public enum Backend: String, Codable, Sendable, Equatable, CaseIterable {
      case exec
      case appServer = "app_server"
      case claude
    }

    public enum ReasoningEffort: String, Codable, Sendable, Equatable, CaseIterable {
      case minimal
      case low
      case medium
      case high
      case xhigh
    }

    public enum ReasoningSummary: String, Codable, Sendable, Equatable, CaseIterable {
      case auto
      case concise
      case detailed
      case none
    }

    public enum WebSearchMode: String, Codable, Sendable, Equatable, CaseIterable {
      case disabled
      case cached
      case live
    }

    public enum PromptProfile: String, Codable, Sendable, Equatable, CaseIterable {
      case core
      case largeOpt = "large_opt"
      case extended
    }

    public var enabled: Bool
    public var backend: Backend
    public var command: String
    public var model: String
    public var timeoutMs: Int
    public var webSearch: WebSearchMode
    public var promptProfile: PromptProfile
    public var reasoningEffort: ReasoningEffort
    public var reasoningSummary: ReasoningSummary
    public var args: [String]

    public init(
      enabled: Bool = false,
      backend: Backend = .exec,
      command: String = "codex",
      model: String = "gpt-5.3-codex-spark",
      timeoutMs: Int = 60_000,
      webSearch: WebSearchMode = .cached,
      promptProfile: PromptProfile = .largeOpt,
      reasoningEffort: ReasoningEffort = .low,
      reasoningSummary: ReasoningSummary = .auto,
      args: [String] = []
    ) {
      self.enabled = enabled
      self.backend = backend
      self.command = command
      self.model = model
      self.timeoutMs = timeoutMs
      self.webSearch = webSearch
      self.promptProfile = promptProfile
      self.reasoningEffort = reasoningEffort
      self.reasoningSummary = reasoningSummary
      self.args = args
    }

    private enum CodingKeys: String, CodingKey {
      case enabled
      case backend
      case command
      case model
      case timeoutMs
      case webSearch
      case promptProfile
      case reasoningEffort
      case reasoningSummary
      case args
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
      self.backend = try c.decodeIfPresent(Backend.self, forKey: .backend) ?? .exec
      self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? "codex"
      self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? "gpt-5.3-codex-spark"
      self.timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 60_000
      self.webSearch = try c.decodeIfPresent(WebSearchMode.self, forKey: .webSearch) ?? .cached
      self.promptProfile = try c.decodeIfPresent(PromptProfile.self, forKey: .promptProfile) ?? .largeOpt
      self.reasoningEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort) ?? .low
      self.reasoningSummary = try c.decodeIfPresent(ReasoningSummary.self, forKey: .reasoningSummary) ?? .auto
      self.args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(enabled, forKey: .enabled)
      try c.encode(backend, forKey: .backend)
      try c.encode(command, forKey: .command)
      try c.encode(model, forKey: .model)
      try c.encode(timeoutMs, forKey: .timeoutMs)
      try c.encode(webSearch, forKey: .webSearch)
      try c.encode(promptProfile, forKey: .promptProfile)
      try c.encode(reasoningEffort, forKey: .reasoningEffort)
      try c.encode(reasoningSummary, forKey: .reasoningSummary)
      try c.encode(args, forKey: .args)
    }
  }

  public var socketPath: String
  public var autosaveDebounceMs: Int
  public var autosaveMaxFlushMs: Int
  public var agent: Agent
  public var theme: ThemeMode
  public var editorMode: EditorMode
  public var colorTheme: String
  public var fontSize: Int
  public var fontFamily: String

  public init(
    socketPath: String = TurboDraftPaths.defaultSocketPath(),
    autosaveDebounceMs: Int = 50,
    autosaveMaxFlushMs: Int = 250,
    agent: Agent = Agent(),
    theme: ThemeMode = .system,
    editorMode: EditorMode = .reliable,
    colorTheme: String = "turbodraft-dark",
    fontSize: Int = 13,
    fontFamily: String = "system"
  ) {
    self.socketPath = socketPath
    self.autosaveDebounceMs = autosaveDebounceMs
    self.autosaveMaxFlushMs = autosaveMaxFlushMs
    self.agent = agent
    self.theme = theme
    self.editorMode = editorMode
    self.colorTheme = colorTheme
    self.fontSize = fontSize
    self.fontFamily = fontFamily
  }

  private enum CodingKeys: String, CodingKey {
    case socketPath
    case autosaveDebounceMs
    case autosaveMaxFlushMs
    case agent
    case theme
    case editorMode
    case colorTheme
    case fontSize
    case fontFamily
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.socketPath = try c.decodeIfPresent(String.self, forKey: .socketPath) ?? TurboDraftPaths.defaultSocketPath()
    self.autosaveDebounceMs = try c.decodeIfPresent(Int.self, forKey: .autosaveDebounceMs) ?? 50
    self.autosaveMaxFlushMs = try c.decodeIfPresent(Int.self, forKey: .autosaveMaxFlushMs) ?? 250
    self.agent = try c.decodeIfPresent(Agent.self, forKey: .agent) ?? Agent()
    self.theme = try c.decodeIfPresent(ThemeMode.self, forKey: .theme) ?? .system
    self.editorMode = try c.decodeIfPresent(EditorMode.self, forKey: .editorMode) ?? .reliable
    self.colorTheme = try c.decodeIfPresent(String.self, forKey: .colorTheme) ?? "turbodraft-dark"
    self.fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? 13
    self.fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? "system"
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(socketPath, forKey: .socketPath)
    try c.encode(autosaveDebounceMs, forKey: .autosaveDebounceMs)
    try c.encode(autosaveMaxFlushMs, forKey: .autosaveMaxFlushMs)
    try c.encode(agent, forKey: .agent)
    try c.encode(theme, forKey: .theme)
    try c.encode(editorMode, forKey: .editorMode)
    try c.encode(colorTheme, forKey: .colorTheme)
    try c.encode(fontSize, forKey: .fontSize)
    try c.encode(fontFamily, forKey: .fontFamily)
  }

  public static func load() -> TurboDraftConfig {
    let path = resolvedConfigPath()
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
      return TurboDraftConfig()
    }
    let decoded = (try? JSONDecoder().decode(TurboDraftConfig.self, from: data)) ?? TurboDraftConfig()
    return decoded.sanitized()
  }

  public static func resolvedConfigPath() -> String {
    ProcessInfo.processInfo.environment["TURBODRAFT_CONFIG"] ?? TurboDraftPaths.defaultConfigPath()
  }

  public func sanitized() -> TurboDraftConfig {
    var cfg = self
    cfg.autosaveDebounceMs = max(0, cfg.autosaveDebounceMs)
    cfg.autosaveMaxFlushMs = max(0, cfg.autosaveMaxFlushMs)
    if cfg.autosaveMaxFlushMs > 0 {
      cfg.autosaveMaxFlushMs = max(cfg.autosaveMaxFlushMs, cfg.autosaveDebounceMs)
    }
    // Some Codex model variants don't support all reasoning efforts (for example Spark doesn't accept "minimal").
    if cfg.agent.model.contains("spark"), cfg.agent.reasoningEffort == .minimal {
      cfg.agent.reasoningEffort = .low
    }

    let normalizedCommand = cfg.agent.command
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if Self.allowedAgentCommands.contains(normalizedCommand) {
      cfg.agent.command = normalizedCommand
    } else {
      cfg.agent.command = cfg.agent.backend == .claude ? "claude" : "codex"
    }
    switch cfg.agent.backend {
    case .claude:
      cfg.agent.command = "claude"
    case .exec, .appServer:
      cfg.agent.command = "codex"
    }

    return cfg
  }

  public func write(to path: String? = nil) throws {
    let target = path ?? TurboDraftConfig.resolvedConfigPath()
    let url = URL(fileURLWithPath: target)
    let data = try JSONEncoder().encode(self.sanitized())
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic])
  }

  public static func writeDefault(to path: String? = nil) throws {
    try TurboDraftConfig().write(to: path)
  }
}
