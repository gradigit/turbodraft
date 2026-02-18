# Research: Fastest macOS Editor Stack for Cold Start + Typing Latency
Date: 2026-02-16
Depth: Full

## Executive Summary
For a dedicated macOS prompt editor where cold-start and "Ctrl+G to editable" latency are primary goals, the best practical stack is native AppKit + NSTextView/TextKit 2 with a minimal single-window architecture and no WebView runtime. Electron and Tauri can be optimized, but both still route UI through browser/WebView process models, which introduces extra startup and IPC surface compared to a native text view stack. A custom Rust+GPU editor engine can be competitive or faster at scale, but has much higher implementation risk and is unnecessary unless AppKit fails measured targets.

Confidence: High for architecture ranking (native AppKit > WebView-based stacks for cold start in this use case). Medium for "absolute fastest possible in all scenarios" because that depends on custom-engine investment and hardware variability.

## Sub-Questions Investigated
1. Which desktop app architecture minimizes cold-start overhead for a prompt editor?
2. Is TextKit 2 suitable for high-performance markdown text editing on macOS?
3. How do Electron and Tauri process models affect startup path complexity?
4. Should TurboDraft continue vs. reuse Kern from a performance standpoint?

## Detailed Findings

### 1) Cold-start performance is dominated by launch-path work and dependency/runtime loading
Apple launch guidance emphasizes separating cold vs warm launch, minimizing work before first frame, avoiding static initialization work, and continuously tracking launch regressions. This directly favors lean startup paths with fewer runtime layers and deferred non-critical work.

Evidence:
- Apple WWDC19 launch guidance explains cold/warm/resume distinctions and launch-phase bottlenecks.
- Apple WWDC22 runtime-performance session emphasizes runtime improvements and launch-sensitive optimizations.
- Apple MetricKit defines app launch metrics and first-draw distributions (platform-level measurement model).

Implication:
For TurboDraft, fastest cold-start behavior comes from aggressively minimizing initialization before first editable text view is visible.

### 2) TextKit 2 is the right native text engine baseline for macOS editor performance
Apple’s TextKit sessions describe TextKit 2 as having improved performance and a viewport/nonlinear layout approach that reduces unnecessary layout work, especially for large content. Apple also indicates modern text controls default to TextKit 2, and warns that falling back into compatibility mode can be expensive.

Evidence:
- WWDC21 AppKit: TextKit 2 designed to be very fast; nonlinear layout model.
- WWDC22 TextKit updates: improved performance/correctness/safety; default TextKit 2 usage in modern text controls; compatibility mode switching is expensive.

Implication:
A native markdown editor should stay on the TextKit 2 path, avoid compatibility fallbacks, and avoid full-document restyling on each edit.

### 3) Electron and Tauri both retain web rendering process overheads despite different tradeoffs
Electron officially documents Chromium-derived multi-process architecture, including main + renderer processes (per BrowserWindow). Tauri has a lighter footprint and smaller bundle size claims, but still uses a Core process plus WebView process(es) for UI execution.

Evidence:
- Electron process model: multi-process, renderer per BrowserWindow.
- Electron performance guidance: measure/profile and defer startup work.
- Tauri process model: Core process orchestrating one or more WebView processes.
- Tauri overview: smaller binaries via system WebView, but still web UI stack.

Implication:
For this app’s strict cold-start target and minimal UI, native AppKit avoids entire web runtime/process plumbing and remains the strongest default.

### 4) "Absolute fastest" has two realistic tiers
- Tier A (best practical for TurboDraft now): AppKit + TextKit 2, no WebView.
- Tier B (highest theoretical ceiling): custom renderer/editor engine (Rust/Metal/CoreText class of approach), but significantly higher complexity and maintenance burden.

Evidence:
- Apple TextKit performance claims support Tier A.
- Zed engineering posts indicate why custom GPU-first stacks pursue performance ceilings; however, these are product-specific and not directly transferable benchmarks.

Implication:
Unless TurboDraft misses measured targets after native optimization, building/porting to a custom editor engine is likely negative ROI.

## Hypothesis Tracking
| Hypothesis | Confidence | Supporting Evidence | Contradicting Evidence |
|------------|------------|---------------------|------------------------|
| H1: Native AppKit + TextKit 2 is the fastest practical stack for TurboDraft cold start | High | Apple launch guidance + TextKit 2 perf claims + Electron/Tauri process-model overheads | No Apple source gives a universal stack ranking with numbers |
| H2: Tauri can match native AppKit cold-start for this use case | Low-Med | Smaller binary size, system WebView reuse | Tauri still spins WebView process model and web runtime path |
| H3: Electron can be made competitive for sub-50ms editor activation | Low | Electron can be optimized heavily | Official docs still describe multi-process Chromium model and startup work sensitivity |
| H4: Custom Rust/GPU engine can beat AppKit at scale | Medium | Zed architecture rationale and performance focus | High implementation complexity; no direct apples-to-apples benchmark for this app |

