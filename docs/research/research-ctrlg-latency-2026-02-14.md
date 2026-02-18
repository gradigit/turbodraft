# Research: TurboDraft Ctrl+G -> editable latency (macOS)
Date: 2026-02-14
Depth: Full

## Executive Summary
TurboDraft’s warm (resident) editor path is dominated by the act of invoking an external-editor shim and waiting for the app to focus + load the file. Apple’s launch guidance emphasizes getting the UI interactive as early as possible and deferring non-critical work off the critical path.

For very low invocation overhead, relying on a large runtime (for example a full Swift CLI) is often counterproductive. Swift static linking is constrained on Apple platforms (for example `-static-stdlib` is not supported), so the most reliable way to minimize “Ctrl+G -> editable” is to keep a resident app instance and use a tiny shim to talk to a local transport (UDS) quickly.

## Sub-Questions Investigated
1. How should we optimize for perceived launch time / interactivity?
2. How can we instrument the dynamic loader and initializers to understand pre-main cost?
3. Can we reduce Swift CLI startup cost via static linking on Apple platforms?

## Findings

### 1) Optimize for time-to-interactive
Apple’s guidance for launch performance focuses on reaching an interactive UI quickly and deferring work that isn’t required for first interaction.

Implications for TurboDraft:
- The editor should become first-responder + editable ASAP.
- Markdown styling/highlighting can be scheduled immediately after, but not block the “open” response path.

### 2) Dynamic loader instrumentation
Apple documents a set of `DYLD_*` environment variables that can log loader behavior (including libraries and initializers) to help understand “pre-main” work.

Implications for TurboDraft:
- When diagnosing launch latency, use dyld logging to see which frameworks/initializers dominate.
- Prefer reducing dylib count and initializer work on the hot path.

### 3) Static linking constraints on Apple platforms
Swift’s `-static-stdlib` is not supported for Apple platforms (and fully static executables are generally not feasible on macOS).

Implications for TurboDraft:
- Don’t expect “make the Swift CLI static” to be the primary lever for sub-50ms invocation.
- If you need a near-instant shim, a small C/ObjC helper is a pragmatic approach.

## Recommendations
1. Keep `turbodraft-app` resident and control it via UDS (already implemented).
2. Use a minimal shim for the external-editor invocation path (for example `turbodraft-open`) that connects to the UDS and performs a JSON-RPC open (and optionally wait) without pulling in heavy runtimes.
3. Ensure “open” does not synchronously run expensive editor embellishments (styling/highlighting); coalesce repeated styling requests.

## Sources
| Source | URL | Quality | Accessed | Notes |
|---|---|---:|---:|---|
| Apple: Logging Dynamic Loader Events | https://developer.apple.com/library/archive/technotes/tn2239/_index.html | High | 2026-02-14 | Official doc describing dyld logging env vars (libraries, initializers, etc.) |
| Apple WWDC 2019: Optimizing App Launch | https://developer.apple.com/videos/play/wwdc2019/423/ | High | 2026-02-14 | Official session emphasizing time-to-interactive and launch optimization patterns |
| Swift Forums: `-static-stdlib` not supported on Apple platforms | https://forums.swift.org/t/why-static-stdlib-is-no-longer-supported-for-apple-platforms/70696 | High | 2026-02-14 | Confirms static stdlib not supported on Apple platforms |
| Swift Forums: Static executable on macOS | https://forums.swift.org/t/static-executable-on-macos/69873 | High | 2026-02-14 | Discussion on static executable feasibility/constraints |
