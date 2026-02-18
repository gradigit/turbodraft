# Research: Fastest possible stack for TurboDraft cold-start performance
Date: 2026-02-16
Depth: Full

## Executive Summary

For raw cold-start speed on macOS, the strongest stack remains native Cocoa/AppKit with `NSTextView` (TextKit), minimal dependencies, and deferred initialization. Web stacks (Electron/Tauri) carry extra process/runtime overhead by architecture. Tauri is materially lighter than Electron, but neither is likely to beat a stripped native AppKit editor on first-frame latency.

Practical decision:
- Keep TurboDraft on native Swift + AppKit + `NSTextView`.
- Treat this as the baseline “fastest class” for your use case.
- Benchmark TurboDraft vs Kern directly, because both are likely in the same class and differences will be implementation-level, not framework-level.

## Sub-Questions Investigated

1. Which stack minimizes cold-start overhead on macOS?
2. What do official sources say about launch-time bottlenecks?
3. How much architectural overhead do Electron and Tauri add?
4. What text stack is best for high-performance markdown editing?
5. If Kern is also TextKit/AppKit-based, can TurboDraft be significantly faster?

## Source Quality Filter

Accepted (primary/reliable):
- Apple Developer WWDC sessions and docs
- Electron official docs
- Tauri official docs

Rejected / deprioritized:
- SEO blogs with unsourced benchmark numbers
- Reddit anecdotal performance claims
- Vendor blogs without reproducible methodology

## Detailed Findings

### 1) Cold-start is dominated by launch-path work, linkage, and initialization

Apple repeatedly emphasizes:
- show UI quickly, defer non-critical init
- avoid unnecessary frameworks/dependencies in launch path
- dynamic linking/dependency count affects launch time

Evidence:
- WWDC19 `Optimizing App Launch`: guidance on launch phases, avoiding unused frameworks, avoiding dynamic loading (`dlopen`/`NSBundleLoad`), minimizing static initializers, and understanding dependency cost.
- WWDC22 `Link fast`: dynamic libraries speed build iteration but increase launch-time work because dylibs must be loaded/connected at launch.
- Mac App Programming Guide (archive): delay initialization, simplify main nib, minimize startup file I/O, keep main thread free.

### 2) Electron has explicit multi-process + Chromium wrapper overhead

From Electron official docs:
- Electron inherits Chromium’s multi-process model.
- Each `BrowserWindow` loads in a separate renderer process.
- Additional utility processes can be spawned.
- Performance guidance focuses on deferring module loads and startup work because startup costs are meaningful.

Implication:
- For equal app functionality, Electron’s architecture carries higher baseline startup overhead than a native single-process AppKit editor.

### 3) Tauri reduces browser-engine bundling overhead vs Electron, but is still a webview stack

From Tauri official docs:
- Tauri uses system webview and does not bundle a browser engine for each app.
- Minimal app size can be very small.
- TAO handles window creation, WRY handles webview rendering.

Implication:
- Tauri is generally a better “web stack for performance” choice than Electron.
- But it still routes rendering through a webview architecture, so a minimal native AppKit text editor remains the likely ceiling for cold-start responsiveness.

### 4) For text editing, TextKit 2 is Apple’s performance direction, but requires careful usage

From Apple WWDC22 TextKit session:
- TextKit 2 uses viewport-based layout for high-performance large-document layout.
- Apple positions TextKit 2 as the forward engine for text controls.
- Avoid unintended fallback/compatibility paths; switching layout systems is expensive and can hurt performance.

Implication:
- Stay native on `NSTextView`.
- Avoid patterns that force expensive compatibility behavior.
- Keep custom rendering/styling localized (line/viewport scope), not whole-document restyles on each keystroke.

## Hypothesis Tracking

| Hypothesis | Confidence | Supporting Evidence | Contradicting Evidence |
|---|---|---|---|
| H1: Native AppKit TextKit is fastest for cold-start | High | Apple launch guidance + no web runtime/process wrapper overhead | No direct public benchmark head-to-head vs every stack |
| H2: Tauri is faster/lighter than Electron | High | Tauri architecture docs + Electron multi-process docs | Exact app-level deltas vary by implementation |
| H3: SwiftUI-first is best for minimum cold-start | Low | No strong official evidence for fastest cold-start specifically | Mixed field reports; many are anecdotal/uncontrolled |
| H4: TurboDraft vs Kern speed difference will be mostly implementation-level, not framework-level | Medium-High | If both are AppKit/TextKit, shared baseline stack costs dominate | Need direct PoC measurement |

## Verification Status

### Verified (2+ strong sources or official + direct architecture source)
- Launch-time wins come from deferring startup work and trimming dependencies/framework load.
- Dynamic linking/dependency surface influences launch cost.
- Electron uses multi-process browser-style architecture with separate renderer processes.
- Tauri avoids bundling browser engine per app and uses system webview.

### Verified (single high-quality source, consistent with platform architecture)
- TextKit 2 viewport architecture is designed for high-performance text layout and is Apple’s forward direction.

### Unverified / requires local measurement
- Exact cold-start delta between TurboDraft and Kern on your target hardware.
- Whether SwiftUI/AppKit hybrid meaningfully regresses launch in your concrete app.
- Whether TextKit1 vs TextKit2 is faster for your specific markdown-styling workload.

## Recommendation (performance-first)

Use this baseline as default implementation target:
- Native macOS app
- Swift + AppKit
- `NSTextView`/TextKit
- Programmatic UI (no heavy storyboard/nib path)
- Minimal third-party dependencies
- Strict launch-path discipline (defer everything non-essential)

Avoid for the ctrl+g critical path:
- Electron
- Tauri/WebView rendering
- Large framework/plugin surfaces
- Heavy startup scanning/indexing/preloads

## TurboDraft vs Kern PoC Benchmark Plan

Build a controlled apples-to-apples benchmark:

1. Same machine, same OS build, release builds only.
2. Scenarios:
   - cold launch to first editable caret
   - warm launch to editable
   - open file (small/medium/large prompt) to editable
   - first keystroke latency
   - sustained typing latency under markdown styling
3. Metrics:
   - p50/p95 over >= 50 runs for warm and >= 20 runs for cold
   - max outlier and failure count
4. Rules:
   - agent disabled for editor-path test
   - no network
   - identical prompt fixtures
   - no background indexing tasks

Decision gate:
- If Kern and TurboDraft are within ~5-10% on `ctrl+g -> editable`, choose by UX fit (markdown-plain editor vs WYSIWYG).
- If Kern is materially faster (>15-20%) and can be constrained to non-WYSIWYG behavior, evaluate reusing Kern core.

## Sources

- Apple WWDC19: Optimizing App Launch  
  https://developer.apple.com/videos/play/wwdc2019/423/
- Apple WWDC22: Link fast: Improve build and launch times  
  https://developer.apple.com/videos/play/wwdc2022/110362/
- Apple Mac App Programming Guide (archive): Tuning for Performance and Responsiveness  
  https://developer.apple.com/library/archive/documentation/General/Conceptual/MOSXAppProgrammingGuide/Performance/Performance.html
- Apple WWDC22: What’s new in TextKit and text views  
  https://developer.apple.com/videos/play/wwdc2022/10090/
- Apple WWDC22: What’s new in AppKit  
  https://developer.apple.com/videos/play/wwdc2022/10074/
- Electron docs: Process Model  
  https://www.electronjs.org/docs/latest/tutorial/process-model
- Electron docs: Performance  
  https://www.electronjs.org/docs/latest/tutorial/performance
- Tauri docs: What is Tauri? / architecture notes  
  https://v2.tauri.app/start/
