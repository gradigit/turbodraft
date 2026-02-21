import Foundation

public struct MarkdownHighlight: Sendable, Equatable {
  public var range: NSRange
  public var kind: MarkdownHighlightKind

  public init(range: NSRange, kind: MarkdownHighlightKind) {
    self.range = range
    self.kind = kind
  }
}

public enum MarkdownHighlightKind: Sendable, Equatable {
  // Fenced code blocks
  case codeFenceDelimiter
  case codeFenceInfo
  case codeBlockLine

  // Block-level markup
  case headerMarker(level: Int)
  case headerText(level: Int)
  case listMarker
  case taskBox(checked: Bool)
  case taskText(checked: Bool)
  case quoteMarker(level: Int)
  case quoteText(level: Int)
  case horizontalRule

  // Inline markup
  case inlineCodeDelimiter
  case inlineCodeText
  case strongMarker
  case strongText
  case emphasisMarker
  case emphasisText
  case strikethroughMarker
  case strikethroughText
  case highlightMarker
  case highlightText
  case linkText
  case linkURL
  case linkPunctuation

  // Tables
  case tablePipe
  case tableSeparator
  case tableHeaderText
}

public enum MarkdownHighlighter {
  private struct FenceState {
    var inFence: Bool
    var fenceChar: Character?
    var fenceLen: Int
  }

  private struct FenceScanCheckpoint {
    var textObjectID: ObjectIdentifier
    var textLength: Int
    var scannedUpTo: Int
    var stateAtScannedUpTo: FenceState
  }

