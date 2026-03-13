import AppKit
import TurboDraftConfig
import XCTest
@testable import TurboDraftApp

@MainActor
final class SettingsViewControllerTests: XCTestCase {
  private let fontPresets: [(title: String, family: String)] = [
    ("System Mono", "system"),
    ("Menlo", "Menlo"),
  ]

  private func makeController(
    config: TurboDraftConfig,
    onAction: @escaping (SettingsAction) -> TurboDraftConfig
  ) -> SettingsViewController {
    let controller = SettingsViewController(
      config: config,
      colorThemes: EditorColorTheme.builtInThemes,
      modelPresets: ["gpt-5.3-codex-spark", "claude-sonnet-4-6"],
      fontPresets: fontPresets,
      applyAction: onAction
    )
    controller.loadViewIfNeeded()
    return controller
  }

  func testRefreshAppliesExternalConfigChanges() {
    let initial = TurboDraftConfig()
    let controller = makeController(config: initial) { _ in initial }

    var updated = initial
    updated.theme = .dark
    updated.agent.draftingPreset = .research
    updated.externalSessionQueues = .init(enabled: false, autoRevealOnAttach: true)
    controller.refresh(
      config: updated,
      colorThemes: EditorColorTheme.builtInThemes,
      modelPresets: ["gpt-5.3-codex-spark", "claude-sonnet-4-6"],
      fontPresets: fontPresets
    )

    XCTAssertEqual(controller._testingSelectedThemeRawValue(), TurboDraftConfig.ThemeMode.dark.rawValue)
    XCTAssertEqual(controller._testingSelectedDraftingPresetRawValue(), TurboDraftConfig.Agent.DraftingPreset.research.rawValue)
    XCTAssertEqual(controller._testingQueuesEnabledState(), .off)
    XCTAssertFalse(controller._testingQueueAutoRevealEnabled())
  }

  func testModelCommitUsesApplyActionResult() {
    var current = TurboDraftConfig()
    let controller = makeController(config: current) { action in
      switch action {
      case .setAgentModel(let model):
        current.agent.model = model
      default:
        break
      }
      return current
    }

    controller._testingSetModelTextAndCommit("gpt-5.4")

    XCTAssertEqual(current.agent.model, "gpt-5.4")
    XCTAssertEqual(controller._testingModelText(), "gpt-5.4")
  }

  func testSettingsViewBuildsAllSections() {
    let controller = makeController(config: TurboDraftConfig()) { _ in TurboDraftConfig() }

    XCTAssertEqual(controller._testingSectionCount(), 5)
    XCTAssertGreaterThan(controller.view.fittingSize.height, 300)
  }
}
