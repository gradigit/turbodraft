import Foundation

public protocol AgentAdapting: Sendable {
  func draft(prompt: String, instruction: String, images: [URL], cwd: String?) async throws -> String
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
