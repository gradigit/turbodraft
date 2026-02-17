# Flush Mode Window Bar Styling (Square Corners + Window Separation)

## Goal
Update the UI in “flush mode” so window tiles/bars look more square (reduced or zero corner radius) and multiple windows are visually distinguishable rather than blending into one continuous bar.

## Constraints
- Only change styling/visual treatment for flush mode; keep non-flush mode appearance unchanged.
- Keep the overall “Apple liquid glass” feel: subtle, lightweight separation (avoid heavy outlines or high-contrast dividers).
- Do not change window ordering, icons, or interaction behavior (hit targets, selection, hover/active states) unless required to preserve usability.

## User Inputs to Request
- Ask the user to define “flush mode” precisely (where it appears, how to enable it) and what UI element(s) are considered the “window bar/tiles.”
- Ask the user to provide a screenshot (or short screen recording) showing the current flush mode appearance with 2+ windows visible.
- Request the relevant Claude Code log excerpt or a short summary of prior design conclusions that should be respected.
- Confirm the target platform/UI stack (e.g., web/CSS, SwiftUI/AppKit, Electron) and where style tokens (corner radius, borders, materials) are managed.

## Agent Decisions / Recommendations
- Decision: Corner radius in flush mode. Options: A) 0 radius (fully square, most “flush”); B) small radius (2–4px) to preserve a glassy softness; C) radius only on the outer container, inner window segments square. Tradeoffs: A is crisp but can feel harsh; B is safer aesthetically but less “flush”; C balances both but adds implementation complexity. Information that changes this: user-provided Apple reference, existing design language elsewhere in the app, and whether the background/material makes hard corners look jagged.
- Decision: How to separate adjacent windows. Options: A) 1px semi-transparent divider line between segments; B) small gap (2–6px) between segments letting the background show through; C) per-window subtle outline/shadow while keeping segments touching. Tradeoffs: A is minimal and maintains a unified bar; B is clearest separation but breaks the continuous-bar look; C can read as “buttons” and may look heavier. Information that changes this: icon density, bar height, and whether the material/background already provides natural separation.

## Implementation Steps
1. Gather and confirm the user inputs above; restate the chosen corner-radius and separation approach before coding.
2. Locate the component/style responsible for rendering windows in flush mode and identify the current corner radius and background/material styling.
3. Implement flush-mode-specific corner styling per the chosen option, ensuring non-flush mode remains unchanged.
4. Add visual separation between windows per the chosen option, handling edge cases: single window (no separators), first/last segment, and dynamic window counts.
5. Verify alignment and interaction: icons remain centered/consistent, spacing doesn’t cause clipping, and pointer/keyboard interactions behave exactly as before.
6. Run the project’s existing build/test commands relevant to the UI change (no new test framework required).
7. Provide a concise before/after description (and screenshots if your workflow supports it) and call out any constants/token values introduced or modified.

## Acceptance Criteria
- In flush mode, window tiles/bars display with square (or explicitly chosen minimal) corners.
- When 2+ windows are present in flush mode, each window is visually separable at a glance without looking like a single continuous bar.
- App icons remain visible, aligned, and unaffected in size/position.
- Non-flush mode styling is unchanged.
- No layout regressions with 1 window, many windows, or varying window titles/icon combinations