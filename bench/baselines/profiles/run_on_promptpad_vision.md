## Goal
Build an MVP macOS-native, ultra-lightweight prompt editor dedicated to the CLI external-editor workflow. The app should reduce friction when refining prompts mid-session by combining markdown editing and live AI prompt-engineering chat, then returning the final prompt to the calling CLI buffer with no copy/paste.

## Core Workflow
1. User types a rough prompt in Claude Code or Codex CLI.
2. User presses Ctrl+G to open the external editor.
3. App opens the provided prompt buffer, auto-sends full text to a warm prompt-engineering agent (default model: Codex 5.3 Spark), and starts refinement.
4. User chats with the agent and applies revisions.
5. Each accepted revision updates the same prompt buffer used by the CLI.
6. User saves and closes; control returns to CLI with the perfected prompt prefilled and ready to submit.

## Scope and Constraints
- macOS native only for v1.
- Startup performance target is under 50 ms on an agreed benchmark definition.
- Editor is single-purpose: prompt text editing only.
- No file browser, no project management, and no settings page in the UI.
- Configuration must be file-based (JSON or equivalent).
- Markdown support must include syntax highlighting and visible formatting for headings, bold text, and lists.
- Include a chat interface for iterative prompt engineering and revision application.
- Do not auto-submit the prompt to CLI; only return edited text.
- Do not log prompt content, secrets, or API keys by default.
- Optional: Reuse or fork an existing open-source editor core only if it clearly accelerates delivery without violating performance and native UX targets.

## User Inputs to Request
- Ask the user to confirm which CLI is first priority and provide the exact external-editor contract (buffer file lifecycle, environment variables, and blocking behavior).
- Request the user’s definition of the under-50-ms metric (cold start vs warm launch), target hardware, and measurement method.
- Ask whether markdown should be source-only with highlighting, split preview, or inline formatted rendering.
- Confirm the model endpoint and authentication approach for the warm agent (local server vs remote API).
- Ask the user to choose preferred interaction layout priority: split pane, sidebar, bottom panel, or diff-first view.

## Agent Decisions / Recommendations
1. Implementation stack decision. Option A: Swift with AppKit/TextKit for strongest native UX and likely fastest launch. Option B: Rust-native stack for performance and systems control with higher macOS text-UX complexity. Option C: C++ with macOS frameworks for maximum control and highest maintenance burden. Information that changes this decision: measured startup on target hardware, team expertise, and required text-editing fidelity.
2. AI runtime architecture decision. Option A: warm local daemon for lowest latency and better interactivity. Option B: direct remote API calls for simpler architecture with variable latency. Option C: hybrid local-first with remote fallback for resilience and added complexity. Information that changes this decision: network stability, local inference availability, and ops complexity tolerance.
3. Prompt iteration UX decision. Option A: split editor and chat for best conversation visibility. Option B: bottom chat panel for maximal editor space. Option C: diff-first review with chat toggle for strongest revision control and higher implementation cost. Information that changes this decision: expected turn count per prompt and user preference for delta review vs conversational editing.

## Implementation Steps
1. Collect and confirm all required details listed in User Inputs to Request, then lock v1 scope.
2. Implement and validate the external-editor lifecycle integration so open-edit-save-close round-trips correctly with the target CLI.
3. Run rapid prototypes for stack, runtime, and UI options, then select one path using Agent Decisions / Recommendations and benchmark evidence.
4. Build the native markdown editor shell with minimal UI, syntax highlighting, and file-based configuration.
5. Integrate the warm AI agent flow: preload system instructions, auto-send initial prompt on launch, support chat iterations, and apply accepted revisions to the live buffer.
6. Implement reliable writeback behavior so each applied revision updates the CLI buffer file safely and save/close always returns the latest prompt.
7. Run end-to-end validation and performance tests, then deliver an MVP with measured startup, response latency, and workflow verification.

## Acceptance Criteria
- Ctrl+G launches the app from the target CLI with existing draft prompt loaded.
- Initial prompt is automatically sent to the configured warm agent and user can iterate through chat.
- Applying a revision updates the same buffer that CLI will read on return.
- Save and close returns control to CLI with the refined prompt already present and no manual paste.
- Markdown editing includes syntax highlighting and visible formatting cues for headings, bold, and lists.
- v1 UI excludes file-open menus and settings pages.
- Performance and flow test results are documented against agreed thresholds.