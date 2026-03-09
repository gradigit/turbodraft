import Foundation
import TurboDraftAgent
import XCTest

private struct StaticDraftAdapter: AgentAdapting {
  let value: String

  func draft(prompt _: String, instruction _: String, images _: [URL], cwd _: String?) async throws -> String {
    value
  }
}

private final class RouteReportingDraftAdapter: AgentAdapting, AgentRouteReporting, @unchecked Sendable {
  let value: String
  let label: String
  private var _lastRouteLabel: String = "uninitialized"

  init(value: String, label: String) {
    self.value = value
    self.label = label
  }

  var lastRouteLabel: String {
    return _lastRouteLabel
  }

  func draft(prompt _: String, instruction _: String, images _: [URL], cwd _: String?) async throws -> String {
    _lastRouteLabel = label
    return value
  }
}

private struct StaticChatAdapter: AgentAdapting, AgentSidebarChatAdapting {
  let draftValue: String
  let chatValue: String

  func draft(prompt _: String, instruction _: String, images _: [URL], cwd _: String?) async throws -> String {
    draftValue
  }

  func chat(message _: String, draft _: String, images _: [URL], cwd _: String?) async throws -> String {
    chatValue
  }
}

private struct FailingDraftAdapter: AgentAdapting {
  struct AdapterError: Error, Equatable {}

  func draft(prompt _: String, instruction _: String, images _: [URL], cwd _: String?) async throws -> String {
    throw AdapterError()
  }

  func testChatUsesPrimaryWhenPrimarySupportsChat() async throws {
    let wrapper = FallbackPromptEngineerAdapter(
      primary: StaticChatAdapter(draftValue: "primary", chatValue: "primary-chat"),
      fallback: StaticChatAdapter(draftValue: "fallback", chatValue: "fallback-chat"),
      primaryLabel: "primary-route",
      fallbackLabel: "fallback-route"
    )

    let out = try await wrapper.chat(message: "m", draft: "d", images: [], cwd: nil)
    XCTAssertEqual(out, "primary-chat")
    XCTAssertEqual(wrapper.lastRouteLabel, "primary-route chat")
  }

  func testChatFallsBackWhenPrimaryChatFails() async throws {
    struct FailingChatAdapter: AgentAdapting, AgentSidebarChatAdapting {
      struct ChatError: Error {}
      func draft(prompt _: String, instruction _: String, images _: [URL], cwd _: String?) async throws -> String { "ok" }
      func chat(message _: String, draft _: String, images _: [URL], cwd _: String?) async throws -> String { throw ChatError() }
    }

    let wrapper = FallbackPromptEngineerAdapter(
      primary: FailingChatAdapter(),
      fallback: StaticChatAdapter(draftValue: "fallback", chatValue: "fallback-chat"),
      primaryLabel: "primary-route",
      fallbackLabel: "fallback-route"
    )

    let out = try await wrapper.chat(message: "m", draft: "d", images: [], cwd: nil)
    XCTAssertEqual(out, "fallback-chat")
    XCTAssertEqual(wrapper.lastRouteLabel, "fallback-route chat fallback")
  }
}

final class FallbackPromptEngineerAdapterTests: XCTestCase {
  func testChatUsesPrimaryWhenPrimarySupportsChat() async throws {
    let wrapper = FallbackPromptEngineerAdapter(
      primary: StaticChatAdapter(draftValue: "primary", chatValue: "primary-chat"),
      fallback: StaticChatAdapter(draftValue: "fallback", chatValue: "fallback-chat"),
      primaryLabel: "primary-route",
      fallbackLabel: "fallback-route"
    )

    let out = try await wrapper.chat(message: "m", draft: "d", images: [], cwd: nil)
    XCTAssertEqual(out, "primary-chat")
    XCTAssertEqual(wrapper.lastRouteLabel, "primary-route chat")
  }

