# Context Handoff — 2026-02-21 (Session 3)

Session summary for context continuity. This handoff assumes ZERO prior context.

## First Steps (Read in Order)

1. Read `CLAUDE.md` — project conventions, build commands, architecture (10 modules), key files, 12 gotchas
2. Read this file completely — session history, all open TODOs, current state, what's next
3. Read `todos/003-pending-p1-benchmark-suite-overhaul.md` — the P1 TODO with full audit findings and phased plan
4. Read `todos/001-pending-p2-session-context-for-prompt-engineer.md` — feature request for CLI session context
5. Read `todos/002-pending-p2-image-size-limits.md` — reject oversized images with error message

## What TurboDraft Is

A native macOS AppKit editor for AI CLI tool hooks. When Claude Code or Codex CLI asks for `$EDITOR` (Ctrl+G), TurboDraft opens in ~10ms (warm) and gives a Markdown editor designed for writing prompts. It has an "Improve Prompt" feature powered by either Codex or Claude that rewrites the prompt in-place.

## Session 3 Summary (2026-02-21)

### What Was Done

1. **Claude/Sonnet backend** (commit f2e013c) — Added `ClaudePromptEngineerAdapter.swift` that invokes `claude -p` with `--output-format text`, `--effort` flag, and `--tools ""` (no tools). New `Backend.claude` config option. Auto-switches when model name contains "claude" or "sonnet". Backend menu in app menu bar. 5 new tests (total: 82).

2. **Benchmark validation** — Ran the prompt-engineering benchmark (`bench_codex_prompt_engineer.py`) with `claude-sonnet-4-6` at `high` effort against `prompt_engineering_draft.md`. Results: 100/100 quality on all 3 runs, ~64s per run.

3. **Benchmark fixture audit** — Discovered multiple integrity issues with the benchmark suite:
   - `dictation_flush_mode.md` fixture contains prompt-engineer OUTPUT, not the original raw voice dictation (which was lost — never committed to git)
   - `prompt_engineering_draft.md` is a meta-circular fixture (system preamble + already-structured TurboDraft spec)
   - Multiple fixtures are self-referential (about TurboDraft itself)
   - Quality scorer rewards structure over substance
   - Model-as-judge and pairwise comparison disabled by default

