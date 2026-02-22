import Foundation

public struct MarkdownEnterEdit: Sendable, Equatable {
  public let replaceRange: NSRange
  public let replacement: String
  public let selectedLocation: Int

  public init(replaceRange: NSRange, replacement: String, selectedLocation: Int) {
    self.replaceRange = replaceRange
    self.replacement = replacement
    self.selectedLocation = selectedLocation
  }
}

public enum MarkdownEnterBehavior {
  private static let fenceRegex = try! NSRegularExpression(pattern: #"^(\s*)(`{3,}|~{3,})(.*)$"#)
  private static let taskRegex = try! NSRegularExpression(
    pattern: #"^([ \t]*(?:>[ \t]*)*)([-+*])([ \t]+)\[([ xX])\]([ \t]+)(.*)$"#
  )
  private static let unorderedRegex = try! NSRegularExpression(
    pattern: #"^([ \t]*(?:>[ \t]*)*)([-+*])([ \t]+)(.*)$"#
  )
  private static let orderedRegex = try! NSRegularExpression(
    pattern: #"^([ \t]*(?:>[ \t]*)*)(\d{1,9})([.)])([ \t]+)(.*)$"#
  )

  private struct ParsedListLine {
    let body: String
    let existingPrefix: String
    let continuePrefix: String
    let insertAbovePrefix: String
    let prefixLength: Int

    var isBodyEmpty: Bool {
      body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  public static func editForEnter(in document: String, selection: NSRange) -> MarkdownEnterEdit? {
    guard selection.length == 0 else { return nil }

    let ns = document as NSString
    guard selection.location >= 0, selection.location <= ns.length else { return nil }

    let lineBounds = lineBoundsAtCursor(in: ns, cursor: selection.location)

    if isInsideFencedCodeBlock(document: ns, before: lineBounds.lineStart) {
      return nil
    }

    let line = ns.substring(with: NSRange(location: lineBounds.lineStart, length: lineBounds.contentLength))
    guard let parsed = parseListLine(line) else {
      guard selection.location == lineBounds.lineEnd,
            let action = MarkdownListContinuation.actionForEnter(in: line)
      else { return nil }
      switch action {
      case let .continueWith(prefix):
        return MarkdownEnterEdit(
          replaceRange: NSRange(location: selection.location, length: 0),
          replacement: "\n\(prefix)",
          selectedLocation: selection.location + 1 + (prefix as NSString).length
        )
      case let .exit(removingPrefix):
        let removeLen = min((removingPrefix as NSString).length, lineBounds.contentLength)
        guard removeLen > 0 else { return nil }
        return MarkdownEnterEdit(
          replaceRange: NSRange(location: lineBounds.lineStart, length: removeLen),
          replacement: "",
          selectedLocation: max(lineBounds.lineStart, selection.location - removeLen)
        )
      }
    }

    let prefixStart = lineBounds.lineStart + parsed.prefixLength

    // Empty list item at end-of-line exits list mode.
    if parsed.isBodyEmpty, selection.location == lineBounds.lineEnd {
      let removeLen = min((parsed.existingPrefix as NSString).length, lineBounds.contentLength)
      guard removeLen > 0 else { return nil }
      return MarkdownEnterEdit(
        replaceRange: NSRange(location: lineBounds.lineStart, length: removeLen),
        replacement: "",
        selectedLocation: max(lineBounds.lineStart, selection.location - removeLen)
      )
    }

    // At the start of the list item (line-start or prefix boundary), create a
    // new empty list item above while preserving the current item content.
    if selection.location <= prefixStart {
      let insertion = "\(parsed.insertAbovePrefix)\n"
      return MarkdownEnterEdit(
        replaceRange: NSRange(location: lineBounds.lineStart, length: 0),
        replacement: insertion,
        selectedLocation: lineBounds.lineStart + (parsed.insertAbovePrefix as NSString).length
      )
    }

    // Middle/end of item: split/continue as a new item at the same nesting.
    return MarkdownEnterEdit(
      replaceRange: NSRange(location: selection.location, length: 0),
      replacement: "\n\(parsed.continuePrefix)",
      selectedLocation: selection.location + 1 + (parsed.continuePrefix as NSString).length
    )
  }

  private static func lineBoundsAtCursor(in ns: NSString, cursor: Int) -> (lineStart: Int, lineEnd: Int, contentLength: Int) {
    let lineStart: Int
    if cursor <= 0 {
      lineStart = 0
    } else {
      let searchRange = NSRange(location: 0, length: cursor)
      let prevNL = ns.range(of: "\n", options: .backwards, range: searchRange)
      lineStart = prevNL.location == NSNotFound ? 0 : prevNL.location + 1
    }

    let nextNLRange = NSRange(location: lineStart, length: ns.length - lineStart)
    let nextNL = ns.range(of: "\n", options: [], range: nextNLRange)
    let lineEnd = nextNL.location == NSNotFound ? ns.length : nextNL.location

    var contentLength = max(0, lineEnd - lineStart)
    if contentLength > 0, ns.character(at: lineStart + contentLength - 1) == 0x0D {
      contentLength -= 1
    }

    return (lineStart, lineEnd, contentLength)
  }

  private static func isInsideFencedCodeBlock(document ns: NSString, before location: Int) -> Bool {
    if location <= 0 { return false }
    let end = min(location, ns.length)
    var inFence = false
    var fenceChar: Character?
    var fenceLen = 0

    var idx = 0
    while idx < end {
      let nextNL = ns.range(of: "\n", options: [], range: NSRange(location: idx, length: end - idx))
      let lineEnd = nextNL.location == NSNotFound ? end : nextNL.location
      let lineRange = NSRange(location: idx, length: max(0, lineEnd - idx))
      let line = ns.substring(with: lineRange)

      let full = NSRange(location: 0, length: (line as NSString).length)
      if let m = fenceRegex.firstMatch(in: line, range: full) {
        let delimRange = m.range(at: 2)
        let delim = (line as NSString).substring(with: delimRange)
        let currentChar = delim.first
        let currentLen = (delim as NSString).length

        if !inFence {
          inFence = true
          fenceChar = currentChar
          fenceLen = currentLen
        } else if currentChar == fenceChar, currentLen >= fenceLen {
          inFence = false
          fenceChar = nil
          fenceLen = 0
        }
      }

      if nextNL.location == NSNotFound { break }
      idx = lineEnd + 1
    }

    return inFence
  }

  private static func parseListLine(_ line: String) -> ParsedListLine? {
    let ns = line as NSString
    let full = NSRange(location: 0, length: ns.length)

    if let m = taskRegex.firstMatch(in: line, range: full) {
      let lead = ns.substring(with: m.range(at: 1))
      let marker = ns.substring(with: m.range(at: 2))
      let markerGap = ns.substring(with: m.range(at: 3))
      let boxState = ns.substring(with: m.range(at: 4))
      let boxGap = ns.substring(with: m.range(at: 5))
      let body = ns.substring(with: m.range(at: 6))
      let existingPrefix = lead + marker + markerGap + "[\(boxState)]" + boxGap
      let continuePrefix = lead + marker + markerGap + "[ ]" + boxGap
      return ParsedListLine(
        body: body,
        existingPrefix: existingPrefix,
        continuePrefix: continuePrefix,
        insertAbovePrefix: continuePrefix,
        prefixLength: (existingPrefix as NSString).length
      )
    }

    if let m = unorderedRegex.firstMatch(in: line, range: full) {
      let lead = ns.substring(with: m.range(at: 1))
      let marker = ns.substring(with: m.range(at: 2))
      let gap = ns.substring(with: m.range(at: 3))
      let body = ns.substring(with: m.range(at: 4))
      let prefix = lead + marker + gap
      return ParsedListLine(
        body: body,
        existingPrefix: prefix,
        continuePrefix: prefix,
        insertAbovePrefix: prefix,
        prefixLength: (prefix as NSString).length
      )
    }

    if let m = orderedRegex.firstMatch(in: line, range: full) {
      let lead = ns.substring(with: m.range(at: 1))
      let n = Int(ns.substring(with: m.range(at: 2))) ?? 1
      let delim = ns.substring(with: m.range(at: 3))
      let gap = ns.substring(with: m.range(at: 4))
      let body = ns.substring(with: m.range(at: 5))
      let existingPrefix = lead + "\(n)\(delim)\(gap)"
      let continuePrefix = lead + "\(n + 1)\(delim)\(gap)"
      let insertAbovePrefix = lead + "\(n)\(delim)\(gap)"
      return ParsedListLine(
        body: body,
        existingPrefix: existingPrefix,
        continuePrefix: continuePrefix,
        insertAbovePrefix: insertAbovePrefix,
        prefixLength: (existingPrefix as NSString).length
      )
    }

    return nil
  }
}
