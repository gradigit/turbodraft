# TurboDraft Human Adjudication Workbook — Batch 2 Hard English

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

<!-- TD_CASE_META {"case_id": "batch2_coding_sidebar_en_dev", "preset_family": "coding", "language_tag": "en-US", "split": "dev", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "20260306", "rater_label": "r1"} -->
## Case 01 — `batch2_coding_sidebar_en_dev`
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
Fix sidebar-divider resizing so divider drags adjust only sidebar width, while true window-edge drags continue to resize the window normally.

Scope and Constraints
- Preserve existing window-edge resize behavior.
- Do not change unrelated layout, scrolling, or chrome behavior.
- Allow extreme narrow sidebar widths without breaking layout.

Implementation Steps
1. Trace divider-drag vs window-edge-drag event paths and confirm where window-frame mutation occurs.
2. Update divider handling so it mutates only sidebar width state.
3. Keep window resizing owned by actual window-edge interactions.
4. Add regression coverage that distinguishes divider drags from border drags.

Validation / Acceptance Checks
- Divider drag changes sidebar width only.
- Window-edge drag still resizes the app window.
- Very narrow sidebar widths do not break layout.
- If the fix requires changing unrelated resize behavior, stop and report that coupling.
```
### Candidate B
```text
Goal / Objective
Correct the sidebar resizing behavior so divider drags primarily control sidebar width while the window remains normally resizable.

Scope and Constraints
- Preserve normal window resizing in typical use.
- If the divider interaction feels awkward after the fix, you may also tune splitter affordance behavior as long as it remains lightweight.
- Keep the layout stable at smaller widths.

Implementation Steps
1. Inspect the current resize interaction path and separate divider logic from window-frame updates where practical.
2. Adjust divider behavior to prefer sidebar-width changes.
3. Manually verify that common window resizing still feels normal.
4. Add targeted regression coverage if the event path is easy to isolate.

Validation / Acceptance Checks
- Divider drags no longer usually resize the whole window.
- Window resizing remains usable.
- Layout stays stable at small widths.
- Report any tradeoff if exact behavior differs by drag origin.
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

<!-- TD_CASE_META {"case_id": "batch2_refactor_provider_en_tune", "preset_family": "refactor", "language_tag": "en-US", "split": "tune", "display_map": {"A": "candidate_b", "B": "candidate_a"}, "seed": "20260306", "rater_label": "r1"} -->
## Case 02 — `batch2_refactor_provider_en_tune`
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
Refactor provider-contract loading so model baseline changes are derived from one coherent source instead of drifting across files.

Scope and Constraints
- Reduce duplicated baseline configuration across judge and drafting roles where possible.
- Prefer one shared default path unless role-specific divergence is clearly necessary.
- Keep manifests, runtime helpers, and docs aligned.

Implementation Steps
1. Inventory baseline defaults across judge and drafting roles.
2. Collapse duplicated defaults into one shared configuration path where feasible.
3. Update dependent manifests/helpers/docs.
4. Add regression tests for drift.

Validation / Acceptance Checks
- Baseline changes can be applied from one source.
- Drift is reduced across files.
- Role-specific divergence remains possible if later needed.
- Report any remaining duplication.
```
### Candidate B
```text
Goal / Objective
Refactor provider-contract loading so judge-baseline changes are defined once and propagate consistently across manifests, runtime defaults, and docs.

Scope and Constraints
- Reduce drift in judge-baseline configuration only.
- Preserve drafting-model defaults unless an explicit requirement says otherwise.
- Keep the resulting ownership model easy to audit in code and tests.

Implementation Steps
1. Inventory every active location where judge baseline defaults are encoded.
2. Centralize or derive those judge defaults from a single maintained source.
3. Update dependent manifests/helpers/docs consistently.
4. Add regression coverage that fails if judge baseline values drift again.

Validation / Acceptance Checks
- Judge baseline can be changed in one maintained place.
- Drafting baseline is unchanged unless intentionally updated.
- Drift between manifests/runtime/docs is caught by tests.
- If centralization creates ambiguous ownership, stop and report it.
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

