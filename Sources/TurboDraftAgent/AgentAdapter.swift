import Foundation

public protocol AgentAdapting: Sendable {
  func draft(prompt: String, instruction: String) async throws -> String
}

