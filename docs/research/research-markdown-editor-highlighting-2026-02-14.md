# Research: Markdown editor highlighting patterns (TurboDraft)
Date: 2026-02-14
Depth: Full

## Executive summary
Popular Markdown editors generally do *not* WYSIWYG-render the document in-place (unless they are “live preview” editors). Instead, they keep plain Markdown text visible but make it easier to read by:

- Styling *content* (bold text is bold; italic is italic; strikethrough is strikethrough).
- De-emphasizing *markup characters* (e.g. `#`, `**`, backticks, brackets/parentheses) so the text reads cleanly.
- Making code blocks visually distinct (monospace + subtle background).
- Styling links and quotes with lightweight affordances (link color/underline; quote marker dim + muted text).

For TurboDraft (minimal, fast, no WebView), this suggests an approach of:

- Line-oriented parsing in a small, allocation-light highlighter.
- Returning spans for both markers and content (so markers can be dim without losing editability).
- Avoiding full Markdown parsing; focus on the “high-value” readability wins.

## What “popular editors” typically show

### Emphasis and headers: style the *content*, dim the *markers*
- Editors like Bear explicitly support (and can optionally hide) Markdown characters while still applying visible emphasis to the text. This aligns with “dim markers, style content” as the best default.  
- VS Code’s markdown tokenization (TextMate scopes) supports applying `fontStyle: bold/italic` for markdown tokens in the source editor, reinforcing that “bold should look bold” is a normal expectation in source-mode editing.

### Code blocks: distinct background + clear fence
- Ulysses describes code blocks as monospaced on a colored background, and supports syntax highlighting within code blocks. TurboDraft’s v1 should do the background/fence/inline-code accents first; language-aware code highlighting can come later.

### Links: link text emphasized, URL de-emphasized
Most editors separate the link label from the raw URL visually: link label looks like a link; raw URL is less prominent.

## Recommendations for TurboDraft v1 highlighting
Implement these in the editor surface (not preview):
- `#` headings: dim the `#` marker, apply heavier weight to heading text.
- `**strong**`, `*em*`, `~~strike~~`, `==highlight==`: dim markers; style content.
- Inline code: dim backticks; add a subtle background behind code content.
- Lists: dim bullet/number markers; optionally accent task checkboxes (`- [ ]`, `- [x]`).
- Links: underline + `NSColor.linkColor` for link text; dim the URL portion.
- Blockquotes: dim `>` marker; slightly mute quote text.

## Sources
| Source | URL | Quality | Accessed | Notes |
|---|---|---:|---:|---|
| Bear FAQ: “How to use Markdown in Bear” | https://bear.app/faq/how-to-use-markdown-in-bear/ | High | 2026-02-14 | Lists supported syntax + mentions “Hide Markdown” option |
| Ulysses Help: “Code Blocks” | https://help.ulysses.app/en_US/dive-into-editing/code-blocks | High | 2026-02-14 | Describes code blocks as monospaced on a colored background; supports syntax highlighting |
| VS Code markdown bold/italic styling discussion (token scopes) | https://www.reddit.com/r/Markdown/comments/y50lpx/ | Medium | 2026-02-14 | Confirms expectation: bold/italic in editor, not only color |
| VS Code TextMate rule example for Markdown tokens | https://gist.github.com/Number-3434/f9eb31b22c3b8df9257f6d970b17d32b | Medium | 2026-02-14 | Shows custom token rules for cleaner markdown source view |

