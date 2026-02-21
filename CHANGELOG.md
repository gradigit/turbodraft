# Changelog

All notable changes to TurboDraft are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Claude/Sonnet backend**: `ClaudePromptEngineerAdapter` invokes `claude -p` with `--output-format text`, `--effort` mapping, and `--tools ""`. New `Backend.claude` config option with auto-detection when model name contains "claude" or "sonnet".
- Backend menu in app menu bar (Codex exec / Codex app-server / Claude)
- **Image drag-and-drop and paste**: images pasted or dragged into the editor are saved as temp files and attached to the prompt-engineer context as `[Image #N]` placeholders with `@image-ref` annotations
- **Color themes**: 7 built-in themes (turbodraft-dark, turbodraft-light, github-dark, github-light, dracula, solarized-dark, solarized-light) + custom theme support via config
- **Font settings**: configurable font family and size via config
- **Task strikethrough**: completed task checkboxes (`- [x]`) render with strikethrough styling
- Unique IDs for image placeholders, `@refs` prepended at top of prompt text
- Shared POSIX spawn helpers extracted into `ProcessHelpers.swift`
- Benchmark suite overhaul TODO with full audit findings (todos/003)

### Fixed

- Styling feedback loop: `applyStyling` now uses `colorTheme.foreground` directly instead of reading `textView.textColor` (which reflects text storage attributes, not the base color)
- Benchmark fixture corruption: restored `dictation_flush_mode.md`, removed misplaced top-level baseline, fixed stale `profile_set.txt` reference

### Changed

- Removed hardcoded test counts from README.md and CLAUDE.md (go stale on every test addition)

## [0.2.0] — 2026-02-19

### Fixed

- **Thread safety**: `CodexPromptEngineerAdapter.draft()` now runs blocking `posix_spawn` + poll loop off the cooperative thread pool via `Task.detached` (matching the CLI adapter pattern)
- **Main-thread image paste**: TIFF→PNG conversion moved to a background task — pasting large retina screenshots no longer freezes the editor
- **Image size limit**: images over 20 MB are now skipped before base64 encoding (app-server adapter) and before passing as CLI args (exec adapter), preventing OOM and API rejection
- **ENOENT handling**: `posix_spawn` returning `ENOENT` now throws `.commandNotFound` instead of a raw `.spawnFailed(errno: 2)` in exec and app-server adapters
- **CLI adapter `nonZeroExit`**: error now includes the last 512 bytes of process output for diagnostics

### Changed

- **Shared `effectiveReasoningEffort`**: extracted from 3 duplicated sites into `PromptEngineerPrompts.effectiveReasoningEffort(model:requested:)` — adapters and AppDelegate all call the shared version
- **Error naming**: `CodexCLIAgentError.timeout` renamed to `.timedOut` to match the other two adapter error types
- **Default parameter cleanup**: removed redundant `images: [URL] = []` defaults from all adapter `draft()` conformances — the protocol extension already provides the default
- **`@unchecked Sendable` removed** from `CodexCLIAgentAdapter` (all properties are `let`)
- **Startup temp cleanup**: `applicationDidFinishLaunching` now removes stale `turbodraft-img-*` and `turbodraft-codex-*` files from the temp directory

### Added

- 10 new tests (67 → 77): shared reasoning-effort logic, adapter error naming, `nonZeroExit` diagnostics, exec adapter `commandNotFound`, and `Task.detached` structural test

## [0.1.0] — 2026-02-19

### Fixed

- **PATH resolution under LaunchAgent**: extracted `CommandResolver.buildEnv(prependingToPath:)` shared across all adapters, using `ProcessInfo.processInfo.environment` (thread-safe) instead of raw C `environ`
- **Spawn failures under LaunchAgent**: `CodexCLIAgentAdapter` now uses `CommandResolver.buildEnv` (was missing entirely)
- **Repair turns re-sending images**: both prompt-engineer adapters now pass `images: []` on repair
- **Session switch image bleed**: `applySessionInfo` cleans up stale temp files and clears `attachedImages`
- **Temp file leak in deinit**: `EditorViewController.deinit` removes orphaned image temp files
- **Dead nvm alias resolution**: removed broken `~/.nvm/alias/default` lookup (contains alias strings, not directories)
- **fnm base directory**: now checks all 3 known locations (`~/.local/share/fnm`, `~/.fnm`, `~/Library/Application Support/fnm`)
- **`saveTempImage` silent failure**: write errors now return `nil` instead of a URL to a nonexistent file
- **Broken MCP disable flags**: removed from `bench_codex_prompt_engineer.py` (4 occurrences) and `codex_app_server_poc.py`

### Changed

- **`supplementalPaths` cached**: changed from computed `var` (filesystem I/O every call) to `static let`

### Added

- `CommandResolver.swift` — centralized PATH resolution and environment building
- Warning when `CodexCLIAgentAdapter` receives images (no mechanism to forward them)
- 9 new tests: `CommandResolverTests` (8 tests) and `CodexAdapterTests.testAdapterIgnoresImagesGracefully`
- Image upload support for prompt engineer (PR #6 from guzus)
- PATH fix for spawning Codex when executable's bin dir is missing (PR #5 from guzus)

[0.2.0]: https://github.com/gradigit/turbodraft/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/gradigit/turbodraft/releases/tag/v0.1.0