  func testChatFallsBackWhenPrimaryChatFails() async throws {
    struct FailingChatAdapter: AgentAdapting, AgentSidebarChatAdapting {
      struct ChatError: Error {}
      func draft(prompt _: String, instruction _: String, images _: [URL], cwd _: String?) async throws -> String { "ok" }
      func chat(message _: String, draft _: String, images _: [URL], cwd _: String?) async throws -> String { throw ChatError() }
    }

    let wrapper = FallbackPromptEngineerAdapter(
      primary: FailingChatAdapter(),
      fallback: StaticChatAdapter(draftValue: "fallback", chatValue: "fallback-chat"),
      primaryLabel: "primary-route",
      fallbackLabel: "fallback-route"
    )

    let out = try await wrapper.chat(message: "m", draft: "d", images: [], cwd: nil)
    XCTAssertEqual(out, "fallback-chat")
    XCTAssertEqual(wrapper.lastRouteLabel, "fallback-route chat fallback")
  }

  func testUsesPrimaryWhenPrimarySucceeds() async throws {
    let wrapper = FallbackPromptEngineerAdapter(
      primary: StaticDraftAdapter(value: "primary"),
      fallback: StaticDraftAdapter(value: "fallback"),
      primaryLabel: "primary-route",
      fallbackLabel: "fallback-route"
    )

    let out = try await wrapper.draft(prompt: "p", instruction: "i", images: [], cwd: nil)
    XCTAssertEqual(out, "primary")
    XCTAssertEqual(wrapper.lastRouteLabel, "primary-route")
  }

  func testFallsBackWhenPrimaryFails() async throws {
    let wrapper = FallbackPromptEngineerAdapter(
      primary: FailingDraftAdapter(),
      fallback: StaticDraftAdapter(value: "fallback"),
      primaryLabel: "primary-route",
      fallbackLabel: "fallback-route"
    )

    let out = try await wrapper.draft(prompt: "p", instruction: "i", images: [], cwd: nil)
    XCTAssertEqual(out, "fallback")
    XCTAssertEqual(wrapper.lastRouteLabel, "fallback-route fallback")
  }

  func testThrowsCombinedErrorWhenBothFail() async {
    let wrapper = FallbackPromptEngineerAdapter(
      primary: FailingDraftAdapter(),
      fallback: FailingDraftAdapter(),
      primaryLabel: "primary-route",
      fallbackLabel: "fallback-route"
    )

    do {
      _ = try await wrapper.draft(prompt: "p", instruction: "i", images: [], cwd: nil)
      XCTFail("Expected combined fallback error")
    } catch let err as FallbackPromptEngineerError {
      switch err {
      case let .primaryAndFallbackFailed(primary, fallback):
        XCTAssertTrue(primary is FailingDraftAdapter.AdapterError)
        XCTAssertTrue(fallback is FailingDraftAdapter.AdapterError)
      case .chatNotSupported:
        XCTFail("Unexpected chatNotSupported for draft flow")
      }
      XCTAssertEqual(wrapper.lastRouteLabel, "primary-route + fallback-route (failed)")
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testDraftDoesNotFallbackWhenPredicateRejects() async {
    let wrapper = FallbackPromptEngineerAdapter(
      primary: FailingDraftAdapter(),
      fallback: StaticDraftAdapter(value: "fallback"),
      primaryLabel: "primary-route",
      fallbackLabel: "fallback-route",
      shouldFallback: { _ in false }
    )

    do {
      _ = try await wrapper.draft(prompt: "p", instruction: "i", images: [], cwd: nil)
      XCTFail("Expected primary error without fallback")
    } catch {
      XCTAssertTrue(error is FailingDraftAdapter.AdapterError)
      XCTAssertEqual(wrapper.lastRouteLabel, "primary-route (failed)")
    }
  }

  func testUsesUnderlyingRouteReportingLabel() async throws {
    let wrapper = FallbackPromptEngineerAdapter(
      primary: RouteReportingDraftAdapter(value: "primary", label: "codex exec (direct)"),
      fallback: StaticDraftAdapter(value: "fallback"),
      primaryLabel: "primary-route",
      fallbackLabel: "fallback-route"
    )

    let out = try await wrapper.draft(prompt: "p", instruction: "i", images: [], cwd: nil)
    XCTAssertEqual(out, "primary")
    XCTAssertEqual(wrapper.lastRouteLabel, "codex exec (direct)")
  }
}
