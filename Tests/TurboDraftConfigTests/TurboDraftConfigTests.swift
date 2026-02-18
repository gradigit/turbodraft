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
}
