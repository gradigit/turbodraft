# TurboDraft Human Adjudication Packet — Batch 1 (English)
## Reviewer Instructions

Use this packet together with the companion CSV answer sheet. Read the draft, compare Candidate A vs Candidate B, and record your decision in the CSV.

### Decision rules

- Prefer the prompt that better preserves the user objective, constraints, and usable output contract.
- Use `Tie` only when the prompts are genuinely equivalent in engineering quality.
- Use `BothBad` only when both prompts are materially unacceptable.
- Leave short notes whenever you choose `Tie`, `BothBad`, or confidence <= 2.
- Unresolved `Tie` / `BothBad` cases must go to tie-break review before canonical import.

### Recommended batch size

- 20–30 pairwise cases per packet
- 2 primary raters + 1 tie-breaker on disagreements
- Randomized A/B order; do not infer quality from position
- Reviewer packets are blinded to source metadata and seed expectations by default

### Defect taxonomy

- `missing_constraint` — Drops or weakens an explicit requirement or constraint.
- `scope_fabrication` — Adds meaningful scope that was not requested.
- `structural_noncompliance` — Misses required sections or output structure.
- `unverifiable_output` — Does not define a checkable deliverable or validation path.
- `prompt_injection_leak` — Treats quoted/untrusted text as instructions.
- `ambiguity` — Leaves important choices underspecified or unclear.
- `verbosity_bloat` — Adds unnecessary filler or bloated prose.
- `language_mismatch` — Uses the wrong language or mishandles bilingual requirements.
- `tool_mismatch` — Assumes the wrong tools/agent capabilities.
- `other` — Another defect not covered above; explain in notes.

## Case 1 — `batch1_coding_sidebar_resize_en_dev`

- Preset family: `coding`
- Language: `en-US`
- Split target: `dev`

### Draft

```text
Fix the TurboDraft sidebar resize bug so dragging the sidebar divider never resizes the whole app window, and keep normal window-edge resizing working.
```

### Candidate A

```text
Goal / Objective
Fix the sidebar divider so dragging it changes only sidebar width and never mutates the app window frame.

Scope and Constraints
- Preserve normal resize behavior when the user drags the actual window border.
- Do not change unrelated layout or scrolling behavior.
- Keep the layout stable even when the sidebar becomes extremely narrow.

Implementation Steps
1. Trace the divider-drag event path and identify where it mutates window size.
2. Change divider drag handling so it updates only the sidebar width state.
3. Preserve independent window-edge resizing.
4. Add regression coverage for divider drag vs window-edge drag.

Validation / Acceptance Checks
- Divider drag changes sidebar width only.
- Window-edge drag still resizes the window.
- Very narrow widths do not break layout.
- If the fix causes layout regressions, stop and report the failing condition.
```

### Candidate B

```text
Fix the sidebar resize behavior and make the whole editor layout feel better if anything else looks off.
```

### Fill-in checklist

- Winner
  - [ ] A
  - [ ] B
  - [ ] Tie
  - [ ] BothBad
