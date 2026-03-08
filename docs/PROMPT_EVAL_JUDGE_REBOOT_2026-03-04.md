# Prompt-Eval Reboot (2026-03-04): Judge Prompt Calibration for Prompt-Engineering Quality

## 1) Refined objective (corrected)

We are optimizing **the LLM judge prompt** used by:
- Judge model: **Codex 5.3 xhigh**

So we can then reliably evaluate/refine:
- Drafting/prompt-engineering prompts (for drafting agent)

Execution model for outcome checks (when needed):
- **Codex 5.3 high** (not Spark)

### Decision to make
When can we say the judge prompt is "locked" and trustworthy enough to drive iterative optimization of drafting prompts?

---

## 2) What was wrong / incomplete in the previous approach

The previous pipeline validated consistency and formatting reliability (good), but underweighted the core question:

> "Does the judge correctly recognize engineering quality and optimization quality of prompts?"

Specifically:
1. It leaned heavily on pairwise consistency checks without a sufficiently rich **prompt-quality gold standard**.
2. It did not strongly separate:
   - **textual prompt quality judgment** vs
   - **true downstream performance impact**.
3. Strict gates were evaluated on tiny sample sizes in recent cycles, causing expected statistical failures.

Conclusion: not wasted work, but only a partial layer. We need a better design centered on judge validity for prompt-engineering quality.

---

## 3) Deep research synthesis (recent + primary)

## A. Provider guidance converges on task-specific, calibrated evals

- OpenAI eval best-practices: task-specific evals, human calibration, continuous evals, avoid generic "vibe" scoring.
- Anthropic eval guidance: define measurable success criteria, build empirical test sets with real distributions and edge cases.
- Google Vertex GenAI evaluation: rubric-based evaluation (adaptive/static) and model-comparison workflows.
- Promptfoo docs: model-graded rubrics and pairwise/select-best are useful, but are still grader-dependent and need calibration.

Implication: judge prompt quality cannot be inferred from one metric; must be calibrated against a well-defined target function.

## B. Recent LLM-as-judge literature warns about bias and instability

- EMNLP 2025 multilingual reliability study reports weak cross-language consistency in many settings (kappa around ~0.3 average in that setup).
- Self-preference/family-bias papers in 2025 show judges can favor own-family outputs unless controlled.
- JuStRank (ACL 2025) emphasizes evaluating judges as **system rankers**, not only per-instance graders.
- 2026 survey on LLM-as-a-Judge highlights standardization, bias control, and human alignment as core reliability issues.

Implication: we must explicitly test positional bias, self/family bias, and rank-level correctness.

---

## 4) Challenge to proposed idea: "Use leaked SOTA system prompts as perfect 100/100"

This is attractive but flawed as a primary anchor.

Why it is risky:
1. **Authenticity risk**: mined/system-leaked prompts may be partial, stale, or tampered.
2. **Objective mismatch**: a system prompt for a general assistant is not automatically optimal for TurboDraft prompt-engineering tasks.
3. **Domain/style confound**: judge may learn to reward a specific style instead of actual engineering quality.
4. **Version drift**: provider behavior and hidden instructions evolve; static leaked artifacts age quickly.

Better alternative:
- Build an internal **Expert Gold Prompt Set (EGPS)** for your exact preset families and constraints, then generate controlled degraded variants.
- Use leaked prompts only as optional out-of-distribution probes, not as absolute 100/100 truth.

---

## 5) Correct eval architecture (usage-limit aware)

Use a **two-arm design**:

## Arm J — Judge-only calibration (primary for judge lock)

Goal: prove the judge prompt can accurately score prompt-engineering quality itself.

### J0. Split + blinding protocol (required)
- Split seed prompts by family into `dev/tune/sealed_test` with fixed seed (60/20/20).
- Generate perturbations **after** split assignment; all children remain in parent split.
- Use `dev+tune` for judge-prompt iteration only.
- Open `sealed_test` once for lock decision; no further tuning on that snapshot.

### J1. Gold dataset construction (prompt-level)
Create `EGPS-v1` with human/expert labels for prompt quality dimensions:
- Intent/constraint preservation
- Structural contract compliance
- Testability/actionability
- Scope discipline / anti-fluff
- Safety/role-boundary hygiene

