import AppKit
import Foundation
import TurboDraftConfig

struct EditorColorTheme {
  let id: String
  let displayName: String
  let isDark: Bool
  let background: NSColor
  let foreground: NSColor
  let caret: NSColor
  let heading: NSColor
  let marker: NSColor
  let code: NSColor
  let codeBackground: NSColor
  let inlineCodeBackground: NSColor
  let link: NSColor
  let emphasis: NSColor
  let strong: NSColor
  let strikethrough: NSColor
  let quote: NSColor
  let highlight: NSColor
  let banner: NSColor
  let secondaryText: NSColor

  // MARK: - Default (appearance-adaptive)

  static let defaultTheme = EditorColorTheme(
    id: "default",
    displayName: "Default",
    isDark: false,  // ignored for default — follows system
    background: EditorTheme.editorBackground,
    foreground: EditorTheme.primaryText,
    caret: EditorTheme.caret,
    heading: EditorTheme.primaryText,
    marker: EditorTheme.markerText,
    code: EditorTheme.primaryText,
    codeBackground: EditorTheme.codeBlockBackground,
    inlineCodeBackground: EditorTheme.inlineCodeBackground,
    link: NSColor.linkColor,
    emphasis: EditorTheme.primaryText,
    strong: EditorTheme.primaryText,
    strikethrough: EditorTheme.secondaryText,
    quote: EditorTheme.primaryText,
    highlight: EditorTheme.highlightBackground,
    banner: EditorTheme.bannerBackground,
    secondaryText: EditorTheme.secondaryText
  )

  // MARK: - TurboDraft Dark (main default)

  static let turbodraftDark = EditorColorTheme(
    id: "turbodraft-dark", displayName: "TurboDraft Dark", isDark: true,
    background: hex("1d1f21"), foreground: hex("c5c9c6"), caret: hex("60a5fa"),
    heading: hex("e0e2e0"), marker: hex("454749"), code: hex("c5c9c6"),
    codeBackground: hex("222425"), inlineCodeBackground: hex("272829"),
    link: hex("60a5fa"), emphasis: hex("c5c9c6"), strong: hex("e0e2e0"),
    strikethrough: hex("5a5c5e"), quote: hex("8a8d8a"),
    highlight: hexA("60a5fa", 0.12), banner: hexA("222425", 0.93),
    secondaryText: hex("707272")
  )

  // MARK: - TurboDraft Light

  static let turbodraftLight = EditorColorTheme(
    id: "turbodraft-light", displayName: "TurboDraft Light", isDark: false,
    background: hex("f5f6f6"), foreground: hex("424242"), caret: hex("1088c8"),
    heading: hex("1a1a1a"), marker: hex("c4c6c8"), code: hex("424242"),
    codeBackground: hex("eaecec"), inlineCodeBackground: hex("e4e6e6"),
    link: hex("1088c8"), emphasis: hex("424242"), strong: hex("1a1a1a"),
    strikethrough: hex("a0a2a4"), quote: hex("686a6c"),
    highlight: hexA("1088c8", 0.10), banner: hexA("eaecec", 0.93),
    secondaryText: hex("888a8c")
  )

  // MARK: - TurboDraft Ice

  static let turbodraftIce = EditorColorTheme(
    id: "turbodraft-ice", displayName: "TurboDraft Ice", isDark: true,
    background: hex("09090b"), foreground: hex("e4e6ea"), caret: hex("93c5fd"),
    heading: hex("93c5fd"), marker: hex("27272a"), code: hex("7dd3fc"),
    codeBackground: hex("050507"), inlineCodeBackground: hex("111114"),
    link: hex("60a5fa"), emphasis: hex("e4e6ea"), strong: hex("f4f4f5"),
    strikethrough: hex("3f3f46"), quote: hex("8a8a94"),
    highlight: hexA("60a5fa", 0.15), banner: hexA("050507", 0.93),
    secondaryText: hex("52525b")
  )

  // MARK: - Community Dark Themes

