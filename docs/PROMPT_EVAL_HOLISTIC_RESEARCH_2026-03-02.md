# Prompt Eval Holistic Research (Codex CLI + Claude CLI + Promptfoo)
Date: 2026-03-02
Owner: prompt-eval system
Depth: Full

## Scope
Research goal: validate the best modern (post-2025-06 where possible) architecture for:
1) drafting prompt evaluation presets,
2) judge design/calibration,
3) Promptfoo integration when providers are local agent CLIs (codex/claude),
4) autonomous improvement loops.

## Sub-questions
1. What does current vendor guidance converge on for prompt evaluation workflow?
2. What are current best practices for LLM-as-judge reliability and calibration?
3. What does Promptfoo natively support for custom local providers and model-graded assertions?
4. What changes are required in our orchestrator/pipeline to align with that guidance?

## Source quality filter
Included sources are official documentation/cookbooks from:
- OpenAI
- Anthropic
- Google (Gemini/Vertex)
- Promptfoo

Low-quality or non-primary SEO sources were excluded.

## Findings

### A) Converged eval workflow: Analyze -> Measure -> Improve (continuous loop)
OpenAI’s recent cookbook formalizes the evaluation flywheel (analyze failures, measure with graders, improve and iterate) and explicitly frames this as a continuous process for resilient systems.

Implication for TurboDraft prompt engineering:
- We should not treat prompt work as one-shot drafting.
- The pipeline must continuously harvest failures, update datasets/rubrics, and rerun benchmark gates.

### B) Success criteria must be explicit and multidimensional
Anthropic’s Test & Evaluate guidance emphasizes specific/measurable/achievable/relevant criteria and multidimensional evaluation (quality + safety + latency + cost dimensions).

Implication:
- Preset acceptance cannot rely on one scalar win-rate.
- Promotion requires multi-metric gate checks and explicit no-go reasons.

### C) LLM judge reliability requires calibration against human ratings
Google Vertex’s judge-evaluation docs explicitly require human-rated ground truth to evaluate judge quality; they recommend balanced metrics and confusion-matrix analysis for pairwise/pointwise judges.

Implication:
- Judge prompt quality must be measured against a labeled calibration set.
- We should track TPR/TNR/balanced accuracy, not raw accuracy only.

### D) Judge bias/variance controls are concrete and actionable
Google’s judge configuration docs highlight:
- response flipping to reduce pairwise position bias,
- multi-sampling to improve consistency (with latency tradeoff),
- optional tuned judge models.

Implication:
- Our judge pipeline should enforce response-order symmetry checks.
- Repeat sampling should be configurable and explicitly costed.

### E) Promptfoo supports local custom providers via Python and file:// provider IDs
Promptfoo’s Python provider docs confirm:
- custom provider entrypoint (`call_api(prompt, options, context)`),
- optional `tokenUsage`, `cost`, `error` return fields,
- persistent workers (reduced overhead),
- file-based provider references (`file://...`).

Implication:
- CLI-native provider wrappers are first-class and production-viable.
- We can run codex/claude through Promptfoo without API-key-only coupling.

### F) Promptfoo model-graded rubric semantics require explicit thresholding
Promptfoo llm-rubric docs clarify pass/score behavior:
- pass defaults to grader `pass`, and if omitted pass can default true,
- score alone does not fail unless `threshold` is set,
- with threshold both pass and score constraints are enforced.

Implication:
- All critical rubric assertions should set thresholds to avoid false-pass drift.

### G) Modern prompting guidance for agentic systems emphasizes structure + cost/accuracy control
Gemini’s current prompt guidance recommends direct structured prompts and explicitly calls out the cost/accuracy tradeoff for deep agentic workflows.

Implication:
- Preset design should encode explicit structure + token budget controls.
- “better prompt” must be evaluated jointly with latency/cost ceilings.

## Hypotheses and confidence

| Hypothesis | Confidence | Evidence |
|---|---:|---|
| H1: Eval-flywheel architecture is superior to ad-hoc prompt tuning | High | OpenAI eval flywheel + Anthropic test/eval loop + Google evaluation-driven cycle |
| H2: Judge reliability is the bottleneck for trustworthy automation | High | Anthropic LLM-graded caution + Google human-ground-truth judge evaluation |
| H3: Promptfoo + CLI provider wrapper is viable for autonomous local evals | High | Promptfoo Python/file provider docs + local smoke run evidence |
| H4: Pairwise bias controls (flip + repeats) materially improve judge robustness | Medium-High | Google judge configuration guidance |

## Adversarial checks
1. **Counterclaim:** “Single win-rate metric is enough.”
   - Rejected: sources repeatedly recommend multidimensional metrics and explicit success criteria.
2. **Counterclaim:** “No need to calibrate judge; use one strong model.”
   - Rejected: judge quality must be measured vs human ground truth; otherwise silent judge drift.
3. **Counterclaim:** “Promptfoo requires API keys, so CLI wrappers are a hack.”
   - Rejected: Promptfoo officially supports file-based custom providers with typed response contract.

## Applied decisions for this repo
1. Keep Promptfoo in the loop, but treat assertion failures as evaluation signal, not infrastructure crash.
2. Maintain fail-closed behavior for provider/tool/runtime errors.
3. Add explicit gate metrics from judge calibration + symmetry + promotion stats.
4. Ensure rubric assertions use thresholds for critical checks.
5. Keep cost/latency accounting in every phase summary.

## Limits / unresolved
- Public docs give strong design guidance, but exact metric thresholds remain use-case specific and must be empirically tuned on our datasets.
- Promptfoo exit code semantics for “assertion failures vs infra failures” are operationally observed in this repo and should be normalized in orchestrator policy.

## Sources (primary)
1. OpenAI Cookbook — Building resilient prompts using an evaluation flywheel
2. Anthropic Docs — Define success criteria and build evaluations
3. Anthropic Docs — Prompt engineering overview
4. Google Vertex — Gen AI evaluation service overview
5. Google Vertex — Evaluate a judge model
6. Google Vertex — Configure a judge model
7. Google AI for Developers — Prompt design strategies (Gemini)
8. Promptfoo Docs — Python provider
9. Promptfoo Docs — LLM rubric assertion
10. Promptfoo Docs — LLM providers overview
