# Context Handoff — 2026-02-19

Session summary for context continuity after clearing.

## First Steps (Read in Order)

1. Read CLAUDE.md — project conventions, build/install rule, key files, gotchas
2. Read README.md — updated install docs, LaunchAgent setup
3. Read `Sources/TurboDraftApp/AppDelegate.swift` — quit latency fix, NSNumber/Bool fix (from prior session)

After reading these files, you'll have full context to continue.

## Session Summary

### What Was Done
- Ran full benchmark suite (primary, multi-fixture, e2e) — all baselines pass
- Confirmed `EnableSecureEventInput` is NOT called by TurboDraft (zero hits in codebase)
- Investigated cold start optimizations (kqueue + early socket bind) — both reverted after benchmarks showed no improvement
- Created `scripts/install` — one-command build + symlink + LaunchAgent restart
- Updated `scripts/turbodraft-launch-agent` with `update` and `restart` commands
- Created `CLAUDE.md` with project instructions, architecture, commands, and gotchas
- Updated `README.md` install section to use `scripts/install` as primary path
- Installed LaunchAgent (`com.turbodraft.app`) on user's machine

### Current State
- All benchmarks pass baselines
- LaunchAgent is installed and running
- `scripts/install` is the canonical update path
- Files created: `CLAUDE.md`, `scripts/install`
- Files modified: `README.md`, `scripts/turbodraft-launch-agent`
- Last commit: e6cc320 — chore: add install script, update launch agent, add CLAUDE.md

### What's Next
1. No explicit pending work — project is in good shape
2. Potential: add `scripts/install` step to CI pipeline
3. Potential: calibrate benchmark baselines on CI runner (current values have dev-machine headroom)

### Failed Approaches
- **Early socket bind** (bind+listen in main.swift before app.run) — CLI connects before accept loop starts, RPC blocks waiting for applicationDidFinishLaunching. Cold start regressed from 174ms to 220ms.
- **kqueue in connectOrLaunch** (replace polling with directory watch) — added syscall overhead, unsigned underflow bug in timeout calculation, no latency improvement because bottleneck is process startup not socket detection.
- Both reverted. Cold start bottleneck is fork+exec+dyld+AppKit bootstrap (~170ms). Only the LaunchAgent eliminates it.

### Key Context
- User runs Ghostty terminal — use OSC-8 hyperlinks with `tput` styling for clickable paths
- User has LaunchAgent installed — always run `scripts/install` after code changes
- Benchmark results are highly sensitive to machine load — check `ps -eo %cpu,command -r | head -5` before interpreting noisy numbers
- The user challenges lazy solutions — always propose the architecturally correct fix, not quick hacks

## Reference Files

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Project instructions for Claude Code |
| `scripts/install` | Build + symlink + restart LaunchAgent |
| `scripts/turbodraft-launch-agent` | LaunchAgent management (install/uninstall/update/restart/status) |
| `Sources/TurboDraftApp/AppDelegate.swift` | App lifecycle, quit handling, RPC dispatch |
| `Sources/TurboDraftCLI/main.swift` | CLI, benchmarks, connectOrLaunch |
| `bench/editor/baseline.json` | Benchmark regression thresholds |
