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

  public static func editForEnter(in document: String, selection: NSRange) -> MarkdownEnterEdit? {
    guard selection.length == 0 else { return nil }

    let ns = document as NSString
    guard selection.location >= 0, selection.location <= ns.length else { return nil }

    let lineBounds = lineBoundsAtCursor(in: ns, cursor: selection.location)
    guard selection.location == lineBounds.lineEnd else { return nil }

    if isInsideFencedCodeBlock(document: ns, before: lineBounds.lineStart) {
      return nil
    }

    let line = ns.substring(with: NSRange(location: lineBounds.lineStart, length: lineBounds.contentLength))
    guard let action = MarkdownListContinuation.actionForEnter(in: line) else { return nil }

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
}