  // Static regex properties: try! is safe — patterns are compile-time literals.
  private static let fenceRegex = try! NSRegularExpression(
    pattern: #"^(\s*)(`{3,}|~{3,})(.*)$"#,
    options: [.anchorsMatchLines]
  )
  private static let headerRegex = try! NSRegularExpression(pattern: #"^(\s*)(#{1,6})(\s+)(.*)$"#)
  private static let quoteRegex = try! NSRegularExpression(pattern: #"^(\s*)(>+)(\s*)(.*)$"#)
  private static let unorderedListRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])(\s+)(.*)$"#)
  private static let orderedListRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d{1,9})([.)])(\s+)(.*)$"#)
  private static let hrRegex = try! NSRegularExpression(pattern: #"^\s*((?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})\s*$"#)
  private static let tableSepRegex = try! NSRegularExpression(pattern: #"^\|?(\s*:?-{1,}:?\s*\|)+\s*:?-{1,}:?\s*\|?\s*$"#)
  private static let tablePipeRegex = try! NSRegularExpression(pattern: #"\|"#)

  private static let backtickRunRegex = try! NSRegularExpression(pattern: #"`+"#)
  private static let strongRegex = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
  private static let emphasisRegex = try! NSRegularExpression(pattern: #"(\*|_)(?=\S)(.+?)(?<=\S)\1"#)
  private static let strikeRegex = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
  private static let highlightRegex = try! NSRegularExpression(pattern: #"==(?=\S)(.+?)(?<=\S)== "#.trimmingCharacters(in: .whitespaces))
  private static let imageRegex = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#)
  private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#)
  private static let referenceLinkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\[([^\]]+)\]"#)
  private static let linkDefinitionRegex = try! NSRegularExpression(pattern: #"^(\s*)\[([^\]]+)\](\s*:\s*)(\S+)(.*)$"#)
  private static let autoLinkRegex = try! NSRegularExpression(pattern: #"<(https?://[^>]+)>"#)
  private static let bareURLRegex = try! NSRegularExpression(pattern: #"(https?://[^\s<>()\[\]]+)"#)
  private static let wordish = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
  private static let trailingURLPunctuation = CharacterSet(charactersIn: ".,;:!?")
  private static let fenceCheckpointLock = NSLock()
  private static var fenceCheckpoint: FenceScanCheckpoint?

  public static func highlights(in text: String, range: NSRange) -> [MarkdownHighlight] {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    let safe = NSIntersectionRange(range, full)
    if safe.length <= 0 { return [] }

    // Determine whether the starting range is inside a fenced code block by scanning the prefix.
    var state = computeFenceState(in: text, ns: ns, before: safe.location)
    var out: [MarkdownHighlight] = []

    var idx = safe.location
    let end = safe.location + safe.length

    while idx <= end {
      let nextNL = ns.range(of: "\n", options: [], range: NSRange(location: idx, length: max(0, end - idx)))
      let lineEnd = nextNL.location == NSNotFound ? end : nextNL.location
      let lineRange = NSRange(location: idx, length: max(0, lineEnd - idx))
      let line = ns.substring(with: lineRange)

      processLine(line, absLineRange: lineRange, fenceState: &state, out: &out)

      if nextNL.location == NSNotFound { break }
      idx = lineEnd + 1
    }

    // Post-processing: mark table header rows (the line immediately before a separator).
    let separators = out.filter { $0.kind == .tableSeparator }
    for sep in separators {
      // Find the line before the separator.
      guard sep.range.location > 0 else { continue }
      let beforeSep = sep.range.location - 1  // the \n before separator
      guard beforeSep > safe.location else { continue }
      let headerLineRange = ns.lineRange(for: NSRange(location: beforeSep, length: 0))
      let headerLine = ns.substring(with: headerLineRange)
      let trimmed = headerLine.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("|") || trimmed.hasSuffix("|") else { continue }
      // Find cell content between pipes.
      let hns = headerLine as NSString
      let hfull = NSRange(location: 0, length: hns.length)
      let pipeMatches = tablePipeRegex.matches(in: headerLine, range: hfull)
      for i in 0..<(pipeMatches.count - 1) {
        let afterPipe = pipeMatches[i].range.location + pipeMatches[i].range.length
        let nextPipe = pipeMatches[i + 1].range.location
        guard nextPipe > afterPipe else { continue }
        // Trim whitespace from cell content range.
        var cellStart = afterPipe
        var cellEnd = nextPipe
        while cellStart < cellEnd, hns.character(at: cellStart) == 0x20 { cellStart += 1 }
        while cellEnd > cellStart, hns.character(at: cellEnd - 1) == 0x20 { cellEnd -= 1 }
        guard cellEnd > cellStart else { continue }
        out.append(MarkdownHighlight(
          range: NSRange(location: headerLineRange.location + cellStart, length: cellEnd - cellStart),
          kind: .tableHeaderText
        ))
      }
    }

    out.sort {
      if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
      if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
      return String(describing: $0.kind) < String(describing: $1.kind)
    }
    return out
  }

  private static func computeFenceState(in text: String, ns: NSString, before location: Int) -> FenceState {
    if location <= 0 { return FenceState(inFence: false, fenceChar: nil, fenceLen: 0) }
    let end = min(location, ns.length)
    if end <= 0 { return FenceState(inFence: false, fenceChar: nil, fenceLen: 0) }
    var state = FenceState(inFence: false, fenceChar: nil, fenceLen: 0)
    let textObjectID = ObjectIdentifier(ns)
    var scanStart = 0

    fenceCheckpointLock.lock()
    if let checkpoint = fenceCheckpoint,
       checkpoint.textObjectID == textObjectID,
       checkpoint.textLength == ns.length,
       checkpoint.scannedUpTo <= end {
      scanStart = checkpoint.scannedUpTo
      state = checkpoint.stateAtScannedUpTo
    }
    fenceCheckpointLock.unlock()

    let prefixRange = NSRange(location: scanStart, length: max(0, end - scanStart))
    fenceRegex.enumerateMatches(in: text, options: [], range: prefixRange) { match, _, _ in
      guard let match else { return }
      let delimRange = match.range(at: 2)
      guard delimRange.location != NSNotFound, delimRange.length > 0 else { return }
      guard let scalar = UnicodeScalar(ns.character(at: delimRange.location)) else { return }
      let ch = Character(scalar)
      let len = delimRange.length
      if !state.inFence {
        state.inFence = true
        state.fenceChar = ch
        state.fenceLen = len
      } else if ch == state.fenceChar, len >= state.fenceLen {
        state.inFence = false
        state.fenceChar = nil
        state.fenceLen = 0
      }
    }

    fenceCheckpointLock.lock()
    if let checkpoint = fenceCheckpoint,
       checkpoint.textObjectID == textObjectID,
       checkpoint.textLength == ns.length,
       checkpoint.scannedUpTo >= end {
      // Keep farther-progress checkpoint for this same text.
    } else {
      fenceCheckpoint = FenceScanCheckpoint(
        textObjectID: textObjectID,
        textLength: ns.length,
        scannedUpTo: end,
        stateAtScannedUpTo: state
      )
    }
    fenceCheckpointLock.unlock()

    return state
  }

  private struct FenceMatch {
    var indentRange: NSRange
    var delimRange: NSRange
    var infoRange: NSRange
  }

  private static func fenceMatch(in line: String) -> FenceMatch? {
    let full = NSRange(location: 0, length: (line as NSString).length)
    guard let m = fenceRegex.firstMatch(in: line, range: full) else { return nil }
    return FenceMatch(
      indentRange: m.range(at: 1),
      delimRange: m.range(at: 2),
      infoRange: m.range(at: 3)
    )
  }

  private static func processLine(_ line: String, absLineRange: NSRange, fenceState: inout FenceState, out: inout [MarkdownHighlight]) {
    let lineNS = line as NSString
    let full = NSRange(location: 0, length: lineNS.length)

    func add(_ local: NSRange, _ kind: MarkdownHighlightKind) {
      if local.length <= 0 { return }
      out.append(MarkdownHighlight(range: NSRange(location: absLineRange.location + local.location, length: local.length), kind: kind))
    }

    // Fenced code blocks
    if let fence = fenceMatch(in: line) {
      let delim = lineNS.substring(with: fence.delimRange)
      let ch = delim.first
      let len = (delim as NSString).length

      add(fence.delimRange, .codeFenceDelimiter)
      if fence.infoRange.length > 0 {
        // Skip leading whitespace in the info string.
        let info = lineNS.substring(with: fence.infoRange)
        let trimmedLen = (info as NSString).length - (info as NSString).range(of: #"^\s*"#, options: .regularExpression).length
        let trimmedStart = (info as NSString).range(of: #"^\s*"#, options: .regularExpression).length
        if trimmedLen > 0 {
          add(NSRange(location: fence.infoRange.location + trimmedStart, length: trimmedLen), .codeFenceInfo)
        }
      }

      if !fenceState.inFence {
        fenceState.inFence = true
        fenceState.fenceChar = ch
        fenceState.fenceLen = len
      } else if ch == fenceState.fenceChar, len >= fenceState.fenceLen {
        fenceState.inFence = false
        fenceState.fenceChar = nil
        fenceState.fenceLen = 0
      }
      return
    }

    if fenceState.inFence {
      add(full, .codeBlockLine)
      return
    }

    // Horizontal rules
    if hrRegex.firstMatch(in: line, range: full) != nil {
      add(full, .horizontalRule)
      return
    }

    // Table separator row (e.g. `|---|---|---`)
    if tableSepRegex.firstMatch(in: line, range: full) != nil {
      add(full, .tableSeparator)
      return
    }

    // Table rows: highlight `|` pipe characters as markers
    if lineNS.length > 0, lineNS.contains("|") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("|") || trimmed.hasSuffix("|") {
        for m in tablePipeRegex.matches(in: line, range: full) {
          add(m.range, .tablePipe)
        }
      }
    }

    // Block quotes (detect before headers to avoid overlapping highlights on `> # Heading`)
    var isBlockquote = false
    if let m = quoteRegex.firstMatch(in: line, range: full) {
      isBlockquote = true
      let level = lineNS.substring(with: m.range(at: 2)).count
      add(m.range(at: 2), .quoteMarker(level: level))
      let textRange = m.range(at: 4)
      if textRange.length > 0 {
        add(textRange, .quoteText(level: level))
      }
    }

    // Headers (skip if already matched as blockquote to avoid overlapping spans)
    if !isBlockquote, let m = headerRegex.firstMatch(in: line, range: full) {
      let level = lineNS.substring(with: m.range(at: 2)).count
      add(m.range(at: 2), .headerMarker(level: level))
      let textRange = m.range(at: 4)
      if textRange.length > 0 {
        add(textRange, .headerText(level: level))
      }
    }

    // Lists (unordered/ordered)
    if let m = unorderedListRegex.firstMatch(in: line, range: full) {
      // Marker: bullet + following whitespace.
      let markerRange = NSRange(location: m.range(at: 2).location, length: m.range(at: 2).length + m.range(at: 3).length)
      add(markerRange, .listMarker)
      // Task box: `- [ ]` / `- [x]`
      addTaskBoxIfPresent(lineNS: lineNS, after: m.range(at: 3).location + m.range(at: 3).length, absLineRange: absLineRange, out: &out)
    } else if let m = orderedListRegex.firstMatch(in: line, range: full) {
      let markerStart = m.range(at: 2).location
      let markerLen = m.range(at: 2).length + m.range(at: 3).length + m.range(at: 4).length
      add(NSRange(location: markerStart, length: markerLen), .listMarker)
      addTaskBoxIfPresent(lineNS: lineNS, after: m.range(at: 4).location + m.range(at: 4).length, absLineRange: absLineRange, out: &out)
    }

    // Inline code spans (compute first so we can exclude other markup inside)
    var excluded: [NSRange] = []
    let tickMatches = backtickRunRegex.matches(in: line, range: full)
    if tickMatches.count >= 2 {
      var i = 0
      while i + 1 < tickMatches.count {
        let open = tickMatches[i].range
        let close = tickMatches[i + 1].range
        if open.length != close.length {
          i += 1
          continue
        }
        let contentStart = open.location + open.length
        let contentLen = close.location - contentStart
        if contentLen > 0 {
          add(open, .inlineCodeDelimiter)
          add(close, .inlineCodeDelimiter)
          add(NSRange(location: contentStart, length: contentLen), .inlineCodeText)
          excluded.append(NSRange(location: open.location, length: (close.location + close.length) - open.location))
        }
        i += 2
      }
    }

    func isExcluded(_ r: NSRange) -> Bool {
      for ex in excluded {
        if NSIntersectionRange(ex, r).length > 0 { return true }
      }
      return false
    }

    func isWordishBoundarySafe(for marker: String, matchRange: NSRange) -> Bool {
      // Avoid false positives like `a_b_c` -> `_b_` italics.
      guard marker.contains("_") else { return true }
      let before = matchRange.location - 1
      if before >= 0, before < lineNS.length {
        let u = lineNS.character(at: before)
        if let s = UnicodeScalar(Int(u)), wordish.contains(s) { return false }
      }
      let after = NSMaxRange(matchRange)
      if after >= 0, after < lineNS.length {
        let u = lineNS.character(at: after)
        if let s = UnicodeScalar(Int(u)), wordish.contains(s) { return false }
      }
      return true
    }

    // Links
    for m in imageRegex.matches(in: line, range: full) {
      if isExcluded(m.range) { continue }
      let alt = m.range(at: 1)
      let u = m.range(at: 2)
      add(alt, .linkText)
      add(u, .linkURL)
      // "!" "[" "]" "(" ")"
      if m.range.length >= 5 {
        add(NSRange(location: m.range.location, length: 1), .linkPunctuation)
        add(NSRange(location: m.range.location + 1, length: 1), .linkPunctuation)
        add(NSRange(location: alt.location + alt.length, length: 1), .linkPunctuation)
        if u.location - 1 >= 0 { add(NSRange(location: u.location - 1, length: 1), .linkPunctuation) }
        add(NSRange(location: NSMaxRange(m.range) - 1, length: 1), .linkPunctuation)
      }
      excluded.append(m.range)
    }
    for m in linkRegex.matches(in: line, range: full) {
      if isExcluded(m.range) { continue }
      let t = m.range(at: 1)
      let u = m.range(at: 2)
      add(t, .linkText)
      add(u, .linkURL)

      // De-emphasize punctuation: '[' ']' '(' ')'
      if m.range.length >= 4 {
        add(NSRange(location: m.range.location, length: 1), .linkPunctuation) // [
        add(NSRange(location: t.location + t.length, length: 1), .linkPunctuation) // ]
        if u.location - 1 >= 0 { add(NSRange(location: u.location - 1, length: 1), .linkPunctuation) } // (
        if NSMaxRange(m.range) - 1 >= 0 { add(NSRange(location: NSMaxRange(m.range) - 1, length: 1), .linkPunctuation) } // )
      }
      excluded.append(m.range)
    }
    for m in autoLinkRegex.matches(in: line, range: full) {
      if isExcluded(m.range) { continue }
      add(m.range(at: 1), .linkURL)
      add(NSRange(location: m.range.location, length: 1), .linkPunctuation) // <
      add(NSRange(location: NSMaxRange(m.range) - 1, length: 1), .linkPunctuation) // >
      excluded.append(m.range)
    }
    for m in referenceLinkRegex.matches(in: line, range: full) {
      if isExcluded(m.range) { continue }
      let t = m.range(at: 1)
      let id = m.range(at: 2)
      add(t, .linkText)
      add(id, .linkURL)
      add(NSRange(location: m.range.location, length: 1), .linkPunctuation) // [
      add(NSRange(location: t.location + t.length, length: 1), .linkPunctuation) // ]
      if id.location - 1 >= 0 { add(NSRange(location: id.location - 1, length: 1), .linkPunctuation) } // [
      add(NSRange(location: NSMaxRange(m.range) - 1, length: 1), .linkPunctuation) // ]
      excluded.append(m.range)
    }
    if let m = linkDefinitionRegex.firstMatch(in: line, range: full) {
      let label = m.range(at: 2)
      let colon = m.range(at: 3)
      let u = m.range(at: 4)
      add(label, .linkText)
      add(u, .linkURL)
      if label.location - 1 >= 0 { add(NSRange(location: label.location - 1, length: 1), .linkPunctuation) } // [
      add(NSRange(location: label.location + label.length, length: 1), .linkPunctuation) // ]
      add(colon, .linkPunctuation)
      excluded.append(m.range)
    }
    for m in bareURLRegex.matches(in: line, range: full) {
      if isExcluded(m.range) { continue }
      let trimmed = trimmedURLRange(m.range, in: lineNS)
      if trimmed.length > 0 {
        add(trimmed, .linkURL)
        excluded.append(trimmed)
      }
    }

    // Strong / emphasis / strike / highlight
    for m in strongRegex.matches(in: line, range: full) {
      if isExcluded(m.range) { continue }
      let marker = m.range(at: 1)
      let markerStr = lineNS.substring(with: marker)
      if !isWordishBoundarySafe(for: markerStr, matchRange: m.range) { continue }
      let body = m.range(at: 2)
      add(marker, .strongMarker)
      add(NSRange(location: NSMaxRange(m.range) - marker.length, length: marker.length), .strongMarker)
      add(body, .strongText)
      excluded.append(m.range)
    }
    for m in emphasisRegex.matches(in: line, range: full) {
      if isExcluded(m.range) { continue }
      let marker = m.range(at: 1)
      let markerStr = lineNS.substring(with: marker)
      if !isWordishBoundarySafe(for: markerStr, matchRange: m.range) { continue }
      let body = m.range(at: 2)
      add(marker, .emphasisMarker)
      add(NSRange(location: NSMaxRange(m.range) - marker.length, length: marker.length), .emphasisMarker)
      add(body, .emphasisText)
      excluded.append(m.range)
    }
    for m in strikeRegex.matches(in: line, range: full) {
      if isExcluded(m.range) { continue }
      add(NSRange(location: m.range.location, length: 2), .strikethroughMarker)
      add(NSRange(location: NSMaxRange(m.range) - 2, length: 2), .strikethroughMarker)
      add(m.range(at: 1), .strikethroughText)
      excluded.append(m.range)
    }
    for m in highlightRegex.matches(in: line, range: full) {
      if isExcluded(m.range) { continue }
      add(NSRange(location: m.range.location, length: 2), .highlightMarker)
      add(NSRange(location: NSMaxRange(m.range) - 2, length: 2), .highlightMarker)
      add(m.range(at: 1), .highlightText)
      excluded.append(m.range)
    }
  }

  private static func addTaskBoxIfPresent(lineNS: NSString, after start: Int, absLineRange: NSRange, out: inout [MarkdownHighlight]) {
    guard start >= 0, start < lineNS.length else { return }
    // Match exactly at `start`: `[ ]` or `[x]`.
    guard start + 2 < lineNS.length else { return }
    guard lineNS.character(at: start) == 0x5B /* [ */ else { return }
    guard lineNS.character(at: start + 2) == 0x5D /* ] */ else { return }
    let mid = lineNS.character(at: start + 1)
    let checked = (mid == 0x78 /* x */ || mid == 0x58 /* X */)
    let boxRange = NSRange(location: start, length: 3)
    out.append(MarkdownHighlight(
      range: NSRange(location: absLineRange.location + boxRange.location, length: boxRange.length),
      kind: .taskBox(checked: checked)
    ))
    // Emit taskText for the rest of the line after the box (+ optional space).
    var textStart = start + 3
    if textStart < lineNS.length, lineNS.character(at: textStart) == 0x20 /* space */ {
      textStart += 1
    }
    let lineEnd = absLineRange.length
    if textStart < lineEnd {
      out.append(MarkdownHighlight(
        range: NSRange(location: absLineRange.location + textStart, length: lineEnd - textStart),
        kind: .taskText(checked: checked)
      ))
    }
  }

  private static func trimmedURLRange(_ range: NSRange, in lineNS: NSString) -> NSRange {
    var trimmed = range
    while trimmed.length > 0 {
      let idx = trimmed.location + trimmed.length - 1
      let u = lineNS.character(at: idx)
      guard let s = UnicodeScalar(Int(u)), trailingURLPunctuation.contains(s) else { break }
      trimmed.length -= 1
    }
    return trimmed
  }
}