<!-- TD_CASE_META {"case_id": "batch2_review_ci_en_sealed", "preset_family": "review", "language_tag": "en-US", "split": "sealed_test", "display_map": {"A": "candidate_b", "B": "candidate_a"}, "seed": "20260306", "rater_label": "r1"} -->
## Case 03 — `batch2_review_ci_en_sealed`
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
Review the current CI failure and determine the most plausible blocker and fix path.

Assumptions / Constraints
- Prefer real evidence from logs when available.
- If logs are noisy, infer the likely root cause from recent diffs and failure shape.
- Keep the review actionable rather than overly cautious.

Open Questions
- Which job appears to fail first?
- What change most likely triggered it?
- What fix is probably required?

Option Space / Tradeoffs
- Fast unblock.
- Durable fix.
- Revert or containment path.

Recommended Next Steps
- Inspect logs and recent changes together.
- Form a likely root-cause hypothesis.
- Suggest the most probable fix and note what still needs confirmation.

Evaluation Criteria
- Review is actionable.
- Hypothesis fits the available evidence.
- Remaining unknowns are noted.
```
### Candidate B
```text
Goal / Framing
Review the current CI failure and identify the first true blocker, likely root cause, and missing verification with evidence.

Assumptions / Constraints
- Prioritize concrete blockers over generic summary.
- Use failing job logs and repo state as primary evidence.
- If evidence is insufficient, say so instead of guessing.

Open Questions
- Which job failed first, and what is the first true error?
- Is the failure caused by environment drift, config drift, or code regression?
- What verification is still missing before calling the issue fixed?

Option Space / Tradeoffs
- Minimal unblock for the immediate failure.
- Durable fix that reduces recurrence.
- Temporary containment if the safe root-cause fix is not ready.

Recommended Next Steps
- Identify the first failing job and first true error.
- Validate whether later errors are only downstream fallout.
- Check for config/docs/runtime drift tied to the failure.
- Propose fixes only when backed by evidence.

Evaluation Criteria
- Blockers are specific and evidence-backed.
- Speculation is clearly labeled or avoided.
- Missing verification is made explicit.
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

<!-- TD_CASE_META {"case_id": "batch2_research_judge_en_dev", "preset_family": "research", "language_tag": "en-US", "split": "dev", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "20260306", "rater_label": "r1"} -->
## Case 04 — `batch2_research_judge_en_dev`
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
Research whether the judge-eval design is valid for prompt-engineering quality, explicitly separating real-primary evidence from synthetic sanity checks.

Assumptions / Constraints
- Real engineered prompts are the primary evidence lane.
- Synthetic perturbations may be used only as secondary sanity evidence.
- If the design cannot justify judge lock for the true goal, say so explicitly.

Open Questions
- Which parts of the design measure real prompt-engineering quality vs only obvious perturbation detection?
- What evidence is required before trusting lock decisions?
- Where could the current eval design create false confidence?

Option Space / Tradeoffs
- Minimal changes that salvage the design.
- Stronger redesign centered on real-primary adjudication.
- Hybrid design with synthetic sanity retained as secondary evidence only.

Recommended Next Steps
- Distinguish primary vs secondary evidence in every metric path.
- Stress-test whether the design would still work on close-call prompt pairs.
- Include at least one adversarial counter-hypothesis check.
- Stop and report if the current design still over-weights synthetic evidence.

Evaluation Criteria
- Primary vs secondary evidence is explicit.
- Failure modes are concrete.
- Recommendations are grounded in evidence, not optimism.
```
### Candidate B
```text
Goal / Framing
Research whether the judge-eval design is valid for prompt quality and suggest improvements.

Assumptions / Constraints
- Consider both synthetic and real prompt examples.
- Try to keep the existing design where possible.
- Focus on practical recommendations.

Open Questions
- What works well already?
- Where are the biggest design weaknesses?
- What changes would improve reliability?

