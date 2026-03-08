import Foundation

struct ExternalQueueAttachment: Sendable, Equatable {
  static let supportedFormatVersion = 1

  var source: String?
  var queuePath: String
  var queueKey: String?
  var queueFormatVersion: Int?

  var isSupportedFormat: Bool {
    queueFormatVersion == nil || queueFormatVersion == Self.supportedFormatVersion
  }

  init?(
    source: String?,
    queuePath: String?,
    queueKey: String?,
    queueFormatVersion: Int?
  ) {
    guard let rawQueuePath = Self.normalizedNonEmpty(queuePath) else { return nil }
    guard NSString(string: rawQueuePath).isAbsolutePath else { return nil }
    self.source = Self.normalizedNonEmpty(source)
    self.queuePath = URL(fileURLWithPath: rawQueuePath).standardizedFileURL.path
    self.queueKey = Self.normalizedNonEmpty(queueKey)
    self.queueFormatVersion = queueFormatVersion
  }

  private static func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }
}
