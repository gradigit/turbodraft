# TurboDraft Prompt Eval — Batch4 Guided Core (English, AI-Assisted R1)

> This is the **AI-assisted expansion lane**.
> It is useful for throughput and disagreement analysis, but it is **not lock-grade blind evidence**.

## Instructions
- Review the AI assessment, then record your own final decision in this file.
- Required per case: relation to AI + final winner + confidence.
- Optional per case: short note.
- Use this lane when the blind-only task is too difficult for a non-expert rater.

## Confidence rubric
- **High** — you clearly agree or clearly reject the AI assessment.
- **Medium** — you have a likely decision, but there is real ambiguity.
- **Low** — still difficult; good candidate for expert review or execution-based check.

<!-- TD_CASE_META {"case_id": "batch3blind_en_001", "preset_family": "coding", "language_tag": "en-US", "split": "dev", "display_map": {"A": "candidate_b", "B": "candidate_a"}, "assist_model_label": "Auggie GPT-5.4", "assist_display_winner": "B", "assist_canonical_winner": "A", "assist_confidence": "Medium", "integrity_sha256": "ed600c6a1e789af0fa4e1f9332367120ed3603036e8c640ec092405b0fd3a7b0"} -->
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
### AI assessment
- Model: Auggie GPT-5.4
- AI pick: B
- AI confidence: Medium
- AI rationale: B preserves the draft more precisely with a clearer execution contract and fewer fabricated side constraints than A.

### Human final decision
Relation to AI:
- [ ] Agree
- [ ] Disagree / override

Final winner:
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

<!-- TD_CASE_META {"case_id": "batch3blind_en_002", "preset_family": "review", "language_tag": "en-US", "split": "sealed_test", "display_map": {"A": "candidate_b", "B": "candidate_a"}, "assist_model_label": "Auggie GPT-5.4", "assist_display_winner": "A", "assist_canonical_winner": "B", "assist_confidence": "Medium", "integrity_sha256": "800b304dde296bf922edd19a988292421e4342d08d51e75bbea926b7bf4e8f4d"} -->
## Case 02

### Draft
```text
Review why TurboDraft CI is failing again and focus on concrete blockers with evidence, not generic summary or speculative fixes.
```
### Candidate A
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
### Candidate B
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
### AI assessment
- Model: Auggie GPT-5.4
- AI pick: A
- AI confidence: Medium
- AI rationale: A stays closer to the draft with a tighter evidence-first execution contract and less added scope than B’s extra config/runtime/doc-drift and recurrence framing.

### Human final decision
Relation to AI:
- [ ] Agree
- [ ] Disagree / override

Final winner:
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

<!-- TD_CASE_META {"case_id": "batch3blind_en_003", "preset_family": "brainstorm", "language_tag": "en-US", "split": "tune", "display_map": {"A": "candidate_b", "B": "candidate_a"}, "assist_model_label": "Auggie GPT-5.4", "assist_display_winner": "A", "assist_canonical_winner": "B", "assist_confidence": "Medium", "integrity_sha256": "141fbd25496721b036922fbaf452944ef37e95b6c492f4c38cc985446e7ad407"} -->
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
### Candidate B
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
### AI assessment
- Model: Auggie GPT-5.4
- AI pick: A
- AI confidence: Medium
- AI rationale: A stays closer to the draft while remaining actionable, whereas B slightly broadens scope with an extra decision path.

### Human final decision
Relation to AI:
- [ ] Agree
- [ ] Disagree / override

Final winner:
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
