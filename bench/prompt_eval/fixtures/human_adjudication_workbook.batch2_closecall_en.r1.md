# TurboDraft Human Adjudication Workbook — Batch 2 Close-Call English

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

<!-- TD_CASE_META {"case_id": "batch2v2_coding_sidebar_en_dev", "preset_family": "coding", "language_tag": "en-US", "split": "dev", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "20260306", "rater_label": "r1"} -->
## Case 01 — `batch2v2_coding_sidebar_en_dev`
- Preset family: `coding`
- Language: `en-US`
- Split target: `dev`

### Draft
```text
Fix the TurboDraft sidebar resize bug so dragging the divider only changes sidebar width, while normal window-edge resizing still works.
```
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

<!-- TD_CASE_META {"case_id": "batch2v2_refactor_provider_en_tune", "preset_family": "refactor", "language_tag": "en-US", "split": "tune", "display_map": {"A": "candidate_b", "B": "candidate_a"}, "seed": "20260306", "rater_label": "r1"} -->
## Case 02 — `batch2v2_refactor_provider_en_tune`
- Preset family: `refactor`
- Language: `en-US`
- Split target: `tune`

### Draft
```text
Refactor provider contract loading so judge baseline changes happen in one place without drifting across manifests, defaults, and docs.
```
### Candidate A
```text
Goal / Objective
Refactor provider-contract loading so judge-baseline changes are defined once and propagate consistently across manifests, runtime defaults, and docs.

Scope and Constraints
- Reduce drift in judge-baseline configuration specifically.
- Preserve drafting-model defaults unless a separate requirement changes them.
- Keep ownership explicit enough that judge-target changes are easy to audit.

Implementation Steps
1. Inventory every active location where judge baseline values are encoded.
2. Centralize or derive those judge defaults from one maintained source.
3. Update dependent manifests, helpers, and docs consistently.
4. Add regression coverage that fails when judge-baseline values drift.

Validation / Acceptance Checks
- Judge baseline can be changed in one maintained place.
- Drafting baseline stays unchanged unless intentionally edited.
- Drift between manifests/runtime/docs is caught by tests.
```
### Candidate B
```text
Goal / Objective
Refactor provider-configuration loading so baseline changes are managed from one coherent source and drift is reduced across manifests, runtime defaults, and docs.

Scope and Constraints
- Reduce duplicated baseline configuration across active provider roles.
- Preserve existing role-specific overrides where they already exist.
- Keep the resulting ownership understandable in code and tests.

Implementation Steps
1. Inventory active baseline definitions across judge and drafting roles.
2. Consolidate shared baseline data where the values are meant to move together.
3. Preserve explicit role-specific settings where they are intentionally separate.
4. Add tests that fail when manifest/runtime/doc defaults diverge.

Validation / Acceptance Checks
- Baseline drift is reduced.
- Intentional role-specific settings still work.
- Baseline ownership is auditable.
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

<!-- TD_CASE_META {"case_id": "batch2v2_review_ci_en_sealed", "preset_family": "review", "language_tag": "en-US", "split": "sealed_test", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "20260306", "rater_label": "r1"} -->
## Case 03 — `batch2v2_review_ci_en_sealed`
- Preset family: `review`
- Language: `en-US`
- Split target: `sealed_test`

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

<!-- TD_CASE_META {"case_id": "batch2v2_research_judge_en_dev", "preset_family": "research", "language_tag": "en-US", "split": "dev", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "20260306", "rater_label": "r1"} -->
## Case 04 — `batch2v2_research_judge_en_dev`
- Preset family: `research`
- Language: `en-US`
- Split target: `dev`

### Draft
```text
Research whether this judge-eval design is actually valid for prompt engineering quality. Separate real-primary evidence from synthetic sanity checks.
```
### Candidate A
```text
Goal / Framing
Research whether the judge-eval design is valid for prompt-engineering quality, separating real-primary evidence from synthetic sanity checks.

Assumptions / Constraints
- Real engineered prompts are the primary evidence lane.
- Synthetic perturbations may remain only as a secondary sanity arm.
- Recommendations should stay tied to what would change lock trustworthiness.

Open Questions
- Which current metrics measure real prompt-quality judgment versus perturbation detection?
- Where could the design create false confidence?
- Which evidence gaps block a trustworthy lock decision?

Option Space / Tradeoffs
- Minimal salvage path.
- Stronger redesign around real-primary adjudication.
- Hybrid path that keeps synthetic sanity evidence secondary.

Recommended Next Steps
- Label each evidence path primary or secondary.
- Check whether the design still works on close-call prompt pairs.
- Compare improvement cost against lock-risk reduction.

Evaluation Criteria
- Primary vs secondary evidence is explicit.
- Risk of false confidence is concrete.
- Recommendations connect to lock decisions.
```
### Candidate B
```text
Goal / Framing
Research whether the judge-eval design is valid for prompt-engineering quality, explicitly distinguishing lock-grade primary evidence from secondary synthetic sanity evidence.

Assumptions / Constraints
- Real engineered prompt comparisons are the primary ground-truth lane.
- Synthetic perturbation checks may support robustness claims but cannot stand in for primary validity.
- If the current design cannot justify the intended trust level, say so directly.

Open Questions
- Which components measure real prompt-engineering judgment rather than obvious perturbation detection?
- Where does the current design risk overstating judge quality?
- What evidence is missing before lock decisions become trustworthy?

Option Space / Tradeoffs
- Minimal salvage path.
- Stronger redesign centered on real-primary adjudication.
- Hybrid design that preserves synthetic sanity checks as clearly secondary evidence.

Recommended Next Steps
- Mark every metric path as primary or secondary evidence.
- Stress-test the design on close-call prompt pairs.
- Include at least one adversarial counter-hypothesis check before recommending lock trust.

Evaluation Criteria
- Primary vs secondary evidence is explicit.
- Failure modes are concrete.
- Recommendations are evidence-backed rather than optimistic.
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

<!-- TD_CASE_META {"case_id": "batch2v2_brainstorm_arch_en_tune", "preset_family": "brainstorm", "language_tag": "en-US", "split": "tune", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "20260306", "rater_label": "r1"} -->
## Case 05 — `batch2v2_brainstorm_arch_en_tune`
- Preset family: `brainstorm`
- Language: `en-US`
- Split target: `tune`

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

<!-- TD_CASE_META {"case_id": "batch2v2_legacy_en_dev", "preset_family": "legacy", "language_tag": "en-US", "split": "dev", "display_map": {"A": "candidate_b", "B": "candidate_a"}, "seed": "20260306", "rater_label": "r1"} -->
## Case 06 — `batch2v2_legacy_en_dev`
- Preset family: `legacy`
- Language: `en-US`
- Split target: `dev`

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
