import Foundation

public enum FallbackPromptEngineerError: Error, CustomStringConvertible {
  case primaryAndFallbackFailed(primary: Error, fallback: Error)
  case chatNotSupported

  public var description: String {
    switch self {
    case let .primaryAndFallbackFailed(primary, fallback):
      return "Primary failed (\(primary)); fallback failed (\(fallback))"
    case .chatNotSupported:
      return "Interactive chat is not supported by this adapter route"
    }
  }
}

/// Wraps a primary drafting adapter with an optional fallback adapter.
///
/// Intended use in TurboDraft:
/// - primary: direct Codex path (app-server or exec)
/// - fallback: LiteLLM-routed Codex path
public final class FallbackPromptEngineerAdapter: AgentAdapting, AgentSidebarStreamingChatAdapting, AgentRouteReporting, @unchecked Sendable {
  private let primary: AgentAdapting
  private let fallback: AgentAdapting?
  private let primaryLabel: String
  private let fallbackLabel: String
  private let shouldFallback: @Sendable (Error) -> Bool
  private let lock = NSLock()
  private var _lastRouteLabel: String = "uninitialized"

  public var lastRouteLabel: String {
    lock.lock()
    defer { lock.unlock() }
    return _lastRouteLabel
  }

  public init(
    primary: AgentAdapting,
    fallback: AgentAdapting?,
    primaryLabel: String,
    fallbackLabel: String,
    shouldFallback: @escaping @Sendable (Error) -> Bool = { _ in true }
  ) {
    self.primary = primary
    self.fallback = fallback
    self.primaryLabel = primaryLabel
    self.fallbackLabel = fallbackLabel
    self.shouldFallback = shouldFallback
  }

  public func draft(prompt: String, instruction: String, images: [URL], cwd: String?) async throws -> String {
    do {
      let out = try await primary.draft(prompt: prompt, instruction: instruction, images: images, cwd: cwd)
      setLastRoute(resolvedRouteLabel(for: primary, defaultLabel: primaryLabel))
      return out
    } catch {
      let primaryError = error
      guard shouldFallback(primaryError), let fallback else {
        setLastRoute("\(resolvedRouteLabel(for: primary, defaultLabel: primaryLabel)) (failed)")
        throw primaryError
      }

      do {
        let out = try await fallback.draft(prompt: prompt, instruction: instruction, images: images, cwd: cwd)
        setLastRoute("\(resolvedRouteLabel(for: fallback, defaultLabel: fallbackLabel)) fallback")
        return out
      } catch {
        let fallbackError = error
        setLastRoute(
          "\(resolvedRouteLabel(for: primary, defaultLabel: primaryLabel)) + \(resolvedRouteLabel(for: fallback, defaultLabel: fallbackLabel)) (failed)"
        )
        throw FallbackPromptEngineerError.primaryAndFallbackFailed(primary: primaryError, fallback: fallbackError)
      }
    }
  }

  public func chat(message: String, draft: String, images: [URL], cwd: String?) async throws -> String {
    try await chat(message: message, draft: draft, images: images, cwd: cwd, onDelta: { _ in })
  }

  public func chat(
    message: String,
    draft: String,
    images: [URL],
    cwd: String?,
    onDelta: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    let primaryChat = primary as? AgentSidebarChatAdapting
    let fallbackChat = fallback as? AgentSidebarChatAdapting
    guard primaryChat != nil || fallbackChat != nil else {
      throw FallbackPromptEngineerError.chatNotSupported
    }

    do {
      guard let primaryChat else { throw FallbackPromptEngineerError.chatNotSupported }
      let out: String
      if let streaming = primaryChat as? AgentSidebarStreamingChatAdapting {
        out = try await streaming.chat(message: message, draft: draft, images: images, cwd: cwd, onDelta: onDelta)
      } else {
        out = try await primaryChat.chat(message: message, draft: draft, images: images, cwd: cwd)
        onDelta(out)
      }
      setLastRoute("\(resolvedRouteLabel(for: primary, defaultLabel: primaryLabel)) chat")
      return out
    } catch {
      let primaryError = error
      guard shouldFallback(primaryError), let fallbackChat else {
        setLastRoute("\(resolvedRouteLabel(for: primary, defaultLabel: primaryLabel)) chat (failed)")
        throw primaryError
      }
      do {
        let out: String
        if let streaming = fallbackChat as? AgentSidebarStreamingChatAdapting {
          out = try await streaming.chat(message: message, draft: draft, images: images, cwd: cwd, onDelta: onDelta)
        } else {
          out = try await fallbackChat.chat(message: message, draft: draft, images: images, cwd: cwd)
          onDelta(out)
        }
        setLastRoute("\(resolvedRouteLabel(for: fallbackChat, defaultLabel: fallbackLabel)) chat fallback")
        return out
      } catch {
        let fallbackError = error
        setLastRoute(
          "\(resolvedRouteLabel(for: primary, defaultLabel: primaryLabel)) + \(resolvedRouteLabel(for: fallbackChat, defaultLabel: fallbackLabel)) chat (failed)"
        )
        throw FallbackPromptEngineerError.primaryAndFallbackFailed(primary: primaryError, fallback: fallbackError)
      }
    }
  }

  public func resetChatSession() {
    (primary as? AgentSidebarChatAdapting)?.resetChatSession()
    (fallback as? AgentSidebarChatAdapting)?.resetChatSession()
  }

  private func setLastRoute(_ value: String) {
    lock.lock()
    _lastRouteLabel = value
    lock.unlock()
  }

  private func resolvedRouteLabel(for adapter: Any, defaultLabel: String) -> String {
    guard let reporting = adapter as? AgentRouteReporting else { return defaultLabel }
    let reported = reporting.lastRouteLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    return reported.isEmpty || reported == "uninitialized" ? defaultLabel : reported
  }
}