## Verification Status
### Verified (2+ sources)
- Launch performance depends on minimizing startup-phase work and measuring cold vs warm separately.
- TextKit 2 is designed for improved performance and modern default use in Apple UI text controls.
- Electron uses Chromium-style multi-process model with renderer processes per window.
- Tauri uses a Core process and WebView process(es), despite smaller package size.

### Unverified / Partially Verified
- A universal claim that AppKit is always faster than all alternatives on every machine and build setup (not directly published as a single official benchmark).
- Exact startup deltas between TurboDraft and Kern (requires local A/B measurement).

### Conflicts / Nuance
- Tauri can be much smaller in binary size than Electron and may start faster than Electron in many projects, but this does not inherently imply faster-than-native AppKit startup for a minimal text editor.

## Self-Critique
- Completeness: Covers architecture, text engine choice, and benchmark methodology.
- Source quality: Prioritized official Apple/Electron/Tauri docs; used Zed posts as directional context only.
- Bias check: Initial native bias was tested against Tauri/Electron documentation.
- Gaps: Lacks direct in-repo, same-hardware A/B numbers vs Kern in this report.
- Recency: Sources include current docs/pages with 2025–2026 updates where available.

## Recommendation (Actionable)
1. Keep TurboDraft on native AppKit + NSTextView (TextKit 2 path), no WebView.
2. Keep launch path minimal: single window, no heavy startup tasks before first editable frame.
3. Defer non-essential initialization (agent/model plumbing, optional services) until after editor is interactive.
4. Maintain optional resident mode only as an optimization layer; keep baseline fast without daemon dependency.
5. Run a strict A/B PoC benchmark versus Kern before any major stack change.

## TurboDraft vs Kern PoC Benchmark Plan
Use identical hardware, build mode, and test corpus. Compare TurboDraft and Kern in at least 100-run batches.

Metrics:
- t_launch_cold: process spawn -> first window visible
- t_editable_cold: process spawn -> caret accepts typing
- t_activate_warm: Ctrl+G hook -> focused editable state (resident)
- t_type_p95: keydown -> rendered glyph commit (instrumented)
- t_autosave_p95: edit -> fsync completion
- mem_idle: RSS after open + 30s idle

Method:
- Instrument with signposts around launch/editable milestones.
- Capture with Instruments/xctrace runs for both apps.
- Run warm/cold separately; avoid mixing resume data into launch metrics.
- Use identical markdown fixtures (small/medium/large + stress file).

Decision rule:
- If TurboDraft is within 5-10% of Kern on core latency metrics while preserving plain-markdown UX and lower complexity, continue TurboDraft.
- If Kern is materially faster (>15-20% on cold/editable p95) and can be constrained to non-WYSIWYG behavior without heavy compromise, consider reusing Kern core.

## Sources
| Source | URL | Quality | Accessed |
|--------|-----|---------|----------|
| Optimizing App Launch (WWDC19) | https://developer.apple.com/la/videos/play/wwdc2019/423/ | High (official Apple) | 2026-02-16 |
| Improve app size and runtime performance (WWDC22) | https://developer.apple.com/videos/play/wwdc2022/110363/ | High (official Apple) | 2026-02-16 |
| MXAppLaunchMetric docs | https://developer.apple.com/documentation/metrickit/mxapplaunchmetric | High (official Apple) | 2026-02-16 |
| What’s new in AppKit (WWDC21) | https://developer.apple.com/videos/play/wwdc2021/10054/ | High (official Apple) | 2026-02-16 |
| What’s new in TextKit and text views (WWDC22) | https://developer.apple.com/videos/play/wwdc2022/10090/ | High (official Apple) | 2026-02-16 |
| Electron Process Model | https://www.electronjs.org/docs/latest/tutorial/process-model | High (official framework docs) | 2026-02-16 |
| Electron Performance Guide | https://www.electronjs.org/docs/latest/tutorial/performance | High (official framework docs) | 2026-02-16 |
| Tauri Process Model | https://v2.tauri.app/concept/process-model/ | High (official framework docs) | 2026-02-16 |
| What is Tauri? | https://v2.tauri.app/start/ | High (official framework docs) | 2026-02-16 |
| Zed GPUI architecture post (context only) | https://zed.dev/blog/videogame | Medium (vendor engineering blog) | 2026-02-16 |