  static let oneDark = EditorColorTheme(
    id: "one-dark", displayName: "One Dark", isDark: true,
    background: hex("282c34"), foreground: hex("abb2bf"), caret: hex("528bff"),
    heading: hex("e5c07b"), marker: hex("5c6370"), code: hex("98c379"),
    codeBackground: hex("21252b"), inlineCodeBackground: hex("2c313a"),
    link: hex("61afef"), emphasis: hex("abb2bf"), strong: hex("abb2bf"),
    strikethrough: hex("5c6370"), quote: hex("8b929e"),
    highlight: hexA("e5c07b", 0.25), banner: hexA("21252b", 0.92),
    secondaryText: hex("8b929e")
  )

  static let githubDark = EditorColorTheme(
    id: "github-dark", displayName: "GitHub Dark", isDark: true,
    background: hex("0d1117"), foreground: hex("c9d1d9"), caret: hex("58a6ff"),
    heading: hex("58a6ff"), marker: hex("484f58"), code: hex("a5d6ff"),
    codeBackground: hex("161b22"), inlineCodeBackground: hex("1f262d"),
    link: hex("58a6ff"), emphasis: hex("c9d1d9"), strong: hex("c9d1d9"),
    strikethrough: hex("484f58"), quote: hex("8b949e"),
    highlight: hexA("e3b341", 0.25), banner: hexA("161b22", 0.92),
    secondaryText: hex("8b949e")
  )

  static let catppuccinMocha = EditorColorTheme(
    id: "catppuccin-mocha", displayName: "Catppuccin Mocha", isDark: true,
    background: hex("1e1e2e"), foreground: hex("cdd6f4"), caret: hex("f5e0dc"),
    heading: hex("89b4fa"), marker: hex("6c7086"), code: hex("a6e3a1"),
    codeBackground: hex("181825"), inlineCodeBackground: hex("313244"),
    link: hex("89b4fa"), emphasis: hex("cdd6f4"), strong: hex("cdd6f4"),
    strikethrough: hex("6c7086"), quote: hex("a6adc8"),
    highlight: hexA("f9e2af", 0.25), banner: hexA("181825", 0.92),
    secondaryText: hex("a6adc8")
  )

  static let dracula = EditorColorTheme(
    id: "dracula", displayName: "Dracula", isDark: true,
    background: hex("282a36"), foreground: hex("f8f8f2"), caret: hex("f8f8f2"),
    heading: hex("bd93f9"), marker: hex("6272a4"), code: hex("50fa7b"),
    codeBackground: hex("21222c"), inlineCodeBackground: hex("343746"),
    link: hex("8be9fd"), emphasis: hex("f8f8f2"), strong: hex("f8f8f2"),
    strikethrough: hex("6272a4"), quote: hex("b4b7c9"),
    highlight: hexA("f1fa8c", 0.25), banner: hexA("21222c", 0.92),
    secondaryText: hex("b4b7c9")
  )

  static let nord = EditorColorTheme(
    id: "nord", displayName: "Nord", isDark: true,
    background: hex("2e3440"), foreground: hex("d8dee9"), caret: hex("d8dee9"),
    heading: hex("88c0d0"), marker: hex("616e88"), code: hex("a3be8c"),
    codeBackground: hex("272c36"), inlineCodeBackground: hex("3b4252"),
    link: hex("81a1c1"), emphasis: hex("d8dee9"), strong: hex("d8dee9"),
    strikethrough: hex("616e88"), quote: hex("a1aab8"),
    highlight: hexA("ebcb8b", 0.25), banner: hexA("272c36", 0.92),
    secondaryText: hex("a1aab8")
  )

  static let tokyoNight = EditorColorTheme(
    id: "tokyo-night", displayName: "Tokyo Night", isDark: true,
    background: hex("1a1b26"), foreground: hex("a9b1d6"), caret: hex("c0caf5"),
    heading: hex("7aa2f7"), marker: hex("565f89"), code: hex("9ece6a"),
    codeBackground: hex("16161e"), inlineCodeBackground: hex("232433"),
    link: hex("7dcfff"), emphasis: hex("a9b1d6"), strong: hex("a9b1d6"),
    strikethrough: hex("565f89"), quote: hex("9099b7"),
    highlight: hexA("e0af68", 0.25), banner: hexA("16161e", 0.92),
    secondaryText: hex("9099b7")
  )

