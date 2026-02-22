import AppKit
import Foundation
import TurboDraftMarkdown

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

  var cacheEntryCount: Int { cacheOrder.count }
  var cacheCapacity: Int { cacheLimit }

  var theme: EditorColorTheme = .defaultTheme

  private(set) var baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  private var strongFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
  private var header1Font = NSFont.monospacedSystemFont(ofSize: 17, weight: .bold)
  private var header2Font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
  private var header3Font = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
  private var headerFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
  private var italicFont: NSFont
  private var strongItalicFont: NSFont

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

  func rebuildFonts(family: String, size: CGFloat) {
    let sz = max(9, min(size, 72))
    if family == "system" {
      baseFont = NSFont.monospacedSystemFont(ofSize: sz, weight: .regular)
      strongFont = NSFont.monospacedSystemFont(ofSize: sz, weight: .semibold)
    } else if let named = NSFont(name: family, size: sz) {
      baseFont = named
      let boldDesc = named.fontDescriptor.withSymbolicTraits(.bold)
      strongFont = NSFont(descriptor: boldDesc, size: sz) ?? named
    } else {
      baseFont = NSFont.monospacedSystemFont(ofSize: sz, weight: .regular)
      strongFont = NSFont.monospacedSystemFont(ofSize: sz, weight: .semibold)
    }

    header1Font = fontVariant(of: baseFont, size: sz + 4, weight: .bold)
    header2Font = fontVariant(of: baseFont, size: sz + 2, weight: .bold)
    header3Font = fontVariant(of: baseFont, size: sz + 1, weight: .semibold)
    headerFont = fontVariant(of: strongFont, size: sz, weight: .semibold)

    let italicTraits: NSFontDescriptor.SymbolicTraits = [.italic]
    let baseItalicDesc = baseFont.fontDescriptor.withSymbolicTraits(italicTraits)
    italicFont = NSFont(descriptor: baseItalicDesc, size: baseFont.pointSize) ?? baseFont

    let strongItalicDesc = strongFont.fontDescriptor.withSymbolicTraits(italicTraits)
    strongItalicFont = NSFont(descriptor: strongItalicDesc, size: strongFont.pointSize) ?? strongFont

    cache.removeAll()
    cacheOrder.removeAll()
  }

  private func fontVariant(of base: NSFont, size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let traits: NSFontDescriptor.SymbolicTraits = (weight == .bold || weight == .semibold) ? [.bold] : []
    let desc = base.fontDescriptor.withSymbolicTraits(traits)
    return NSFont(descriptor: desc, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
  }

  func setTheme(_ newTheme: EditorColorTheme) {
    theme = newTheme
    cache.removeAll()
    cacheOrder.removeAll()
  }

  func highlights(in text: String, range: NSRange) -> [Highlight] {
    let key = cacheKey(text: text, range: range)
    if let cached = cache[key] {
      return cached
    }

    var out: [Highlight] = []
    let spans = MarkdownHighlighter.highlights(in: text, range: range)
    let t = theme
    for span in spans {
      let attrs: [NSAttributedString.Key: Any]
      switch span.kind {
      case .codeFenceDelimiter:
        attrs = [.foregroundColor: t.marker]
      case .codeFenceInfo:
        attrs = [.foregroundColor: t.secondaryText]
      case .codeBlockLine:
        attrs = [
          .foregroundColor: t.code,
          .backgroundColor: t.codeBackground,
        ]
      case let .headerMarker(level):
        _ = level
        attrs = [.foregroundColor: t.marker]
      case let .headerText(level):
        let font: NSFont
        switch level {
        case 1: font = header1Font
        case 2: font = header2Font
        case 3: font = header3Font
        default: font = headerFont
        }
        attrs = [
          .foregroundColor: t.heading,
          .font: font,
        ]
      case .listMarker:
        attrs = [.foregroundColor: t.marker]
      case let .taskBox(checked):
        if checked {
          attrs = [.foregroundColor: t.link]
        } else {
          attrs = [.foregroundColor: t.marker]
        }
      case let .quoteMarker(level):
        _ = level
        attrs = [.foregroundColor: t.marker]
      case let .quoteText(level):
        _ = level
        attrs = [.foregroundColor: t.quote]
      case .horizontalRule:
        attrs = [.foregroundColor: t.marker]
      case .inlineCodeDelimiter:
        attrs = [.foregroundColor: t.marker]
      case .inlineCodeText:
        attrs = [
          .foregroundColor: t.code,
          .backgroundColor: t.inlineCodeBackground,
          .font: baseFont,
        ]
      case .strongMarker:
        attrs = [.foregroundColor: t.marker]
      case .strongText:
        attrs = [.foregroundColor: t.strong, .font: strongFont]
      case .emphasisMarker:
        attrs = [.foregroundColor: t.marker]
      case .emphasisText:
        attrs = [.foregroundColor: t.emphasis, .font: italicFont]
      case .strikethroughMarker:
        attrs = [.foregroundColor: t.marker]
      case .strikethroughText:
        attrs = [
          .foregroundColor: t.strikethrough,
          .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ]
      case .highlightMarker:
        attrs = [.foregroundColor: t.marker]
      case .highlightText:
        attrs = [
          .foregroundColor: t.foreground,
          .backgroundColor: t.highlight,
        ]
      case .linkText:
        attrs = [
          .foregroundColor: t.link,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
      case .linkURL:
        attrs = [
          .foregroundColor: t.link,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
      case .linkPunctuation:
        attrs = [.foregroundColor: t.marker]
      case .tablePipe:
        attrs = [.foregroundColor: t.marker]
      case .tableSeparator:
        attrs = [.foregroundColor: t.marker]
      case .tableHeaderText:
        attrs = [.foregroundColor: t.heading, .font: strongFont]
      case let .taskText(checked):
        if checked {
          attrs = [
            .foregroundColor: t.strikethrough,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
          ]
        } else {
          attrs = [:]
        }
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

    return CacheKey(
      rangeLocation: safe.location,
      rangeLength: safe.length,
      textHash: hashUTF16(in: ns, range: safe)
    )
  }

  private func hashUTF16(in ns: NSString, range: NSRange) -> Int {
    var hasher = Hasher()
    var cursor = range.location
    let end = range.location + range.length
    var buffer = [unichar](repeating: 0, count: 1024)
    while cursor < end {
      let chunkLen = min(buffer.count, end - cursor)
      let chunkRange = NSRange(location: cursor, length: chunkLen)
      ns.getCharacters(&buffer, range: chunkRange)
      for i in 0..<chunkLen {
        hasher.combine(buffer[i])
      }
      cursor += chunkLen
    }
    return hasher.finalize()
  }
}
