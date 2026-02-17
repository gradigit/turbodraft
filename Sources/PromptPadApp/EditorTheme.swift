import AppKit

enum EditorTheme {
  static let editorBackground: NSColor = NSColor(name: nil) { appearance in
    switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
    case .darkAqua:
      // Charcoal (not pure black) for comfortable long-form editing.
      return NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)
    default:
      // Paper white with a slight warmth to reduce glare.
      return NSColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1.0)
    }
  }

  static let primaryText: NSColor = NSColor.labelColor
  static let secondaryText: NSColor = NSColor.secondaryLabelColor
  static let markerText: NSColor = NSColor.tertiaryLabelColor
  static let caret: NSColor = NSColor.labelColor

  static let codeBlockBackground: NSColor = NSColor(name: nil) { appearance in
    switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
    case .darkAqua:
      return NSColor(srgbRed: 0.11, green: 0.13, blue: 0.18, alpha: 1.0)
    default:
      return NSColor(srgbRed: 0.94, green: 0.94, blue: 0.91, alpha: 1.0)
    }
  }

  static let inlineCodeBackground: NSColor = NSColor(name: nil) { appearance in
    switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
    case .darkAqua:
      return NSColor(srgbRed: 0.14, green: 0.16, blue: 0.22, alpha: 1.0)
    default:
      return NSColor(srgbRed: 0.92, green: 0.92, blue: 0.89, alpha: 1.0)
    }
  }

  static let bannerBackground: NSColor = NSColor(name: nil) { appearance in
    switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
    case .darkAqua:
      return NSColor(srgbRed: 0.12, green: 0.13, blue: 0.17, alpha: 0.92)
    default:
      return NSColor(srgbRed: 0.96, green: 0.96, blue: 0.94, alpha: 0.92)
    }
  }

  static let highlightBackground: NSColor = NSColor(name: nil) { appearance in
    switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
    case .darkAqua:
      return NSColor(srgbRed: 0.55, green: 0.45, blue: 0.12, alpha: 0.35)
    default:
      return NSColor(srgbRed: 0.98, green: 0.86, blue: 0.25, alpha: 0.55)
    }
  }
}