  static let rosePine = EditorColorTheme(
    id: "rose-pine", displayName: "Rose Pine", isDark: true,
    background: hex("191724"), foreground: hex("e0def4"), caret: hex("e0def4"),
    heading: hex("c4a7e7"), marker: hex("6e6a86"), code: hex("9ccfd8"),
    codeBackground: hex("1f1d2e"), inlineCodeBackground: hex("26233a"),
    link: hex("ebbcba"), emphasis: hex("e0def4"), strong: hex("e0def4"),
    strikethrough: hex("6e6a86"), quote: hex("b4b1cc"),
    highlight: hexA("f6c177", 0.25), banner: hexA("1f1d2e", 0.92),
    secondaryText: hex("b4b1cc")
  )

  static let gruvboxDark = EditorColorTheme(
    id: "gruvbox-dark", displayName: "Gruvbox Dark", isDark: true,
    background: hex("282828"), foreground: hex("ebdbb2"), caret: hex("ebdbb2"),
    heading: hex("fabd2f"), marker: hex("7c6f64"), code: hex("b8bb26"),
    codeBackground: hex("1d2021"), inlineCodeBackground: hex("3c3836"),
    link: hex("83a598"), emphasis: hex("ebdbb2"), strong: hex("ebdbb2"),
    strikethrough: hex("7c6f64"), quote: hex("bdae93"),
    highlight: hexA("fabd2f", 0.25), banner: hexA("1d2021", 0.92),
    secondaryText: hex("bdae93")
  )

  static let monokaiPro = EditorColorTheme(
    id: "monokai-pro", displayName: "Monokai Pro", isDark: true,
    background: hex("2d2a2e"), foreground: hex("fcfcfa"), caret: hex("fcfcfa"),
    heading: hex("ffd866"), marker: hex("727072"), code: hex("a9dc76"),
    codeBackground: hex("221f22"), inlineCodeBackground: hex("3a373b"),
    link: hex("78dce8"), emphasis: hex("fcfcfa"), strong: hex("fcfcfa"),
    strikethrough: hex("727072"), quote: hex("c1c0c0"),
    highlight: hexA("ffd866", 0.25), banner: hexA("221f22", 0.92),
    secondaryText: hex("c1c0c0")
  )

  static let solarizedDark = EditorColorTheme(
    id: "solarized-dark", displayName: "Solarized Dark", isDark: true,
    background: hex("002b36"), foreground: hex("839496"), caret: hex("839496"),
    heading: hex("b58900"), marker: hex("586e75"), code: hex("859900"),
    codeBackground: hex("073642"), inlineCodeBackground: hex("0a4050"),
    link: hex("268bd2"), emphasis: hex("839496"), strong: hex("839496"),
    strikethrough: hex("586e75"), quote: hex("93a1a1"),
    highlight: hexA("b58900", 0.25), banner: hexA("073642", 0.92),
    secondaryText: hex("93a1a1")
  )

  static let materialDark = EditorColorTheme(
    id: "material-dark", displayName: "Material Dark", isDark: true,
    background: hex("212121"), foreground: hex("eeffff"), caret: hex("ffcc00"),
    heading: hex("c792ea"), marker: hex("545454"), code: hex("c3e88d"),
    codeBackground: hex("1a1a1a"), inlineCodeBackground: hex("2c2c2c"),
    link: hex("82aaff"), emphasis: hex("eeffff"), strong: hex("eeffff"),
    strikethrough: hex("545454"), quote: hex("b0bec5"),
    highlight: hexA("ffcb6b", 0.25), banner: hexA("1a1a1a", 0.92),
    secondaryText: hex("b0bec5")
  )

  static let vscodeDarkPlus = EditorColorTheme(
    id: "vscode-dark-plus", displayName: "VS Code Dark+", isDark: true,
    background: hex("1e1e1e"), foreground: hex("d4d4d4"), caret: hex("aeafad"),
    heading: hex("569cd6"), marker: hex("808080"), code: hex("ce9178"),
    codeBackground: hex("1a1a1a"), inlineCodeBackground: hex("2d2d2d"),
    link: hex("4ec9b0"), emphasis: hex("d4d4d4"), strong: hex("d4d4d4"),
    strikethrough: hex("808080"), quote: hex("9e9e9e"),
    highlight: hexA("dcdcaa", 0.25), banner: hexA("1a1a1a", 0.92),
    secondaryText: hex("9e9e9e")
  )