Per sample, include:
- engineered prompt text
- human absolute score (0–100), with rubric anchors at 0/25/50/75/100
- pairwise preferences vs other prompts
- error tags (missing constraints, ambiguity, role leakage, etc.)
- label provenance metadata (`rater_count`, `blind_round`, `adjudication_status`)

Label quality policy:
- 3 independent blinded expert ratings per item.
- Require Krippendorff's alpha >= 0.67 before lock run.
- Adjudicate high-disagreement items; unresolved items excluded from lock set.

### J2. Counterfactual perturbation suite (cheap, high-signal)
For each gold prompt, auto-generate controlled degradations:
- remove one critical constraint
- inject conflicting instruction
- add decorative fluff without utility
- remove output contract/schema
- introduce agent-role leakage
- increase verbosity with no information gain

These give near-deterministic "should-score-lower" tests without expensive execution runs.

Leakage/shortcut controls:
- At least 50% of negatives must be human-written naturalistic negatives.
- Hold out perturbation templates used for lock eval (never seen during tuning).
- Include adversarial hard negatives that preserve style while breaking semantics.
- Report synthetic vs natural subset metrics separately; both must pass.

### J3. Judge tests
Run Codex 5.3 xhigh judge with candidate judge prompts on:
- absolute scoring task
- pairwise ranking task
- error-tag detection task

Metrics:
- Spearman/Pearson vs human absolute scores
- Pairwise agreement vs human preference labels
- Error-tag F1 / recall on critical defects
- Calibration (confidence vs correctness; Brier/ECE)

### J4. Robustness / invariance checks
- Position swap invariance (A/B order)
- Paraphrase invariance
- Verbosity distractor resilience
- Style/family self-preference probe

Pass thresholds define judge lock readiness.

