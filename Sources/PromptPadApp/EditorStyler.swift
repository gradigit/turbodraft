import AppKit
import Foundation
import PromptPadMarkdown

struct Highlight {
  var range: NSRange
  var attributes: [NSAttributedString.Key: Any]
}

final class MarkdownStyler {
  private struct CacheKey: Hashable {
    var rangeLocation: Int
    var rangeLength: Int
    var textHash: Int
  }

  private var cache: [CacheKey: [Highlight]] = [:]
  private var cacheOrder: [CacheKey] = []
  private let cacheLimit = 512

  private let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  private let strongFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
  private let header1Font = NSFont.monospacedSystemFont(ofSize: 17, weight: .bold)
  private let header2Font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
  private let header3Font = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
  private let headerFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
  private let italicFont: NSFont
  private let strongItalicFont: NSFont

  init() {
    let italicTraits: NSFontDescriptor.SymbolicTraits = [.italic]
    let baseItalicDesc = baseFont.fontDescriptor.withSymbolicTraits(italicTraits)
    if let f = NSFont(descriptor: baseItalicDesc, size: baseFont.pointSize) {
      italicFont = f
    } else {
      italicFont = baseFont
    }

    let strongItalicDesc = strongFont.fontDescriptor.withSymbolicTraits(italicTraits)
    if let f = NSFont(descriptor: strongItalicDesc, size: strongFont.pointSize) {
      strongItalicFont = f
    } else {
      strongItalicFont = strongFont
    }
  }

  func highlights(in text: String, range: NSRange) -> [Highlight] {
    let key = cacheKey(text: text, range: range)
    if let cached = cache[key] {
      return cached
    }

    var out: [Highlight] = []
    let spans = MarkdownHighlighter.highlights(in: text, range: range)
    for span in spans {
      let attrs: [NSAttributedString.Key: Any]
      switch span.kind {
      case .codeFenceDelimiter:
        attrs = [.foregroundColor: EditorTheme.markerText]
      case .codeFenceInfo:
        attrs = [.foregroundColor: EditorTheme.secondaryText]
      case .codeBlockLine:
        attrs = [
          .foregroundColor: EditorTheme.primaryText,
          .backgroundColor: EditorTheme.codeBlockBackground,
        ]
      case let .headerMarker(level):
        _ = level
        attrs = [.foregroundColor: EditorTheme.markerText]
      case let .headerText(level):
        let font: NSFont
        switch level {
        case 1: font = header1Font
        case 2: font = header2Font
        case 3: font = header3Font
        default: font = headerFont
        }
        attrs = [
          .foregroundColor: EditorTheme.primaryText,
          .font: font,
        ]
      case .listMarker:
        attrs = [.foregroundColor: EditorTheme.markerText]
      case let .taskBox(checked):
        if checked {
          attrs = [.foregroundColor: NSColor.controlAccentColor]
        } else {
          attrs = [.foregroundColor: EditorTheme.markerText]
        }
      case let .quoteMarker(level):
        _ = level
        attrs = [.foregroundColor: EditorTheme.markerText]
      case let .quoteText(level):
        _ = level
        attrs = [.foregroundColor: EditorTheme.secondaryText]
      case .horizontalRule:
        attrs = [.foregroundColor: EditorTheme.markerText]
      case .inlineCodeDelimiter:
        attrs = [.foregroundColor: EditorTheme.markerText]
      case .inlineCodeText:
        attrs = [
          .foregroundColor: EditorTheme.primaryText,
          .backgroundColor: EditorTheme.inlineCodeBackground,
          .font: baseFont,
        ]
      case .strongMarker:
        attrs = [.foregroundColor: EditorTheme.markerText]
      case .strongText:
        attrs = [.font: strongFont]
      case .emphasisMarker:
        attrs = [.foregroundColor: EditorTheme.markerText]
      case .emphasisText:
        attrs = [.font: italicFont]
      case .strikethroughMarker:
        attrs = [.foregroundColor: EditorTheme.markerText]
      case .strikethroughText:
        attrs = [
          .foregroundColor: EditorTheme.secondaryText,
          .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ]
      case .highlightMarker:
        attrs = [.foregroundColor: EditorTheme.markerText]
      case .highlightText:
        attrs = [
          .foregroundColor: EditorTheme.primaryText,
          .backgroundColor: EditorTheme.highlightBackground,
        ]
      case .linkText:
        attrs = [
          .foregroundColor: NSColor.linkColor,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
      case .linkURL:
        attrs = [
          .foregroundColor: NSColor.linkColor,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
      case .linkPunctuation:
        attrs = [.foregroundColor: EditorTheme.markerText]
      }
      out.append(Highlight(range: span.range, attributes: attrs))
    }

    cache[key] = out
    cacheOrder.append(key)
    // O(n) FIFO eviction is fine here — cacheLimit is small (512) and this runs
    // at most once per highlight pass, removing only a handful of entries.
    if cacheOrder.count > cacheLimit {
      let removeCount = cacheOrder.count - cacheLimit
      for _ in 0..<removeCount {
        let victim = cacheOrder.removeFirst()
        cache.removeValue(forKey: victim)
      }
    }

    return out
  }

  private func cacheKey(text: String, range: NSRange) -> CacheKey {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    let safe = NSIntersectionRange(range, full)
    if safe.length <= 0 {
      return CacheKey(rangeLocation: 0, rangeLength: 0, textHash: 0)
    }

    let slice = ns.substring(with: safe)
    var hasher = Hasher()
    hasher.combine(slice)
    return CacheKey(
      rangeLocation: safe.location,
      rangeLength: safe.length,
      textHash: hasher.finalize()
    )
  }
}
