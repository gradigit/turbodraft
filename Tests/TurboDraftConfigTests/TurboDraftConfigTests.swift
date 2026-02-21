import XCTest

@testable import TurboDraftConfig

final class TurboDraftConfigTests: XCTestCase {
  func testDecodeDefaultsThemeToSystem() throws {
    let cfg = try JSONDecoder().decode(TurboDraftConfig.self, from: Data("{}".utf8))
    XCTAssertEqual(cfg.theme, .system)
    XCTAssertEqual(cfg.editorMode, .reliable)
    XCTAssertEqual(cfg.autosaveDebounceMs, 50)
  }

  func testDecodeDefaultsAgentSettings() throws {
    let cfg = try JSONDecoder().decode(TurboDraftConfig.self, from: Data("{}".utf8))
    XCTAssertEqual(cfg.agent.enabled, false)
    XCTAssertEqual(cfg.agent.backend, .exec)
    XCTAssertEqual(cfg.agent.webSearch, .cached)
    XCTAssertEqual(cfg.agent.promptProfile, .largeOpt)
    XCTAssertEqual(cfg.agent.reasoningEffort, .low)
    XCTAssertEqual(cfg.agent.reasoningSummary, .auto)
  }

  func testSanitizesMinimalEffortForSpark() throws {
    let cfg = try JSONDecoder().decode(
      TurboDraftConfig.self,
      from: Data(#"{"agent":{"model":"gpt-5.3-codex-spark","reasoningEffort":"minimal"}}"#.utf8)
    ).sanitized()
    XCTAssertEqual(cfg.agent.reasoningEffort, .low)
  }

  func testDecodeDarkTheme() throws {
    let cfg = try JSONDecoder().decode(TurboDraftConfig.self, from: Data(#"{"theme":"dark"}"#.utf8))
    XCTAssertEqual(cfg.theme, .dark)
  }

  func testSanitizesNegativeAutosaveDebounce() throws {
    let cfg = try JSONDecoder().decode(
      TurboDraftConfig.self,
      from: Data(#"{"autosaveDebounceMs":-15}"#.utf8)
    ).sanitized()
    XCTAssertEqual(cfg.autosaveDebounceMs, 0)
  }

  func testDecodeClaudeBackend() throws {
    let cfg = try JSONDecoder().decode(
      TurboDraftConfig.self,
      from: Data(#"{"agent":{"backend":"claude","model":"claude-sonnet-4-6","command":"claude"}}"#.utf8)
    )
    XCTAssertEqual(cfg.agent.backend, .claude)
    XCTAssertEqual(cfg.agent.model, "claude-sonnet-4-6")
    XCTAssertEqual(cfg.agent.command, "claude")
  }

  func testClaudeBackendRoundTrips() throws {
    var cfg = TurboDraftConfig()
    cfg.agent.backend = .claude
    cfg.agent.model = "claude-sonnet-4-6"
    cfg.agent.command = "claude"
    let data = try JSONEncoder().encode(cfg)
    let decoded = try JSONDecoder().decode(TurboDraftConfig.self, from: data)
    XCTAssertEqual(decoded.agent.backend, .claude)
    XCTAssertEqual(decoded.agent.model, "claude-sonnet-4-6")
    XCTAssertEqual(decoded.agent.command, "claude")
  }

  func testSanitizedRejectsUnknownAgentCommand() throws {
    let cfg = try JSONDecoder().decode(
      TurboDraftConfig.self,
      from: Data(#"{"agent":{"backend":"exec","command":"./evil-wrapper"}}"#.utf8)
    ).sanitized()
    XCTAssertEqual(cfg.agent.command, "codex")
  }

  func testSanitizedAlignsAgentCommandWithBackend() throws {
    let execCfg = try JSONDecoder().decode(
      TurboDraftConfig.self,
      from: Data(#"{"agent":{"backend":"exec","command":"claude"}}"#.utf8)
    ).sanitized()
    XCTAssertEqual(execCfg.agent.command, "codex")

    let claudeCfg = try JSONDecoder().decode(
      TurboDraftConfig.self,
      from: Data(#"{"agent":{"backend":"claude","command":"codex"}}"#.utf8)
    ).sanitized()
    XCTAssertEqual(claudeCfg.agent.command, "claude")
  }
}