Option Space / Tradeoffs
- Keep most of the design.
- Redesign major parts.
- Use a hybrid approach.

Recommended Next Steps
- Review current metrics and datasets.
- Compare them with best practices.
- Recommend targeted improvements.

Evaluation Criteria
- Recommendations are practical.
- Weaknesses are identified.
- Reliability likely improves.
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

<!-- TD_CASE_META {"case_id": "batch2_brainstorm_arch_en_tune", "preset_family": "brainstorm", "language_tag": "en-US", "split": "tune", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "20260306", "rater_label": "r1"} -->
## Case 05 — `batch2_brainstorm_arch_en_tune`
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
- Distinguish conceptual clarity from maintenance cost and user-facing complexity.
- Keep recommendations tied to testable product consequences.

Open Questions
- What does family-only simplify or sacrifice?
- What does family+profile enable or complicate?
- Which assumptions can be tested cheaply before locking architecture?

Option Space / Tradeoffs
- Family-only presets.
- Family+profile matrix.
- Hybrid path with a smaller starter taxonomy.
- Contrarian option: avoid preset taxonomy expansion until eval evidence is stronger.

Recommended Next Steps
- List the minimum experiments that could falsify the current architecture belief.
- Define what user confusion and maintenance overhead would look like in each option.
- Recommend the lowest-cost test sequence before committing.

Evaluation Criteria
- Options are genuinely distinct.
- Tradeoffs are concrete.
- Next steps are falsifiable, not just opinionated.
```
### Candidate B
```text
Goal / Framing
Brainstorm whether presets should be organized by family only or by family plus profile, and recommend the cleaner architecture.

Assumptions / Constraints
- Simplicity for users should be weighted heavily.
- Maintenance cost matters.
- Try to converge on a recommendation.

Open Questions
- Which architecture is simpler?
- Which architecture is easier to maintain?
- Which one should probably be chosen?

Option Space / Tradeoffs
- Family-only presets.
- Family+profile presets.
- A hybrid option.

Recommended Next Steps
- Compare the options.
- Pick the one that seems best.
- Outline a rollout plan.

Evaluation Criteria
- Recommendation is clear.
- Tradeoffs are noted.
- Rollout seems feasible.
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

<!-- TD_CASE_META {"case_id": "batch2_legacy_en_dev", "preset_family": "legacy", "language_tag": "en-US", "split": "dev", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "20260306", "rater_label": "r1"} -->
## Case 06 — `batch2_legacy_en_dev`
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
Modernize the legacy preset language while preserving its intended behavior, boundary conditions, and protective guardrails.

Scope and Constraints
- Preserve behavioral intent and explicit protections.
- Improve clarity, terminology, and redundancy only when meaning is unchanged.
- If a legacy guardrail appears obsolete, flag it instead of silently removing it.

Implementation Steps
1. Identify outdated wording, duplicated phrasing, and unclear terminology.
2. Rewrite for clarity while preserving constraint meaning.
3. Mark any potentially obsolete guardrails separately rather than deleting them by default.
4. Add tests or diff checks that detect semantic drift.

Validation / Acceptance Checks
- Behavioral intent is preserved.
- Guardrails are retained unless explicitly approved for removal.
- Modernization improves readability without broadening scope.
- Any uncertain guardrail is surfaced, not silently dropped.
```
### Candidate B
```text
Goal / Objective
Modernize the legacy preset so it is clearer, leaner, and easier to maintain.

Scope and Constraints
- Preserve the main intent of the preset.
- Remove wording that seems redundant or overly defensive if it no longer appears necessary.
- Prefer a cleaner prompt over carrying forward historical baggage.

Implementation Steps
1. Identify outdated wording and redundancy.
2. Rewrite for clarity and concision.
3. Remove defensive phrasing that seems unnecessary.
4. Check that the result still reflects the overall intent.

Validation / Acceptance Checks
- Prompt is clearer and shorter.
- Main intent is still present.
- Obvious legacy baggage is removed.
- Report any major uncertainty.
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
