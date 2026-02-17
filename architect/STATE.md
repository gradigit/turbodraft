# Forge State
## Current Stage: questionnaire
## Mode: 1
## Depth: full
## Categories Asked: [1, 2, 3, 4, 5, 6, 8, 9, 11, 12]
## Categories Skipped: [7, 10]
## Categories Remaining: []
## Key Decisions:
- Single dedicated macOS editor app is required; AI module is an optional add-on.
- One-app model preferred with one-way focus: no menus/plugins/settings UI, JSON-based configuration.
- Hard target remains cold-start performance (`<50ms`), with auto-save + hot reload as first-class behavior.
- Single-user local usage; no plugin architecture or phase 2.
- AI add-on must include chat loop and must not block editor responsiveness on conflict.
