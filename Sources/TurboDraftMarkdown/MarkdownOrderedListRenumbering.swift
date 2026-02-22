import Foundation

public enum MarkdownOrderedListRenumbering {
  private struct OrderedLine {
    let lead: String
    let delimiter: String
    let number: Int
    let numberRange: NSRange
  }

  private static let orderedRegex = try! NSRegularExpression(
    pattern: #"^([ \t]*(?:>[ \t]*)*)(\d{1,9})([.)])([ \t]+)(.*)$"#
  )

  /// Renumbers a contiguous ordered-list block around `cursor`.
  ///
  /// Returns `nil` when no renumbering is needed.
  public static func renumber(document: String, around cursor: Int) -> String? {
    let ns = document as NSString
    guard ns.length > 0 else { return nil }

    let lines = allLineRanges(in: ns)
    guard !lines.isEmpty else { return nil }

    let anchorIndex = nearestOrderedLineIndex(in: ns, lines: lines, around: cursor)
    guard let anchorIndex else { return nil }

    guard let anchor = parseOrderedLine(in: ns, lineRange: lines[anchorIndex]) else {
      return nil
    }

    var start = anchorIndex
    while start > 0,
          let prev = parseOrderedLine(in: ns, lineRange: lines[start - 1]),
          prev.lead == anchor.lead,
          prev.delimiter == anchor.delimiter
    {
      start -= 1
    }

    var end = anchorIndex
    while end + 1 < lines.count,
          let next = parseOrderedLine(in: ns, lineRange: lines[end + 1]),
          next.lead == anchor.lead,
          next.delimiter == anchor.delimiter
    {
      end += 1
    }

    guard start <= end else { return nil }

    var orderedLines: [OrderedLine] = []
    orderedLines.reserveCapacity(end - start + 1)
    for i in start...end {
      guard let parsed = parseOrderedLine(in: ns, lineRange: lines[i]) else {
        return nil
      }
      orderedLines.append(parsed)
    }

    guard let first = orderedLines.first else { return nil }
    let startNumber = max(1, first.number)

    let mutable = NSMutableString(string: document)
    var changed = false
    for (offset, line) in orderedLines.enumerated().reversed() {
      let expected = startNumber + offset
      if line.number == expected { continue }
      mutable.replaceCharacters(in: line.numberRange, with: "\(expected)")
      changed = true
    }

    guard changed else { return nil }
    return mutable as String
  }

  private static func allLineRanges(in ns: NSString) -> [NSRange] {
    var ranges: [NSRange] = []
    var idx = 0
    while idx <= ns.length {
      let range = ns.lineRange(for: NSRange(location: idx, length: 0))
      ranges.append(range)
      let next = NSMaxRange(range)
      if next >= ns.length { break }
      idx = next
    }
    return ranges
  }

  private static func nearestOrderedLineIndex(in ns: NSString, lines: [NSRange], around cursor: Int) -> Int? {
    let clamped = max(0, min(cursor, ns.length))
    var containing: Int?
    for (i, lineRange) in lines.enumerated() {
      if NSLocationInRange(clamped, lineRange) || (clamped == NSMaxRange(lineRange) && clamped == ns.length) {
        containing = i
        break
      }
    }
    guard let idx = containing else { return nil }

    if parseOrderedLine(in: ns, lineRange: lines[idx]) != nil {
      return idx
    }
    if idx > 0, parseOrderedLine(in: ns, lineRange: lines[idx - 1]) != nil {
      return idx - 1
    }
    if idx + 1 < lines.count, parseOrderedLine(in: ns, lineRange: lines[idx + 1]) != nil {
      return idx + 1
    }
    return nil
  }

  private static func parseOrderedLine(in ns: NSString, lineRange: NSRange) -> OrderedLine? {
    var contentRange = lineRange
    if contentRange.length > 0, ns.character(at: NSMaxRange(contentRange) - 1) == 0x0A {
      contentRange.length -= 1
    }
    if contentRange.length > 0, ns.character(at: NSMaxRange(contentRange) - 1) == 0x0D {
      contentRange.length -= 1
    }
    let line = ns.substring(with: contentRange)
    let lineNS = line as NSString
    let full = NSRange(location: 0, length: lineNS.length)
    guard let m = orderedRegex.firstMatch(in: line, range: full) else { return nil }

    let lead = lineNS.substring(with: m.range(at: 1))
    let n = Int(lineNS.substring(with: m.range(at: 2))) ?? 1
    let delim = lineNS.substring(with: m.range(at: 3))
    let absoluteNumberRange = NSRange(
      location: contentRange.location + m.range(at: 2).location,
      length: m.range(at: 2).length
    )
    return OrderedLine(lead: lead, delimiter: delim, number: n, numberRange: absoluteNumberRange)
  }
}
