# TurboDraft Human Adjudication Workbook — Batch 3 EN R1

## Instructions
- Make your blind decision in this file directly.
- Do not open any AI-assist appendix until the blind pass is finished.
- Required per case: winner + confidence.
- Optional per case: short note.
- Candidate order is randomized per case; do not infer quality from position.

## Confidence rubric
- **High** — clear winner; materially better on multiple important criteria.
- **Medium** — likely winner; better overall, but there is a real tradeoff or ambiguity.
- **Low** — close call; uncertain or difficult to distinguish.

<!-- TD_CASE_META {"case_id": "batch3blind_en_001", "preset_family": "coding", "language_tag": "en-US", "split": "dev", "display_map": {"A": "candidate_b", "B": "candidate_a"}, "seed": "1", "rater_label": "alpha", "integrity_sha256": "367f84f092185f07d71ca129c720ee2b4fbcd34a6a34a1b9ad83efb3664c00d1"} -->
## Case 01

### Draft
```text
Fix the TurboDraft sidebar resize bug so dragging the divider only changes sidebar width, while normal window-edge resizing still works.
```
### Candidate A
```text
Goal / Objective
Fix divider-drag behavior so the sidebar width changes without mutating the app window frame.

Scope and Constraints
- Preserve normal window-edge resizing.
- Keep the fix narrowly scoped to divider-vs-border resize behavior.
- Avoid changing unrelated scrolling or editor interaction paths.

Implementation Steps
1. Trace the divider drag path and identify where window-frame updates occur.
2. Separate divider-width state updates from actual window-edge resize handling.
3. Add regression coverage for divider drags and border drags.
4. Document any remaining ambiguity in the event boundary.

Validation / Acceptance Checks
- Divider drags never resize the whole window.
- Window-edge drags still resize the window.
- No unrelated interaction path changes are introduced.
```
### Candidate B
```text
Goal / Objective
Fix the sidebar divider so divider drags adjust sidebar width only, while genuine window-edge drags continue to control the window frame.

Scope and Constraints
- Preserve current window-edge resizing behavior exactly.
- Keep the change limited to divider-resize behavior and any directly coupled event routing.
- Do not broaden the task into visual or layout polish.

Implementation Steps
1. Compare divider-drag and window-edge-drag event paths and isolate the point where they diverge.
2. Ensure divider drags write only sidebar-width state, while border drags remain the sole path that changes the window frame.
3. Add regression tests that prove the two drag origins stay separate.
4. If coupling remains, report it explicitly instead of compensating with broader resize changes.

Validation / Acceptance Checks
- Divider drag updates sidebar width only.
- Border drag remains the only window-resize path.
- Scope remains limited to the resize bug and directly coupled routing.
```
### Blind decision
Winner:
- [ ] A
- [ ] B
- [ ] Tie
- [ ] BothBad

Confidence:
- [ ] High
- [ ] Medium
- [ ] Low

Optional note:
> 

<!-- TD_CASE_META {"case_id": "batch3blind_en_002", "preset_family": "review", "language_tag": "en-US", "split": "sealed_test", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "1", "rater_label": "alpha", "integrity_sha256": "48f9663347cedfcc8cf511b119e4f127be9aa89b0df118ac7ef3108a0a110eb1"} -->
## Case 02

### Draft
```text
Review why TurboDraft CI is failing again and focus on concrete blockers with evidence, not generic summary or speculative fixes.
```
### Candidate A
```text
Goal / Framing
Review the current CI failure and identify the first true blocker, likely root cause, and missing verification using concrete evidence.

Assumptions / Constraints
- Prioritize real blockers over generic summary.
- Use failing job logs first, then recent config/code changes for corroboration.
- If the evidence remains ambiguous, say so instead of forcing a clean narrative.

Open Questions
- Which job fails first, and what is the first true error?
- Which later failures are only consequences of that first blocker?
- What verification is still missing before a fix can be trusted?

Option Space / Tradeoffs
- Immediate unblock.
- More durable fix that reduces recurrence.
- Temporary containment if the root cause cannot be safely fixed yet.

Recommended Next Steps
- Identify the first failing job and first true error.
- Check whether config/runtime/doc drift contributes to the failure.
- Distinguish evidence-backed fixes from tentative hypotheses.

Evaluation Criteria
- Blockers are evidence-backed.
- Speculation is labeled rather than hidden.
- Remaining verification gaps are visible.
```
### Candidate B
```text
Goal / Framing
Review the current CI failure and identify the first true blocker, the most likely root cause, and the missing verification with evidence.

Assumptions / Constraints
- Prioritize concrete blockers over generic summary.
- Use failing job logs as the primary evidence source.
- When the evidence is incomplete, mark uncertainty instead of overstating confidence.

Open Questions
- Which job failed first and what is the first true error?
- Which downstream errors are only fallout?
- What verification is still missing before calling the issue fixed?

Option Space / Tradeoffs
- Immediate unblock.
- Durable fix.
- Temporary containment.

Recommended Next Steps
- Inspect the first failing job and isolate the first real error.
- Separate direct blockers from downstream fallout.
- Propose fixes only where the evidence supports them.

Evaluation Criteria
- Findings are specific.
- Evidence is primary, not speculative.
- Missing verification is explicit.
```
### Blind decision
Winner:
- [ ] A
- [ ] B
- [ ] Tie
- [ ] BothBad

