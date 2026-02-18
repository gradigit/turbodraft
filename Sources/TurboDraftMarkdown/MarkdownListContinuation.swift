import Foundation

public enum MarkdownListContinuationAction: Sendable, Equatable {
  case continueWith(prefix: String)
  case exit(removingPrefix: String)
}

public enum MarkdownListContinuation {
  private static let taskRegex = try! NSRegularExpression(
    pattern: #"^([ \t]*(?:>[ \t]*)*)([-+*])([ \t]+)\[([ xX])\]([ \t]+)(.*)$"#
  )
  private static let unorderedRegex = try! NSRegularExpression(
    pattern: #"^([ \t]*(?:>[ \t]*)*)([-+*])([ \t]+)(.*)$"#
  )
  private static let orderedRegex = try! NSRegularExpression(
    pattern: #"^([ \t]*(?:>[ \t]*)*)(\d{1,9})([.)])([ \t]+)(.*)$"#
  )
  private static let quoteRegex = try! NSRegularExpression(
    pattern: #"^([ \t]*(?:>[ \t]*)+)(.*)$"#
  )

  /// Determines list continuation behavior for pressing Enter at the end of a line.
  ///
  /// Returns:
  /// - `.continueWith(prefix:)` when the line should continue as a new list item.
  /// - `.exit(removingPrefix:)` when pressing Enter on an empty list item should remove the marker.
  /// - `nil` when no list continuation behavior should apply.
  public static func actionForEnter(in line: String) -> MarkdownListContinuationAction? {
    if let parsed = parseTask(line) {
      return parsed
    }
    if let parsed = parseUnordered(line) {
      return parsed
    }
    if let parsed = parseOrdered(line) {
      return parsed
    }
    if let parsed = parseQuote(line) {
      return parsed
    }
    return nil
  }

  private static func parseTask(_ line: String) -> MarkdownListContinuationAction? {
    let ns = line as NSString
    let full = NSRange(location: 0, length: ns.length)
    guard let m = taskRegex.firstMatch(in: line, range: full) else { return nil }
    let lead = ns.substring(with: m.range(at: 1))
    let marker = ns.substring(with: m.range(at: 2))
    let markerGap = ns.substring(with: m.range(at: 3))
    let boxGap = ns.substring(with: m.range(at: 5))
    let body = ns.substring(with: m.range(at: 6))

    let existingPrefix = lead + marker + markerGap + "[\(ns.substring(with: m.range(at: 4)))]" + boxGap
    let continuePrefix = lead + marker + markerGap + "[ ]" + boxGap
    return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? .exit(removingPrefix: existingPrefix)
      : .continueWith(prefix: continuePrefix)
  }

  private static func parseUnordered(_ line: String) -> MarkdownListContinuationAction? {
    let ns = line as NSString
    let full = NSRange(location: 0, length: ns.length)
    guard let m = unorderedRegex.firstMatch(in: line, range: full) else { return nil }
    let lead = ns.substring(with: m.range(at: 1))
    let marker = ns.substring(with: m.range(at: 2))
    let gap = ns.substring(with: m.range(at: 3))
    let body = ns.substring(with: m.range(at: 4))

    let prefix = lead + marker + gap
    return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? .exit(removingPrefix: prefix)
      : .continueWith(prefix: prefix)
  }

  private static func parseOrdered(_ line: String) -> MarkdownListContinuationAction? {
    let ns = line as NSString
    let full = NSRange(location: 0, length: ns.length)
    guard let m = orderedRegex.firstMatch(in: line, range: full) else { return nil }
    let lead = ns.substring(with: m.range(at: 1))
    let n = Int(ns.substring(with: m.range(at: 2))) ?? 1
    let delim = ns.substring(with: m.range(at: 3))
    let gap = ns.substring(with: m.range(at: 4))
    let body = ns.substring(with: m.range(at: 5))

    let existingPrefix = lead + "\(n)\(delim)\(gap)"
    let continuePrefix = lead + "\(n + 1)\(delim)\(gap)"
    return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? .exit(removingPrefix: existingPrefix)
      : .continueWith(prefix: continuePrefix)
  }

  private static func parseQuote(_ line: String) -> MarkdownListContinuationAction? {
    let ns = line as NSString
    let full = NSRange(location: 0, length: ns.length)
    guard let m = quoteRegex.firstMatch(in: line, range: full) else { return nil }
    let prefix = ns.substring(with: m.range(at: 1))
    let body = ns.substring(with: m.range(at: 2))

    return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? .exit(removingPrefix: prefix)
      : .continueWith(prefix: prefix)
  }
}
