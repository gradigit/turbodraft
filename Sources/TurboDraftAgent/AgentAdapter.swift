import Foundation

public protocol AgentAdapting: Sendable {
  func draft(prompt: String, instruction: String, images: [URL]) async throws -> String
}

extension AgentAdapting {
  /// Convenience overload for call sites that don't attach images.
  public func draft(prompt: String, instruction: String) async throws -> String {
    try await draft(prompt: prompt, instruction: instruction, images: [])
  }
}