Confidence:
- [ ] High
- [ ] Medium
- [ ] Low

Optional note:
> 

<!-- TD_CASE_META {"case_id": "batch3blind_en_003", "preset_family": "brainstorm", "language_tag": "en-US", "split": "tune", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "1", "rater_label": "alpha", "integrity_sha256": "14cd9ebfd204e89b7ef7d7d344a6a1d72ad06d49e7898c9a9e1c138f1c601fe0"} -->
## Case 03

### Draft
```text
Brainstorm whether presets should be split by family only or family plus profile, and make sure the analysis includes tradeoffs and falsifiable experiments.
```
### Candidate A
```text
Goal / Framing
Brainstorm whether prompt presets should be organized by family only or by family plus profile, with explicit tradeoffs and falsifiable validation experiments.

Assumptions / Constraints
- Do not assume either architecture is correct up front.
- Separate conceptual clarity from maintenance burden and user-facing complexity.
- Keep recommendations tied to observable product consequences.

Open Questions
- What does family-only simplify or sacrifice?
- What does family+profile enable or complicate?
- Which assumptions can be tested cheaply before the architecture is locked?

Option Space / Tradeoffs
- Family-only presets.
- Family+profile matrix.
- Hybrid starter taxonomy.
- Contrarian option: defer taxonomy expansion until eval evidence is stronger.

Recommended Next Steps
- Define the minimum experiments that could falsify the current architecture belief.
- Specify how user confusion and maintenance overhead would be observed in each option.
- Recommend the lowest-cost test sequence before committing.

Evaluation Criteria
- Options are genuinely distinct.
- Tradeoffs are concrete.
- Next steps are falsifiable rather than preference-driven.
```
### Candidate B
```text
Goal / Framing
Brainstorm whether prompt presets should be organized by family only or by family plus profile, with explicit tradeoffs and falsifiable validation experiments.

Assumptions / Constraints
- Do not assume either architecture is correct up front.
- Keep recommendations tied to user-facing complexity and maintenance cost.
- Avoid converging too early on a preferred design.

Open Questions
- What does family-only simplify or sacrifice?
- What does family+profile enable or complicate?
- Which assumptions can be tested cheaply before locking architecture?

Option Space / Tradeoffs
- Family-only presets.
- Family+profile matrix.
- Hybrid starter taxonomy.

Recommended Next Steps
- Define low-cost experiments that could falsify the current architectural belief.
- Compare user confusion risk against maintenance overhead.
- Sequence experiments before any final commitment.

Evaluation Criteria
- Options are distinct.
- Tradeoffs are concrete.
- Next steps are falsifiable.
```
### Blind decision
Winner:
- [ ] A
- [ ] B
- [ ] Tie
- [ ] BothBad

Confidence:
- [ ] High
- [ ] Medium
- [ ] Low

Optional note:
> 

<!-- TD_CASE_META {"case_id": "batch3blind_en_004", "preset_family": "legacy", "language_tag": "en-US", "split": "dev", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "1", "rater_label": "alpha", "integrity_sha256": "d97054abf489ee9870f3f8bf4fe11cbb171937fb017ab727d33320ea630f279a"} -->
## Case 04

### Draft
```text
Modernize the legacy preset language without changing its intended behavior or removing its protective guardrails.
```
### Candidate A
```text
Goal / Objective
Modernize the legacy preset language while preserving its intended behavior and protective guardrails.

Scope and Constraints
- Preserve behavioral intent and guardrails.
- Improve clarity, terminology, and redundancy only when meaning stays unchanged.
- Surface any potentially obsolete guardrail as a flagged follow-up rather than treating it as an in-scope rewrite decision.

Implementation Steps
1. Identify outdated wording, duplicated phrasing, and ambiguous terminology.
2. Rewrite for clarity while preserving guardrail semantics.
3. Separate modernization edits from flagged follow-up questions about possible cleanup.
4. Add a semantic review or diff check that looks for boundary drift.

Validation / Acceptance Checks
- Behavioral intent is preserved.
- Guardrails remain intact unless explicitly approved otherwise.
- Readability improves without narrowing or broadening protections.
```
### Candidate B
```text
Goal / Objective
Modernize the legacy preset language while preserving its intended behavior, boundary conditions, and protective guardrails.

Scope and Constraints
- Preserve behavioral intent and guardrails.
- Improve clarity and terminology only when meaning is unchanged.
- Flag potentially obsolete guardrails separately instead of rewriting behavior around them.

Implementation Steps
1. Identify outdated wording and ambiguous terminology.
2. Rewrite for clarity while preserving guardrail semantics.
3. Separate possible cleanup opportunities from the main modernization pass.
4. Add a semantic review step that checks for drift.

Validation / Acceptance Checks
- Behavioral intent is preserved.
- Guardrails remain intact.
- Modernization improves readability without changing boundaries.
```
### Blind decision
Winner:
- [ ] A
- [ ] B
- [ ] Tie
- [ ] BothBad

Confidence:
- [ ] High
- [ ] Medium
- [ ] Low

Optional note:
> 
