import Foundation

public protocol AgentAdapting: Sendable {
  func draft(prompt: String, instruction: String, images: [URL], cwd: String?) async throws -> String
}

public protocol AgentSidebarChatAdapting: Sendable {
  /// Sends one interactive sidebar chat turn to the drafting agent.
  func chat(message: String, draft: String, images: [URL], cwd: String?) async throws -> String

  /// Clears any adapter-side chat session state (for example thread IDs).
  func resetChatSession()
}

public protocol AgentSidebarStreamingChatAdapting: AgentSidebarChatAdapting {
  /// Sends one interactive sidebar chat turn and emits incremental assistant deltas.
  /// `onDelta` is invoked with appended text chunks in response order.
  func chat(
    message: String,
    draft: String,
    images: [URL],
    cwd: String?,
    onDelta: @escaping @Sendable (String) -> Void
  ) async throws -> String
}

public protocol AgentRouteReporting: AnyObject {
  /// Human-readable route label for the most recent draft call.
  /// Example: "codex app-server (direct)" or "codex app-server (litellm fallback)".
  var lastRouteLabel: String { get }
}

extension AgentAdapting {
  /// Convenience overload for call sites that don't attach images or cwd.
  public func draft(prompt: String, instruction: String) async throws -> String {
    try await draft(prompt: prompt, instruction: instruction, images: [], cwd: nil)
  }

  /// Convenience overload for call sites that don't pass cwd.
  public func draft(prompt: String, instruction: String, images: [URL]) async throws -> String {
    try await draft(prompt: prompt, instruction: instruction, images: images, cwd: nil)
  }
}

extension AgentSidebarChatAdapting {
  public func resetChatSession() {}
}

extension AgentSidebarStreamingChatAdapting {
  public func chat(message: String, draft: String, images: [URL], cwd: String?) async throws -> String {
    try await chat(message: message, draft: draft, images: images, cwd: cwd, onDelta: { _ in })
  }
}
