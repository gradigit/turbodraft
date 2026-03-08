# TurboDraft Guided Blind Core Workbook — Batch4 EN R2

## Instructions
- This is the **guided blind core** lane for lock-grade human evidence.
- Use the checklist as a reading aid, but make your own decision.
- Do not open any AI-assisted workbook or appendix first.
- Required per case: winner + confidence.
- Optional per case: short note.
- If both candidates seem acceptable, use the checklist to identify which one is less likely to fail the draft.
- If you still genuinely cannot tell, choose `Tie` with `Low` confidence.

## Confidence rubric
- **High** — one candidate clearly satisfies the draft better with fewer obvious risks.
- **Medium** — likely winner, but there is a real tradeoff or ambiguity.
- **Low** — still hard to distinguish from text alone.

<!-- TD_CASE_META {"case_id": "batch3blind_en_001", "preset_family": "coding", "language_tag": "en-US", "split": "dev", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "11", "rater_label": "eta", "lane": "guided_blind_core", "content_sha256": "5196bb1ace50c272bd98ca8bd3ebc0c3df910edce6a0f32bc051afd2f24165eb", "integrity_sha256": "fe34afaa98fc7cd0b5720b8857513562d61ddca8ba5ead2ea7bdddb3102a32f0"} -->
## Case 01

### Draft
```text
Fix the TurboDraft sidebar resize bug so dragging the divider only changes sidebar width, while normal window-edge resizing still works.
```
### Why this case matters
> The human does not need to decide which prompt is 'more expert'; only which one is less likely to break the requested resize behavior.
### Quick checklist
- Does it clearly separate divider-drag behavior from true window-edge resizing?
- Does it preserve normal border resize behavior?
- Does it keep scope narrow instead of adding unrelated layout polish?
### Disqualifiers to look for
- Vague about which drag path resizes the window
- Expands scope beyond the resize bug
- Fails to require regression checks for divider vs border drags
### Candidate A
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
### Candidate B
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

<!-- TD_CASE_META {"case_id": "batch3blind_en_002", "preset_family": "review", "language_tag": "en-US", "split": "sealed_test", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "11", "rater_label": "eta", "lane": "guided_blind_core", "content_sha256": "87955c82c8b81da6578642d59a31f0572213d014c48716e7d5c1a197c2d1ba66", "integrity_sha256": "2dde1e794006ee539dcd280c5bfe7ec41a99639c4fc749948fd38cc122a37ad5"} -->
## Case 02

### Draft
```text
Review why TurboDraft CI is failing again and focus on concrete blockers with evidence, not generic summary or speculative fixes.
```
### Why this case matters
> The task is to diagnose CI failures with evidence, not to produce a generic review or speculative fix list.
### Quick checklist
- Does it ask for concrete blockers backed by evidence?
- Does it avoid generic summary or speculative fixes?
- Does it keep the task focused on diagnosis before proposing changes?
### Disqualifiers to look for
- Generic prose without evidence requirements
- Speculative fixes before identifying blockers
- Loses the 'concrete blockers only' requirement
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

<!-- TD_CASE_META {"case_id": "batch3blind_en_003", "preset_family": "brainstorm", "language_tag": "en-US", "split": "tune", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "11", "rater_label": "eta", "lane": "guided_blind_core", "content_sha256": "571d48b83c36186da403e50cda8a012d2f61c09afdddb3b286df7532b0aa48eb", "integrity_sha256": "133399d558bfa91ad9ad76361eeaedd08c713a0f7ca7e0d2a260867514c10447"} -->
## Case 03

### Draft
```text
Brainstorm whether presets should be split by family only or family plus profile, and make sure the analysis includes tradeoffs and falsifiable experiments.
```
### Why this case matters
> A good prompt here should preserve open exploration and force the analysis to be testable rather than opinion-only.
### Quick checklist
- Does it compare family-only vs family-plus-profile instead of assuming one answer?
- Does it include tradeoffs?
- Does it require falsifiable experiments or a way to test the recommendation?
### Disqualifiers to look for
- Assumes a single architecture too early
- Drops tradeoffs or experiments
- Turns brainstorming into a one-sided recommendation
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