- Quality A (0-100): ______
- Quality B (0-100): ______
- Confidence (1-5): ______
- Defect tags A (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Defect tags B (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Notes:
  - ____________________________________________
  - ____________________________________________

## Case 2 — `batch1_coding_promptfoo_runner_en_tune`

- Preset family: `coding`
- Language: `en-US`
- Split target: `tune`

### Draft

```text
Add a Promptfoo-based benchmark flow that uses local CLIs instead of API keys and records judge reliability metrics.
```

### Candidate A

```text
Build a Promptfoo benchmark with local CLIs. Make it flexible and cover everything related to prompt evaluation.
```

### Candidate B

```text
Goal / Objective
Implement a Promptfoo benchmark path that uses local agent CLIs instead of API-key-only providers and records judge reliability metrics.

Scope and Constraints
- Use the existing CLI provider wrapper pattern when possible.
- Record invalid JSON, runtime/provider errors, and timeout statistics.
- Do not break simulated/non-promotable local smoke paths.

Implementation Steps
1. Inspect current Promptfoo provider integration and identify where CLI-backed providers are already wired.
2. Extend or reuse that integration for the new benchmark flow.
3. Ensure run artifacts include judge reliability telemetry.
4. Add tests covering successful execution and provider-failure handling.

Validation / Acceptance Checks
- Benchmark runs through local CLI providers without requiring API keys.
- Reliability metrics are emitted in artifacts.
- Existing smoke paths still work.
- If provider failures are swallowed or misclassified, stop and report it.
```

### Fill-in checklist

- Winner
  - [ ] A
  - [ ] B
  - [ ] Tie
  - [ ] BothBad
- Quality A (0-100): ______
- Quality B (0-100): ______
- Confidence (1-5): ______
- Defect tags A (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Defect tags B (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Notes:
  - ____________________________________________
  - ____________________________________________

## Case 3 — `batch1_refactor_provider_contract_en_dev`

- Preset family: `refactor`
- Language: `en-US`
- Split target: `dev`

### Draft

```text
Refactor provider contract loading so active judge model changes can be made in one place without drift across manifests and defaults.
```

### Candidate A

```text
Refactor the provider config setup and clean up anything that feels duplicated.
```

### Candidate B

```text
Goal / Objective
Refactor provider contract loading so active judge-model changes are defined once and propagated consistently across manifests, defaults, and docs.

Scope and Constraints
- Reduce drift between provider contract files, manifest defaults, and runtime helpers.
- Preserve current behavior except for intentional baseline-target updates.
- Do not silently change drafting-model defaults unless explicitly required.

Implementation Steps
1. Inventory every active location where judge-model defaults are encoded.
2. Centralize or derive shared defaults to reduce drift.
3. Update dependent code paths and docs consistently.
4. Add regression coverage that fails when active defaults diverge.

Validation / Acceptance Checks
- Judge-model target can be changed in one maintained source of truth or one tightly governed path.
- Drift tests fail closed when configs disagree.
- Drafting defaults stay unchanged unless intentionally updated.
- If centralization creates hidden coupling, stop and document it.
```

### Fill-in checklist

- Winner
  - [ ] A
  - [ ] B
  - [ ] Tie
  - [ ] BothBad
- Quality A (0-100): ______
- Quality B (0-100): ______
- Confidence (1-5): ______
- Defect tags A (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Defect tags B (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Notes:
  - ____________________________________________
  - ____________________________________________

## Case 4 — `batch1_review_ci_failure_en_sealed`

- Preset family: `review`
- Language: `en-US`
- Split target: `sealed_test`

### Draft

```text
Review why the TurboDraft GitHub CI is failing again and focus on real blockers, not generic summary.
```

### Candidate A

```text
Review the CI failure and summarize what happened.
```

### Candidate B

```text
Goal / Framing
Review the current CI failure and identify concrete blockers, likely root causes, and missing verification.

Assumptions / Constraints
- Prioritize real failure causes over generic summary.
- Call out behavioral regressions, missing tests, and config drift first.
- If evidence is insufficient, say so instead of guessing.

Open Questions
- Which job failed first and why?
- Is the failure caused by environment drift, model/config drift, or code regression?
- What verification is missing to prove the fix?

Option Space / Tradeoffs
- Minimal fix for the immediate failure.
- More durable fix that reduces config drift.
- Temporary containment if the root cause cannot be safely fixed yet.

Recommended Next Steps
- Inspect failing job logs and identify the first true error.
- Check whether active config/docs drifted from expected defaults.
- Verify the proposed fix with the relevant targeted tests.

Evaluation Criteria
- Root-cause specificity
- Regression awareness
- Test/verification completeness
- Avoidance of guesswork
```

### Fill-in checklist

- Winner
  - [ ] A
  - [ ] B
  - [ ] Tie
  - [ ] BothBad
- Quality A (0-100): ______
- Quality B (0-100): ______
- Confidence (1-5): ______
- Defect tags A (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Defect tags B (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Notes:
  - ____________________________________________
  - ____________________________________________

## Case 5 — `batch1_research_judge_design_en_tune`

- Preset family: `research`
- Language: `en-US`
- Split target: `tune`

### Draft

```text
Figure out whether our judge-lock eval design is valid, especially whether it really measures prompt engineering quality instead of just structural compliance.
```

### Candidate A

```text
Research whether our judge eval is good and explain the pros and cons.
```

### Candidate B

```text
Goal / Framing
Evaluate whether the current judge-lock design measures real prompt-engineering quality rather than superficial structure compliance.

Assumptions / Constraints
- Prefer recent primary sources and prior internal findings.
- Distinguish lock-grade evidence from synthetic sanity checks.
- Challenge the current design; do not assume it is valid.

Open Questions
- Which parts of the design measure true prompt quality?
- Which parts risk over-rewarding structure alone?
- What additional calibration or benchmark evidence is required?

Option Space / Tradeoffs
- Keep current design and patch narrow gaps.
- Redesign the benchmark around adjudicated real prompt pairs.
- Use a staged policy: judge-only confidence first, outcome-grounded lock second.

Recommended Next Steps
- Cross-verify key claims against at least two independent sources when possible.
- Include one adversarial counter-hypothesis review.
- Map each claimed metric back to the exact quality property it is supposed to measure.

Evaluation Criteria
- Construct validity
- Calibration reliability
- Robustness to order/verbosity artifacts
- Operational feasibility
```

### Fill-in checklist

- Winner
  - [ ] A
  - [ ] B
  - [ ] Tie
  - [ ] BothBad
- Quality A (0-100): ______
- Quality B (0-100): ______
- Confidence (1-5): ______
- Defect tags A (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Defect tags B (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Notes:
  - ____________________________________________
  - ____________________________________________

## Case 6 — `batch1_brainstorm_preset_arch_en_dev`

- Preset family: `brainstorm`
- Language: `en-US`
- Split target: `dev`

### Draft

```text
Think through whether preset+profile should exist at all, or whether everything should just be explicit presets.
```

### Candidate A

```text
Brainstorm whether preset and profile should both exist and give some ideas.
```

### Candidate B

```text
Goal / Framing
Explore whether TurboDraft should keep a preset+profile architecture or collapse everything into explicit standalone presets.

Assumptions / Constraints
- Evaluate simplicity, user comprehension, maintenance cost, and prompt-quality flexibility.
- Do not assume the current architecture is correct.

Open Questions
- What user confusion does the current model create?
- What complexity does a pure-preset model remove or add?
- Which architecture better supports distinct prompt-engineering strategies?

Option Space / Tradeoffs
- Keep preset + profile as-is.
- Collapse to standalone presets only.
- Hybrid: keep profiles internally, expose only presets in UX.

Recommended Next Steps
- Identify the lowest-cost experiments that test user comprehension and maintenance burden.
- Include one contrarian option even if it seems unattractive.
- Prioritize options that can be validated without rebuilding the whole system.

Evaluation Criteria
- UX clarity
- Architectural flexibility
- Maintenance cost
- Prompt-quality control
```

### Fill-in checklist

- Winner
  - [ ] A
  - [ ] B
  - [ ] Tie
  - [ ] BothBad
- Quality A (0-100): ______
- Quality B (0-100): ______
- Confidence (1-5): ______
- Defect tags A (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Defect tags B (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Notes:
  - ____________________________________________
  - ____________________________________________

## Case 7 — `batch1_legacy_coding_en_sealed`

- Preset family: `legacy`
- Language: `en-US`
- Split target: `sealed_test`

### Draft

```text
Take this older coding prompt and make it production-ready without losing any meaningful constraints.
```

### Candidate A

```text
Rewrite this old coding prompt so it looks modern and professional.
```

### Candidate B

```text
User Inputs to Request
- Ask for any missing hard constraints only if the draft truly lacks essential implementation context.

Agent Decisions / Recommendations
- Preserve every meaningful requirement from the old prompt unless it is clearly contradictory.
- Prefer precise, testable wording over cosmetic modernization.

Implementation Steps
1. Extract the original task, constraints, and uncertainty from the draft.
2. Rewrite the prompt so it is concise but fully usable by a coding model.
3. Preserve references, caveats, and non-obvious requirements.
4. Do not silently remove requirements just to make the prompt shorter.

Validation / Acceptance Checks
- The rewritten prompt is more usable but still non-lossy.
- Hard constraints from the original draft remain present.
- If the draft contains contradictions, call them out instead of inventing a resolution.
```

### Fill-in checklist

- Winner
  - [ ] A
  - [ ] B
  - [ ] Tie
  - [ ] BothBad
- Quality A (0-100): ______
- Quality B (0-100): ______
- Confidence (1-5): ______
- Defect tags A (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Defect tags B (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Notes:
  - ____________________________________________
  - ____________________________________________

## Case 8 — `batch1_coding_prompt_packet_en_dev`

- Preset family: `coding`
- Language: `en-US`
- Split target: `dev`

### Draft

```text
Build the first human adjudication packet from our seed bank and make sure the output is ready for reviewers to use immediately.
```

### Candidate A

```text
Goal / Objective
Build the first human-adjudication packet from the existing seed bank and make it ready for reviewers to use immediately.

Scope and Constraints
- Reuse the existing packet-builder and answer-sheet flow where possible.
- Produce reviewer-facing artifacts, not just planning notes.
- Keep the workflow compatible with later canonical import.

Implementation Steps
1. Select a balanced first batch of candidate prompt pairs.
2. Render a markdown review packet and companion CSV answer sheet.
3. Ensure case IDs, hashes, and source IDs are preserved for later compilation.
4. Document any unresolved tie-break workflow assumptions.

Validation / Acceptance Checks
- The packet is readable and ready for review.
- The answer sheet captures structured decisions.
- The artifacts are compatible with later compilation/import.
- If the batch is too toy-like or lacks coverage, stop and note the gap.
```

### Candidate B

```text
Create a review packet from the seed bank so humans can look at it.
```

### Fill-in checklist

- Winner
  - [ ] A
  - [ ] B
  - [ ] Tie
  - [ ] BothBad
- Quality A (0-100): ______
- Quality B (0-100): ______
- Confidence (1-5): ______
- Defect tags A (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Defect tags B (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Notes:
  - ____________________________________________
  - ____________________________________________

## Case 9 — `batch1_research_quota_math_en_tune`

- Preset family: `research`
- Language: `en-US`
- Split target: `tune`

### Draft

```text
Figure out the human-labeling campaign math needed to satisfy our frozen lock floors without wasting reviewer effort.
```

### Candidate A

```text
Goal / Framing
Determine the human-labeling campaign math required to satisfy the frozen lock floors without wasting reviewer effort.

Assumptions / Constraints
- Use the frozen lock floors as hard constraints.
- Minimize wasted review work on non-lock-eligible coverage.

Open Questions
- How many total pairwise cases are required?
- How many sealed cases are needed?
- How should work be distributed across families and languages?

Option Space / Tradeoffs
- Many small packets with frequent review checkpoints.
- Fewer larger packets with more efficient labeling throughput.
- A pilot packet followed by scale-up after UX validation.

Recommended Next Steps
- Compute the minimum campaign totals from the frozen floors.
- Add buffer beyond the minimum to absorb exclusions and unresolved cases.
- Recommend an operational packet size and review cadence.

Evaluation Criteria
- Lock-floor coverage
- Reviewer efficiency
- Traceability
- Risk of wasted labeling work
```

### Candidate B

```text
Estimate how much labeling work we need and give a rough plan.
```

### Fill-in checklist

- Winner
  - [ ] A
  - [ ] B
  - [ ] Tie
  - [ ] BothBad
- Quality A (0-100): ______
- Quality B (0-100): ______
- Confidence (1-5): ______
- Defect tags A (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Defect tags B (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Notes:
  - ____________________________________________
  - ____________________________________________

## Case 10 — `batch1_brainstorm_lock_tranches_en_dev`

- Preset family: `brainstorm`
- Language: `en-US`
- Split target: `dev`

### Draft

```text
Brainstorm a realistic multi-tranche plan to go from one adjudication packet to a lock-eligible benchmark campaign.
```

### Candidate A

```text
Come up with a few ways to scale our adjudication campaign.
```

### Candidate B

```text
Goal / Framing
Brainstorm a realistic multi-tranche plan to scale from one adjudication packet to a lock-eligible benchmark campaign.

Assumptions / Constraints
- Respect frozen lock floors.
- Prefer tractable operational steps over idealized large-scale plans.
- Include reviewer fatigue and tie-break handling in the design.

Open Questions
- What should tranche 1 prove before scale-up?
- How should later tranches increase family/language coverage?
- When should sealed cases be introduced or expanded?

Option Space / Tradeoffs
- Small pilot then scale.
- Immediate full-scale campaign.
- Parallel family-specific packets with centralized tie-break review.

Recommended Next Steps
- Prioritize low-cost validation in tranche 1.
- Include one contrarian high-throughput option and explain why it may be risky.
- Define what signal is needed before moving to the next tranche.

Evaluation Criteria
- Operational realism
- Coverage growth
- Review quality protection
- Lock-readiness trajectory
```

### Fill-in checklist

- Winner
  - [ ] A
  - [ ] B
  - [ ] Tie
  - [ ] BothBad
- Quality A (0-100): ______
- Quality B (0-100): ______
- Confidence (1-5): ______
- Defect tags A (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Defect tags B (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______
- Notes:
  - ____________________________________________
  - ____________________________________________
