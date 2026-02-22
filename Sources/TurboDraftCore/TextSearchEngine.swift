import Foundation

public struct TextSearchOptions: Equatable, Sendable {
  public var caseSensitive: Bool
  public var wholeWord: Bool
  public var regexEnabled: Bool

  public init(caseSensitive: Bool = false, wholeWord: Bool = false, regexEnabled: Bool = false) {
    self.caseSensitive = caseSensitive
    self.wholeWord = wholeWord
    self.regexEnabled = regexEnabled
  }
}

public struct TextSearchSummary: Equatable, Sendable {
  public let totalCount: Int
  public let ranges: [NSRange]
}

public enum TextSearchEngine {
  public static func makeRegex(query: String, options: TextSearchOptions) -> NSRegularExpression? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var pattern = options.regexEnabled ? trimmed : NSRegularExpression.escapedPattern(for: trimmed)
    if options.wholeWord {
      pattern = #"\b(?:\#(pattern))\b"#
    }
    let reOptions: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
    return try? NSRegularExpression(pattern: pattern, options: reOptions)
  }

  public static func summarizeMatches(
    in text: String,
    query: String,
    options: TextSearchOptions,
    captureLimit: Int = Int.max
  ) -> TextSearchSummary? {
    guard let re = makeRegex(query: query, options: options) else { return nil }
    let fullRange = NSRange(location: 0, length: (text as NSString).length)
    var total = 0
    var ranges: [NSRange] = []
    ranges.reserveCapacity(min(captureLimit, 64))
    re.enumerateMatches(in: text, range: fullRange) { match, _, _ in
      guard let match else { return }
      total += 1
      if ranges.count < captureLimit {
        ranges.append(match.range)
      }
    }
    return TextSearchSummary(totalCount: total, ranges: ranges)
  }

  public static func replacementForMatch(
    in text: String,
    range: NSRange,
    query: String,
    replacementTemplate: String,
    options: TextSearchOptions
  ) -> String? {
    guard options.regexEnabled else { return replacementTemplate }
    guard let re = makeRegex(query: query, options: options) else { return nil }
    guard let match = re.firstMatch(in: text, range: range), match.range == range else {
      return replacementTemplate
    }
    return re.replacementString(for: match, in: text, offset: 0, template: replacementTemplate)
  }

  public static func replaceAll(
    in text: String,
    query: String,
    replacementTemplate: String,
    options: TextSearchOptions
  ) -> (text: String, count: Int)? {
    guard let re = makeRegex(query: query, options: options) else { return nil }
    let fullRange = NSRange(location: 0, length: (text as NSString).length)
    let mutable = NSMutableString(string: text)
    let count = re.replaceMatches(in: mutable, range: fullRange, withTemplate: replacementTemplate)
    return (mutable as String, count)
  }
}