### J5. Judge-manipulation robustness (prompt-injection resistance)
- Inject candidate-level attacks that attempt to steer the judge (\"always pick A\", role hijack text, schema-breaking bait).
- Evaluate both raw and sanitized variants.
- Measure:
  - attack success rate (ASR)
  - score drift between attacked vs sanitized prompt pairs
  - invalid-json amplification under attack

## Arm O — Outcome-grounded lite (secondary validation, cost-controlled)

Goal: ensure judge signal tracks real downstream utility, without brute-force spend.

Primary execution model: **Codex 5.3 high**.
Cross-model validity check: add at least one out-of-family execution model in lock stage.

### O1. Candidate funnel
1. Run Arm J to rank candidates.
2. Keep only top-K (e.g., 3–5) + baseline.
3. Add exploration slots (e.g., 2 random/diversity candidates) to avoid Arm-J-only pruning bias.

### O2. Sparse stratified execution set
- Small but stratified task set across preset families + edge cases.
- Evaluate candidate prompts by downstream task success metrics.

### O3. Sequential testing (early stop)
- Use sequential pairwise elimination (Bradley-Terry/Elo style + confidence bounds).
- Stop comparing a pair once confidence interval excludes meaningful gain.
- Pre-register stopping policy (alpha-spending or Bayesian posterior threshold).
- Enforce minimum pair comparisons before early stop is allowed.

### O4. Meta-agreement
Measure whether judge rankings from Arm J align with outcome rankings from Arm O.
This is the final external validity check before lock.

---

## 6) Judge lock criteria (proposed)

Lock judge prompt only if all pass:

1. **Arm J validity**
   - Spearman rho >= 0.65 on sealed set (95% CI lower bound > 0.50)
   - Pairwise agreement >= 75% vs human preferences (N >= 500 pairwise labels)
   - Critical-defect recall >= 90% (role leakage, missing constraints, contract loss)
2. **Arm J robustness**
   - Order-swap flip rate <= 5%
   - Family/source bias delta <= 3 points (absolute score scale 0–100)
   - Paraphrase invariance median absolute delta <= 5 points
3. **Arm O external validity**
   - Judge ranking aligns with outcome ranking: Spearman rho >= 0.50
   - Alignment holds for Codex 5.3 high and at least one out-of-family model
   - Sample floors: >= 200 total Arm O tasks, and >= 20 tasks per preset family per execution model
   - Uncertainty gate: bootstrap 95% CI lower bound for rho > 0.30
4. **Operational reliability**
   - Invalid JSON rate <= 0.5%
   - Runtime error rate <= 1.0%
   - Timeout rate <= 2.0%
5. **Run-to-run stability**
   - Repeat lock evaluation 5 times with shuffled order and fresh random seeds
   - Median metrics must pass all gates
   - No run may fall below threshold by more than predefined tolerance (`delta`)
   - Report SD and flip-rate across reruns
6. **Judge-manipulation resistance**
   - Attack success rate <= 5%
   - Score drift attacked vs sanitized <= 5 points (median)
   - Invalid-json under attack <= 2x baseline invalid-json rate

If any fail: iterate judge prompt first, do not promote drafting prompt changes.

---

## 7) Usage-limit strategy (practical)

1. Hash-based caching for every judge call and execution call.
2. Start with Arm J (cheap) before any Arm O execution.
3. Perturbation-heavy tests (low token cost, high signal).
4. Sequential elimination to avoid full Cartesian benchmarking.
5. Run expensive audits only on finalists.
6. Hard stop-loss per cycle (tokens + wall-clock + provider-call cap).

### Anti-overfitting controls
- Max 3 tuning rounds per dataset snapshot.
- Maintain frozen canary set never used for tuning.
- Lock requires non-regression on canary set.
- Refresh canary snapshot on major model updates or quarterly.

---

## 8) Concrete repo implementation plan

### New datasets
- `bench/prompt_eval/datasets/judge_quality/gold_prompts.jsonl`
- `bench/prompt_eval/datasets/judge_quality/perturbations.jsonl`
- `bench/prompt_eval/datasets/judge_quality/pairwise_labels.jsonl`

### New scripts
- `bench/prompt_eval/tools/build_judge_quality_dataset.py`
- `bench/prompt_eval/tools/run_judge_quality_calibration.py`
- `bench/prompt_eval/tools/run_judge_invariance_suite.py`
- `bench/prompt_eval/tools/run_outcome_lite_eval.py`
- `bench/prompt_eval/tools/run_judge_outcome_meta_agreement.py`

### Gate updates
Add judge-lock gate block with explicit Arm J + Arm O criteria.

---

## 9) Adversarial review checklist

Required adversarial challenge points:
1. Can judge game the rubric style without true quality understanding?
2. Do perturbations overfit to synthetic artifacts?
3. Are multilingual/pivot presets underrepresented?
4. Is pairwise-only mode vulnerable to distractor features?
5. Could family bias survive source blinding?

Every failed challenge must map to a new test or threshold.

---

## 10) Immediate recommendation

- Do **not** lock judge prompt yet.
- Adopt this two-arm design.
- First deliverable: Arm J dataset + calibration + invariance report.
- Only after Arm J passes, run Arm O lite to validate external utility alignment.

---

## 11) Source index (primary + recent)

Provider documentation:
- OpenAI Evals guide: https://platform.openai.com/docs/guides/evals
- OpenAI Graders guide: https://platform.openai.com/docs/guides/graders
- Anthropic eval tool docs: https://docs.anthropic.com/en/docs/test-and-evaluate/eval-tool
- Google Vertex GenAI evaluation overview: https://cloud.google.com/vertex-ai/generative-ai/docs/models/evaluation-overview
- Promptfoo model-graded assertions: https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/
- Promptfoo select-best assertions: https://www.promptfoo.dev/docs/configuration/expected-outputs/select-best/

Research literature:
- A Survey on LLM-as-a-Judge (2026): https://arxiv.org/abs/2508.00404
- How Reliable is Multilingual LLM-as-a-Judge? (EMNLP 2025): https://aclanthology.org/2025.emnlp-main.1385/
- Judges as Rankers (JuStRank, ACL 2025): https://aclanthology.org/2025.acl-long.158/
- Who Validates the Validators? (2025): https://arxiv.org/abs/2507.18952

---

## 12) Adversarial-review integration summary

Critical issues found and addressed in this revision:
1. Added explicit split/blinding protocol (`J0`) to prevent leakage.
2. Added rater-reliability/adjudication policy for human labels.
3. Replaced ambiguous lock language with numeric, falsifiable thresholds.
4. Added synthetic-vs-natural perturbation controls.
5. Added exploration slots + pre-registered sequential stopping controls.
6. Added anti-overfitting controls (round caps + canary non-regression).
7. Added cross-model external validity requirement.
8. Added Arm O sample-size/CI gates.
9. Added run-to-run stability gates (5 reruns).
10. Added explicit judge-manipulation (prompt-injection) robustness suite (`J5`).