4. **Infrastructure fixes** (commit 121e644):
   - Removed misplaced `bench/baselines/dictation_flush_mode.md` (duplicate of profiles/ version)
   - Fixed `profile_set.txt`: `run_on_turbodraft_vision.md` → `run_on_promptpad_vision.md`
   - Restored `dictation_flush_mode.md` from benchmark corruption (note: still wrong content — it's a prompt-engineer output, not raw dictation)
   - `.gitignore`d research files and local-only docs

5. **Benchmark overhaul TODO** (commit f4443b5) — Created `todos/003-pending-p1-benchmark-suite-overhaul.md` with comprehensive findings and 3-phase improvement plan

6. **Doc sync** (commit 985cf77) — Updated CLAUDE.md (Claude adapter refs, new gotcha, benchmark command) and CHANGELOG.md (Unreleased section with all changes since v0.2.0)

### What Was NOT Done

- The benchmark suite overhaul itself (TODO 003) — only the audit and plan
- Sonnet hasn't been benchmarked against the full profile fixture set (only 1 valid fixture tested)
- The `dictation_flush_mode.md` fixture still has wrong content (user needs to re-dictate the original)
- P0 security fixes from the production readiness review (session 2) are still open — see below
- Image size limits (TODO 002) not implemented yet
- Session context for prompt engineer (TODO 001) not implemented yet

### Current State

- Branch: main, up to date with origin
- All 82 tests pass
- Working tree clean (no uncommitted changes)
- LaunchAgent running latest binary
- Git worktrees: only main (clean)
- Untracked files: all gitignored (research files, local docs)

## All Open TODOs

### P0 — Security (from Session 2 production review)

These were identified in `docs/production-readiness-review-2026-02-20.md` but have NOT been fixed:

| # | Issue | File | Effort |
|---|-------|------|--------|
| SEC-1 | Command injection via `system()` — `TURBODRAFT_TERMINAL_BUNDLE_ID` unsanitized | `main.c:635` | Low |
| SEC-2 | Raw `environ` leaked to child via `posix_spawn` | `main.c:292,318` | Medium |
| SEC-3 | `getpeereid()` fail-open — connections accepted without auth on failure | `UnixDomainSocket.swift:160` | 1-line fix |
| BUG-1 | Stale `editorMode` in EditorViewController after config change | `EditorViewController.swift:454` | Low |
| BUG-2 | `sessionsById` memory leak — no session GC/close RPC | `AppDelegate.swift:497` | Medium |

### P1 — Benchmark Suite Overhaul (TODO 003)

**This is the primary next task.** The full audit is in `todos/003-pending-p1-benchmark-suite-overhaul.md`. Key phases:

1. **New fixtures** — Write 6-8 domain-diverse, genuinely rough fixtures (not about TurboDraft, not already-refined). Create matching baselines.
2. **Scoring improvements** — Make model-as-judge default, add input-complexity awareness, add fidelity checks.
3. **Methodology fixes** — Rename preamble identity from "You are TurboDraft" to generic, run from neutral dir, add regression tracking.

### P1 — Performance (from Session 2 review)

| # | Issue | Detail |
|---|-------|--------|
| PERF-1 | O(n) fence-state prefix scan per keystroke | Fine for <5KB, 5-10ms at 100KB |
| PERF-2 | O(n) cache key hashing via substring copy | Combined with PERF-1, can exceed 16ms at 100KB |

### P2 — Feature TODOs

- `todos/001-pending-p2-session-context-for-prompt-engineer.md` — Prompt engineer has no CLI session context
- `todos/002-pending-p2-image-size-limits.md` — Reject images >20MB / >8000px with error

### P2 — Dead Code (~660 LOC removable)

See `docs/production-readiness-review-2026-02-20.md` section P2.

## Failed Approaches (Across All Sessions)

- Sequential `[image N]` placeholders — indices shift on undo/redo, corrupting references. Use `[image-XXXX]` with 8-char hex UUIDs instead.
- Clipboard-based image passthrough — hijacks user's clipboard, unreliable
- Appending @refs at bottom of document — Claude may not read images before prompt text. Prepend at top.
- Reading `textView.textColor` in `applyStyling` — reflects text storage attributes, not base color. Creates feedback loop. Always use `colorTheme.foreground` directly.
- Setting tight benchmark P95 thresholds from dev-machine runs — machine load causes false regressions

## Key Context for New Agent

- **User runs fish shell** and Ghostty terminal — use OSC-8 hyperlinks with `tput` styling (raw SGR codes get stripped)
- **Always run `scripts/install`** after any code change — rebuilds release binary and restarts LaunchAgent
- **Agent adapters** share `ProcessHelpers.swift` (POSIX spawn helpers) — don't re-add to individual adapter files
- **Agent adapters must use `CommandResolver.buildEnv()`** when spawning child processes — raw `environ` breaks under LaunchAgent
- **Image placeholders** use `[image-XXXX]` format (8-char hex UUID), NOT `[image N]`
- **`CLAUDECODE` env var** must be unset when running `claude -p` from inside a Claude Code session
- **Prompt-engineering benchmark** (`scripts/bench_codex_prompt_engineer.py`, 1957 lines) supports both Codex and Claude models. Has heuristic scoring, optional model-as-judge, and optional pairwise comparison. The benchmark suite has known issues — see TODO 003.
- **Config lives at** `~/Library/Application Support/TurboDraft/config.json`
- **Socket at** `~/Library/Application Support/TurboDraft/rpc.sock`

## Reference Files

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Project instructions, commands, architecture, gotchas |
| `CHANGELOG.md` | Version history (v0.1.0, v0.2.0, Unreleased) |
| `todos/003-pending-p1-benchmark-suite-overhaul.md` | Benchmark audit findings + phased plan |
| `todos/001-pending-p2-session-context-for-prompt-engineer.md` | CLI session context feature |
| `todos/002-pending-p2-image-size-limits.md` | Image size limits feature |
| `docs/production-readiness-review-2026-02-20.md` | Full production readiness report (P0-P3) |
| `Sources/TurboDraftAgent/ClaudePromptEngineerAdapter.swift` | Claude/Sonnet backend |
| `Sources/TurboDraftAgent/CodexPromptEngineerAdapter.swift` | Codex exec backend |
| `Sources/TurboDraftApp/EditorViewController.swift` | Text editing, images, autosave, styling |
| `Sources/TurboDraftApp/AppDelegate.swift` | App lifecycle, socket server, RPC dispatch, menus |
| `scripts/bench_codex_prompt_engineer.py` | Prompt-engineering quality benchmark |
| `bench/fixtures/profiles/` | Profile fixtures for prompt-engineering benchmarks |
| `bench/baselines/profiles/` | Gold-standard baselines for pairwise comparison |
| `bench/preambles/` | System preamble variants (core, extended, large-optimized) |
