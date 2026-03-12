import Foundation

struct ExternalSessionContextAttachment: Sendable, Equatable {
  static let supportedFormatVersion = 1

  var source: String?
  var contextPath: String
  var contextFormatVersion: Int?

  var isSupportedFormat: Bool {
    contextFormatVersion == nil || contextFormatVersion == Self.supportedFormatVersion
  }

  init?(
    source: String?,
    contextPath: String?,
    contextFormatVersion: Int?
  ) {
    guard let rawContextPath = Self.normalizedNonEmpty(contextPath) else { return nil }
    guard NSString(string: rawContextPath).isAbsolutePath else { return nil }
    self.source = Self.normalizedNonEmpty(source)
    self.contextPath = URL(fileURLWithPath: rawContextPath).standardizedFileURL.path
    self.contextFormatVersion = contextFormatVersion
  }

  private static func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }
}

struct ExternalSessionContextSnapshot: Sendable, Equatable {
  static let maxAgentCharacters = 8_000

  var source: String?
  var displayText: String
  var agentText: String
  var wasTruncated: Bool
  var byteCount: Int

  static func load(from attachment: ExternalSessionContextAttachment) throws -> ExternalSessionContextSnapshot {
    let url = URL(fileURLWithPath: attachment.contextPath)
    let data = try Data(contentsOf: url)

    let normalized = normalizeContextData(data)
    let agentPrepared = truncate(normalized.agentText, limit: maxAgentCharacters)
    let displayPrepared = truncate(normalized.displayText, limit: maxAgentCharacters)

    return ExternalSessionContextSnapshot(
      source: attachment.source,
      displayText: displayPrepared.text,
      agentText: agentPrepared.text,
      wasTruncated: agentPrepared.truncated || displayPrepared.truncated,
      byteCount: data.count
    )
  }

  private static func normalizeContextData(_ data: Data) -> (displayText: String, agentText: String) {
    if let jsonObject = try? JSONSerialization.jsonObject(with: data),
       JSONSerialization.isValidJSONObject(jsonObject),
       let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
       let prettyText = String(data: prettyData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !prettyText.isEmpty
    {
      return (prettyText, prettyText)
    }

    if let text = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    {
      return (text, text)
    }

    let fallback = "<session context unreadable>"
    return (fallback, fallback)
  }

  private static func truncate(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
    guard text.count > limit else { return (text, false) }
    let idx = text.index(text.startIndex, offsetBy: limit)
    return ("\(text[..<idx])\n\n…[truncated]", true)
  }
}