  static let sublimeMariana = EditorColorTheme(
    id: "sublime-mariana", displayName: "Sublime Mariana", isDark: true,
    background: hex("303841"), foreground: hex("d8dee9"), caret: hex("f8f8f0"),
    heading: hex("ee932b"), marker: hex("6d7a8a"), code: hex("99c794"),
    codeBackground: hex("272d35"), inlineCodeBackground: hex("3c444e"),
    link: hex("6699cc"), emphasis: hex("d8dee9"), strong: hex("d8dee9"),
    strikethrough: hex("6d7a8a"), quote: hex("a6acb5"),
    highlight: hexA("fac761", 0.25), banner: hexA("272d35", 0.92),
    secondaryText: hex("a6acb5")
  )

  // MARK: - Community Light Themes

  static let githubLight = EditorColorTheme(
    id: "github-light", displayName: "GitHub Light", isDark: false,
    background: hex("ffffff"), foreground: hex("24292f"), caret: hex("24292f"),
    heading: hex("0550ae"), marker: hex("8b949e"), code: hex("0a3069"),
    codeBackground: hex("f6f8fa"), inlineCodeBackground: hex("eff1f3"),
    link: hex("0969da"), emphasis: hex("24292f"), strong: hex("24292f"),
    strikethrough: hex("8b949e"), quote: hex("57606a"),
    highlight: hexA("fff8c5", 0.80), banner: hexA("f6f8fa", 0.92),
    secondaryText: hex("57606a")
  )

  static let catppuccinLatte = EditorColorTheme(
    id: "catppuccin-latte", displayName: "Catppuccin Latte", isDark: false,
    background: hex("eff1f5"), foreground: hex("4c4f69"), caret: hex("dc8a78"),
    heading: hex("1e66f5"), marker: hex("9ca0b0"), code: hex("40a02b"),
    codeBackground: hex("e6e9ef"), inlineCodeBackground: hex("dce0e8"),
    link: hex("1e66f5"), emphasis: hex("4c4f69"), strong: hex("4c4f69"),
    strikethrough: hex("9ca0b0"), quote: hex("6c6f85"),
    highlight: hexA("df8e1d", 0.20), banner: hexA("e6e9ef", 0.92),
    secondaryText: hex("6c6f85")
  )

  static let solarizedLight = EditorColorTheme(
    id: "solarized-light", displayName: "Solarized Light", isDark: false,
    background: hex("fdf6e3"), foreground: hex("657b83"), caret: hex("657b83"),
    heading: hex("b58900"), marker: hex("93a1a1"), code: hex("859900"),
    codeBackground: hex("eee8d5"), inlineCodeBackground: hex("e8e1ca"),
    link: hex("268bd2"), emphasis: hex("657b83"), strong: hex("657b83"),
    strikethrough: hex("93a1a1"), quote: hex("586e75"),
    highlight: hexA("b58900", 0.20), banner: hexA("eee8d5", 0.92),
    secondaryText: hex("586e75")
  )

  static let gruvboxLight = EditorColorTheme(
    id: "gruvbox-light", displayName: "Gruvbox Light", isDark: false,
    background: hex("fbf1c7"), foreground: hex("3c3836"), caret: hex("3c3836"),
    heading: hex("d79921"), marker: hex("928374"), code: hex("79740e"),
    codeBackground: hex("f2e5bc"), inlineCodeBackground: hex("ebdbb2"),
    link: hex("458588"), emphasis: hex("3c3836"), strong: hex("3c3836"),
    strikethrough: hex("928374"), quote: hex("504945"),
    highlight: hexA("d79921", 0.20), banner: hexA("f2e5bc", 0.92),
    secondaryText: hex("504945")
  )

  // MARK: - Theme Registry

  static let builtInThemes: [EditorColorTheme] = [
    defaultTheme,
    // TurboDraft
    turbodraftDark, turbodraftLight, turbodraftIce,
    // Community Dark
    oneDark, githubDark, catppuccinMocha, dracula, nord, tokyoNight,
    rosePine, gruvboxDark, monokaiPro, solarizedDark, materialDark,
    vscodeDarkPlus, sublimeMariana,
    // Community Light
    githubLight, catppuccinLatte, solarizedLight, gruvboxLight,
  ]

