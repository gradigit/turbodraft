# Forging Plans Transcript
## Project Context: New project
## Raw Input
I want to build a macOS-native lightweight prompt editor app for Claude/Codex/Code CLI prompt entry. Current flow uses Ctrl+G to open Zed or another external editor (like prompt in text file), then save/close to return refined prompt text to CLI. I want a dedicated app optimized for this one use case:

- Fast startup (target <50ms)
- macOS-native, minimal and lightweight
- Markdown-only (no WYSIWYG), with syntax highlighting and markdown rendering styles for bold/headers/bullets while editing
- Minimal UI: no menus for file open/save/etc., no settings pages; config via JSON.
- Primary mode: edit and polish prompts quickly and copy directly back to terminal prompt.
- Second phase: include embedded prompting workflow so pressing Ctrl+G sends current prompt to a local AI engine (Codex/agent) immediately to iteratively improve prompt.
- Agent should have system prompt already loaded and continuously refine the prompt in near real-time with chat.
- Need iterative workflow: send current prompt + user messages to assistant, reflect improvements to prompt file in editor, keep syncing to terminal prompt on save/close.
- Target architecture likely includes hot/long-running local agent process for low latency.
- I care about performance, minimalism, and good markdown highlighting for prompt engineering.


## Questionnaire

### Category 1: Core Vision
1. One sentence
- A lightweight, hyper-performant, dedicated prompt editor app with optional AI-assisted prompt-engineering workflow.
2. Problem solved + who
- Solves CLI control-G external editor latency. Existing editors are too heavy for this targeted task. It helps developers, especially me, who want fast prompt iteration while in Codex/Claude/Codex CLI sessions.
3. Primary and secondary users
- Primary: me (single developer, power user). Secondary: eventual open-source users/distribution audience.
4. Success metrics
- Startup time: sub-50ms target.
- Prompt-engineering iteration feedback latency: <5s typical, up to ~10s depending on Codex Spark responsiveness.
5. Most important requirement
- Hyper performant behavior with near-zero cold start and fast prompt iteration loop.

### Category 2: Requirements & Constraints
1. Mandatory capabilities
- Minimal, markdown-focused external-editor-like app for prompt editing.
- Keep startup and iteration loop latency very low.
- Markdown syntax highlighting + rendering cues (headers, bold, bullets).
- Integrate with CLI control-G workflow.
- Reflect iterative AI-assisted prompt refinements back into prompt text file continuously.
2. Explicit exclusions
- No full-featured general-purpose editor behavior.
- No heavy file/menu/settings UI.
3. Hard constraints
- Must be lightweight and performance-first.
- macOS-native.
- Priority on fast startup and response (near-zero cold start).
4. Soft constraints
- Minimal and focused UX, config via JSON.
- Markdown formatting preview/rendering for readability.
5. Compliance
- None identified.
6. Integration constraints
- Must integrate with Claude Code/Codex CLI via external editor behavior and control-G trigger.

### Category 3: Prior Art & Context
1. Existing known solutions
- None known by user; user believes no exact existing match.
2. Why not existing
- Typical editors (e.g., Zed/VS Code) are too heavy/slow for this focused use.
3. Prior attempts
- None described beyond current external editor flow.
4. References/inspiration
- Existing Ctrl+G external editor flow in CLI tools.
5. Existing docs/resources
- Not specified beyond CLI/editor tooling docs.

### Category 4: Architecture & Structure
1) Target architecture preference
- One app for the editor. The AI feature should be optional as a model add-on.
2) Language/toolkit preference
- Not finalized. You explicitly requested research (study skill, subagents in parallel) to determine best language/toolkit.
3) Data flow
- Yes: terminal/control-G editor flow with prompt file. Agent should provide hot-load updates so prompt-file changes from AI appear in editor instantly (live sync/autosave).
4) Must-have architectural constraints
- Must support instant auto-save and instant hot reload.
- If agent integration is enabled, prompt improvements returned from AI should remain visible in an agent chat interface and sync carefully with prompt file.

### Category 5: Edge Cases & Error Handling
1) Save while agent is mid-edit
- Save should still work; if agent conflicts occur, user can use undo (e.g., Ctrl+Z) on their preferred path. (You noted user can recover from chat text if file conflict occurs.)
2) Agent timeout / malformed output
- Prefer conflict-safe behavior; recovery can include manual correction/undo fallback. 
3) CLI hook failures
- If valid lockdown constraints are hit, leave behavior as-is (do not auto-disrupt).
4) Invalid markdown/input
- Leave as-is (do not auto-fix).


### Category 6: Scale & Performance
- Scope: single-user local use only.
- Critical metric: cold/startup latency target < 50 ms. Kept as non-negotiable target.
- Prompt-engineering roundtrip latency is model-dependent and not primary control point.
- No explicit constraints on sync/keypress latency or plugin-scale performance.

### Category 8: Integration & Dependencies
- Integration target: both Claude Code and Codex CLI.
- Transport for AI add-on: to be decided by research.
- In-app behavior should support immediate auto-save and hot reload: edits from agent should reflect instantly in editor.
- Chat interface is needed for iterative prompt engineering while keeping control over prompt edits.

### Category 9: Testing & Verification
- Need robust benchmarking suite for startup latency.
- Need robust automated test suite.
- Prompt quality review not critical in-app; AI output assumed acceptable and can be trained/controlled.

### Category 11: Trade-offs & Priorities
- Priority order: speed, simplicity, quality.
- Minimal UI and minimal feature set are priorities; little can be sacrificed except strict speed target.
- Production-grade polish expected despite simplicity.

### Category 12: Scope & Boundaries
- In-scope: single-session app with AI add-on (no separate phase planned).
- No plugins or extra ecosystem expansion requested.
- No explicit phased roadmap or future phase separated from MVP.
