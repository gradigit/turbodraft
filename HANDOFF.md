# Context Handoff — 2026-02-20

Session summary for context continuity after clearing.

## First Steps (Read in Order)

1. Read CLAUDE.md — project conventions, build/install rule, architecture, gotchas
2. Read this file's session summary and deferred work

After reading these files, you'll have full context to continue.

## Session Summary

### What Was Done

**Added iA Writer-inspired themes, font settings, and fixed styling bug** (commit 260f167)

1. **3 TurboDraft themes** — Dark (monochrome + `#60a5fa` blue accent), Light (off-white + `#1088c8` blue), Ice (near-black + ice blue) — all inspired by iA Writer's monochrome aesthetic
2. **Kept all 17 community themes** — originally removed them by mistake, restored alongside the 3 new themes
3. **EditorColorTheme system** — new file with built-in themes + custom JSON theme loading from `~/Library/Application Support/TurboDraft/themes/`
4. **Font settings** — configurable font size (11-20pt) and family (System Mono, Menlo, SF Mono, JetBrains Mono, Fira Code) via View menu
5. **Dynamic font rebuilding** — `EditorStyler.rebuildFonts(family:size:)` reconstructs all 8 font variants, clears LRU cache
6. **Task checkbox strikethrough** — `taskText(checked: Bool)` token in MarkdownHighlighter; checked items get dimmed + struck
7. **Save status moved to top-left** — floating overlay at top-left of editor instead of bottom bar, themed with secondaryText
8. **Fixed typing attributes corruption** — `NSTextView.textColor` reflects text storage attributes, so our highlight colors (marker, heading) fed back into `baseAttrs` creating a permanent color feedback loop. Fix: use `colorTheme.foreground` directly in `applyStyling`.
9. **TurboDraftConfig additions** — `fontSize` (default 13), `fontFamily` (default "system"), `colorTheme` default changed to "turbodraft-dark"

### Current State
- All 77 tests pass on main
- Commit 260f167 pushed to origin/main
- LaunchAgent running latest binary

### What's Next (Deferred Work)

| Issue | Reason deferred |
|-------|----------------|
| Image passthrough from TurboDraft → Claude Code | Research done (`research-image-passthrough-2026-02-20.md`), needs implementation |
| Extract `setCloExec`/`setNonBlocking`/`writeAll` triplicate | Refactor — no behavior change |
| Image size limits (50MB retina screenshots) | Needs UX design for user feedback |
| Undo/image index desync | Complex state management — needs design |

### Failed Approaches
- Resetting `typingAttributes` in `handleTextDidChange` (after insertion — too late)
- Resetting `typingAttributes` via `insertText` override in EditorTextView (before insertion — still didn't help because `baseAttrs` itself was corrupted)
- Root cause was `textView.textColor` being derived from text storage, not a stored property

### Key Context
- User runs fish shell and Ghostty terminal — use OSC-8 hyperlinks with `tput` styling
- User has LaunchAgent installed — always run `scripts/install` after code changes
- Default theme is now `turbodraft-dark` (iA Writer-inspired monochrome)

## Reference Files

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Project instructions for Claude Code |
| `Sources/TurboDraftApp/EditorColorTheme.swift` | Theme definitions (built-in + custom) |
| `Sources/TurboDraftApp/EditorStyler.swift` | Markdown styling, font management, LRU cache |
| `Sources/TurboDraftApp/EditorViewController.swift` | Text editing, autosave, styling, agent integration |
| `Sources/TurboDraftApp/AppDelegate.swift` | App lifecycle, menus (theme, font size, font family) |
| `Sources/TurboDraftConfig/TurboDraftConfig.swift` | Config with fontSize, fontFamily, colorTheme |
| `Sources/TurboDraftMarkdown/MarkdownHighlighter.swift` | Markdown tokenizer with taskText token |
