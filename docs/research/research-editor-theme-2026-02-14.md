# Research: Light/Dark theme and “best-looking” minimal editor UI (PromptPad)
Date: 2026-02-14
Depth: Full

## Executive Summary
For a super-minimal macOS editor, the most reliable way to look “native” and stay accessible is to:

- Prefer system semantic colors for hierarchy and selection where possible (they adapt to Dark Mode and accessibility settings).
- If you want a distinctive look, keep it to a tiny custom palette (background surface + a few accents) implemented as dynamic `NSColor` variants.
- Maintain strong contrast in both light and dark, and test with Increase Contrast.
- If you use Core Animation `CGColor` (layer backgrounds), you must update it on appearance changes; dynamic colors are otherwise resolved at draw time.

This points to a default theme that follows system appearance, with optional config override (system/light/dark), similar to how mature macOS editors handle it.

## Sub-Questions Investigated
1. What do Apple’s guidelines say about Dark Mode, contrast, and color choice?
2. What patterns keep a text editor looking good in both appearances while remaining fast?
3. How should a “theme override” interact with system appearance?
4. What are common implementation pitfalls (dynamic colors, attributed strings, CGColor)?

## Hypothesis Tracking
| Hypothesis | Confidence | Supporting Evidence | Contradicting Evidence |
|---|---|---|---|
| H1: Use only system semantic colors (e.g., `labelColor`, `textBackgroundColor`, `selectedTextBackgroundColor`) | High | Apple recommends system-defined colors; they adapt to Dark Mode and accessibility. | Can look generic; less “designed” without small palette decisions. |
| H2: Use a small custom background palette implemented as dynamic colors + keep system selection/accent | High | Apple guidance on contrast + dynamic colors; avoids hard-coded static colors; respects user accent/highlight; common in mature editors. | Must be careful to keep contrast high and update CGColors. |
| H3: Use translucency/materials (NSVisualEffectView) for “premium” look | Medium | Apple’s system uses materials; can look great. | Reduce Transparency and contrast concerns; potential readability issues in an editor; more moving parts than needed. |

**Chosen approach:** H2.

## Detailed Findings

### 1) Contrast and accessibility are non-negotiable
Apple explicitly calls out minimum contrast ratios and recommends checking contrast in both light and dark appearances, including with Increase Contrast enabled. A common failure mode is low-contrast gray-on-black in dark mode. 

Practical implication for PromptPad:
- Don’t ship a low-contrast “pretty” theme as default.
- Keep primary text high-contrast against background, and use a muted color only for non-content affordances.

### 2) Prefer system-defined colors for selection and hierarchy
System-defined semantic colors adapt to appearance and accessibility settings, and the system provides multiple “label” strengths (primary/secondary/tertiary/quaternary) for hierarchy.

Practical implication:
- Use system selection background (and avoid hardcoding selection tints).
- Use semantic label strengths for markdown markers and secondary UI.

### 3) Dynamic colors: resolved at draw time, but CGColor is a trap
WWDC guidance for Dark Mode emphasizes dynamic colors; NSColor resolves dynamic values at draw time. However, when you bridge to `CGColor` (for CALayer), you can’t expect automatic updates and may need to refresh when appearance changes.

Practical implication:
- Use `NSColor` for view/control properties wherever possible.
- If you set `layer.backgroundColor`, update it in `viewDidChangeEffectiveAppearance`.

### 4) Theme override is a normal feature for text editors
Mature editors support an appearance override independent of system appearance. CotEditor is a concrete example: it added an “Appearance” option to force document window appearance, and later refined selection background behavior when editor appearance differs from the system.

Practical implication:
- Provide config `theme: system|light|dark`.
- When forced, set the window appearance accordingly.

## Recommendations
1. Add config `theme: system|light|dark` with default `system`.
2. Implement a small custom palette (paper light + charcoal dark) as dynamic `NSColor` values.
3. Keep selection/highlight using system colors to respect user preferences.
4. Update any `CGColor` layer backgrounds on appearance changes.

## Sources
| Source | URL | Quality | Accessed | Notes |
|---|---|---:|---:|---|
| Apple HIG: Accessibility (contrast + prefer system-defined colors) | https://developer.apple.com/design/human-interface-guidelines/accessibility | High | 2026-02-14 | Contrast ratios and recommendation to prefer system-defined colors |
| Apple: Sufficient Contrast evaluation criteria | https://developer.apple.com/help/app-store-connect/manage-app-accessibility/sufficient-contrast-evaluation-criteria | High | 2026-02-14 | Reinforces 4.5:1 guidance; warns about dark-mode contrast mistakes |
| Apple: Dark Interface evaluation criteria | https://developer.apple.com/help/app-store-connect/manage-app-accessibility/dark-interface-evaluation-criteria/ | High | 2026-02-14 | Mentions supporting system dark mode and expectations around in-app settings |
| Apple UI Design Tips (contrast, text size) | https://developer.apple.com/design/tips/ | High | 2026-02-14 | General guidance on readability and contrast |
| WWDC 2018: Introducing Dark Mode (NSColor dynamic resolution) | https://nonstrict.eu/wwdcindex/wwdc2018/210/ | Medium | 2026-02-14 | Transcript covering NSColor dynamic system colors and draw-time resolution |
| WWDC 2019: Implementing Dark Mode on iOS (dynamic color model; notes CGColor pitfalls) | https://developer.apple.com/videos/play/wwdc2019/214/ | High | 2026-02-14 | Dynamic colors, attributed strings, CGColor caveats |
| Vincent Tourraine notes on WWDC 2019 Dark Mode | https://www.vtourraine.net/blog/2019/wwdc-2019-dark-mode-ios | Medium | 2026-02-14 | Highlights dynamic colors and the “CGColor needs manual update” pitfall |
| Jesse Squires: Creating dynamic colors (notes NSColor dynamic provider) | https://www.jessesquires.com/blog/2023/07/11/creating-dynamic-colors-in-swiftui/ | High | 2026-02-14 | Practical discussion of dynamic colors in AppKit/UIKit |
| CotEditor release notes (appearance override) | https://coteditor.com/releasenotes/3.8.0.en | High | 2026-02-14 | Adds appearance option independent of system |
| CotEditor release notes (selection background behavior) | https://coteditor.com/releasenotes/4.8.3.en | High | 2026-02-14 | Notes selection background correctness when system/theme differ |
