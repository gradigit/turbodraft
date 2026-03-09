import XCTest
@testable import TurboDraftApp

final class EditorRoutingPolicyTests: XCTestCase {
  func testCodexAdaptiveTimeoutBudgetCapsPrimaryForInteractiveFallback() {
    let budget = EditorViewController.codexAdaptiveTimeoutBudget(configuredTimeoutMs: 60_000)

    XCTAssertEqual(budget.primaryMs, 6_000)
    XCTAssertEqual(budget.fallbackMs, 54_000)
    XCTAssertEqual(budget.primaryMs + budget.fallbackMs, 60_000)
    XCTAssertLessThanOrEqual(budget.primaryMs, 8_000)
  }

  func testCodexAdaptiveTimeoutBudgetPreservesConfiguredTotalAcrossRange() {
    for configured in [2_000, 3_000, 5_000, 10_000, 30_000, 60_000] {
      let budget = EditorViewController.codexAdaptiveTimeoutBudget(configuredTimeoutMs: configured)
      XCTAssertEqual(budget.primaryMs + budget.fallbackMs, max(2_000, configured), "configured=\(configured)")
      XCTAssertGreaterThanOrEqual(budget.primaryMs, 1_000, "configured=\(configured)")
      XCTAssertGreaterThanOrEqual(budget.fallbackMs, 1_000, "configured=\(configured)")
      XCTAssertLessThan(budget.primaryMs, budget.primaryMs + budget.fallbackMs, "configured=\(configured)")
    }
  }

  func testCodexAdaptivePrimaryTimeoutHelperMatchesBudget() {
    for configured in [2_000, 5_000, 60_000] {
      XCTAssertEqual(
        EditorViewController.codexAdaptivePrimaryTimeoutMs(configuredTimeoutMs: configured),
        EditorViewController.codexAdaptiveTimeoutBudget(configuredTimeoutMs: configured).primaryMs
      )
    }
  }
}