  static func loadCustomThemes() -> [EditorColorTheme] {
    let dir = TurboDraftPaths.themesDir()
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: nil
    ) else { return [] }

    return files
      .filter { $0.pathExtension.lowercased() == "json" }
      .compactMap { url -> EditorColorTheme? in
        guard let data = try? Data(contentsOf: url),
              let def = try? JSONDecoder().decode(EditorColorThemeDefinition.self, from: data)
        else { return nil }
        return def.toTheme()
      }
  }

  static func allThemes() -> [EditorColorTheme] {
    var themes = builtInThemes
    themes.append(contentsOf: loadCustomThemes())
    return themes
  }

  static func resolve(id: String, from themes: [EditorColorTheme]) -> EditorColorTheme {
    themes.first { $0.id == id } ?? defaultTheme
  }

  // MARK: - Hex Helpers

  private static func hex(_ hex: String) -> NSColor {
    colorFromHex(hex) ?? .white
  }

  private static func hexA(_ hex: String, _ alpha: CGFloat) -> NSColor {
    (colorFromHex(hex) ?? .white).withAlphaComponent(alpha)
  }

  static func colorFromHex(_ hex: String) -> NSColor? {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }

    let scanner = Scanner(string: s)
    var value: UInt64 = 0
    guard scanner.scanHexInt64(&value) else { return nil }

    switch s.count {
    case 6:
      let r = CGFloat((value >> 16) & 0xFF) / 255.0
      let g = CGFloat((value >> 8) & 0xFF) / 255.0
      let b = CGFloat(value & 0xFF) / 255.0
      return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    case 8:
      let r = CGFloat((value >> 24) & 0xFF) / 255.0
      let g = CGFloat((value >> 16) & 0xFF) / 255.0
      let b = CGFloat((value >> 8) & 0xFF) / 255.0
      let a = CGFloat(value & 0xFF) / 255.0
      return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    default:
      return nil
    }
  }
}

// MARK: - JSON Definition (Codable)

struct EditorColorThemeDefinition: Codable {
  var id: String
  var displayName: String
  var isDark: Bool
  var background: String
  var foreground: String
  var caret: String?
  var heading: String?
  var marker: String?
  var code: String?
  var codeBackground: String?
  var inlineCodeBackground: String?
  var link: String?
  var emphasis: String?
  var strong: String?
  var strikethrough: String?
  var quote: String?
  var highlight: String?
  var banner: String?
  var secondaryText: String?

  func toTheme() -> EditorColorTheme? {
    guard let bg = EditorColorTheme.colorFromHex(background),
          let fg = EditorColorTheme.colorFromHex(foreground)
    else { return nil }

    func opt(_ hex: String?, fallback: NSColor) -> NSColor {
      guard let hex, let c = EditorColorTheme.colorFromHex(hex) else { return fallback }
      return c
    }

    // Derive a muted foreground for marker/secondary if not specified.
    let muted = fg.withAlphaComponent(0.5)

    return EditorColorTheme(
      id: id,
      displayName: displayName,
      isDark: isDark,
      background: bg,
      foreground: fg,
      caret: opt(caret, fallback: fg),
      heading: opt(heading, fallback: fg),
      marker: opt(marker, fallback: muted),
      code: opt(code, fallback: fg),
      codeBackground: opt(codeBackground, fallback: bg.blended(withFraction: 0.05, of: fg) ?? bg),
      inlineCodeBackground: opt(inlineCodeBackground, fallback: bg.blended(withFraction: 0.08, of: fg) ?? bg),
      link: opt(link, fallback: NSColor.linkColor),
      emphasis: opt(emphasis, fallback: fg),
      strong: opt(strong, fallback: fg),
      strikethrough: opt(strikethrough, fallback: muted),
      quote: opt(quote, fallback: fg.withAlphaComponent(0.7)),
      highlight: opt(highlight, fallback: NSColor(srgbRed: 1, green: 0.9, blue: 0.4, alpha: 0.25)),
      banner: opt(banner, fallback: bg.withAlphaComponent(0.92)),
      secondaryText: opt(secondaryText, fallback: muted)
    )
  }
}
