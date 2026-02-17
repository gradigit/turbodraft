# Research: Baseline Prompt Review Checklist + Engineered Prompt Format + Iterative Workflow
Date: 2026-02-15
Depth: Full

## Executive Summary

Your current baseline review checklist is directionally solid and aligns with how major vendors recommend evaluating LLM systems: define explicit success criteria, build empirical tests, and avoid “vibe-based” evaluation. It is not fully “objective” (no prompt rubric is), but you can make it substantially more reliable with (1) anchored scoring, (2) blinded/pairwise evaluation with order randomization, and (3) calibration against a small, human-reviewed gold set.

Your baseline engineered prompt format (Goal, Scope, Requirements, Deliverables, Acceptance Criteria, User Inputs to Request, Agent Decisions) is consistent with common prompt-template components observed in real-world LLM applications and with prompt-pattern guidance (clarity, constraints, explicit outputs). There is no universally optimal template: template/format choice measurably affects model performance and can be model-specific, so the “best” format must be chosen empirically for your target models and tasks.

The workflow you described (agent produces a rewrite, asks clarifying questions, user answers, agent refines; repeat) matches both research and product practice: iterative refinement frameworks (e.g., Self-Refine) and prompt-optimization tooling (e.g., PromptWizard) show repeated critique/refine loops improve outputs; interactive prompt tooling exists (e.g., PromptAid) to reduce the cognitive overhead of iteration.

Confidence: High on evaluation/iteration principles; Medium on “optimal” prompt format claims because format optimality is task/model-dependent.

## Topics Studied
1. Is our baseline prompt review checklist trustworthy and objective?
2. Is the baseline engineered prompt format close to optimal for prompt-engineering outputs?
3. Is the “iterative refinement with questions” workflow a good fit for PromptPad?

## 1) Baseline Review Checklist: Trustworthiness & Objectivity

### Sub-questions investigated
1. What do credible sources recommend for evaluating LLM outputs in practice?
2. What are known failure modes/biases of LLM-as-judge evaluation?
3. How do we reduce subjectivity in a human checklist?

### Findings

#### 1.1 Evaluation should be task-specific, empirical, and calibrated
- Both OpenAI and Anthropic emphasize defining success criteria, building empirical evaluations/test sets, and iterating continuously rather than relying on generic metrics or intuition.
- This supports your checklist’s focus on fidelity, constraints, and testability, but it suggests strengthening the checklist with explicit scoring anchors and a small reference set of “good” vs “bad” baseline outputs.

#### 1.2 LLM-as-judge is useful but not “objective”; it is bias-prone (and protocol choice matters)
- OpenAI’s evaluation guidance explicitly recommends leaning on pairwise comparisons / scoring against criteria because LLMs are comparatively strong at discrimination tasks, but also calls out position bias and verbosity bias as common issues to control for.
- Recent research documents additional instability in LLM-as-judge:
  - Position bias in pairwise comparisons.
  - Non-transitivity (A>B, B>C, C>A) that can make rankings baseline-sensitive.
  - Shortcut/recency/provenance cues that can silently flip judgments.
- There is also evidence that the feedback protocol itself can change reliability: a 2025 study found pairwise protocols can be more vulnerable to “distractor” features than absolute scoring in some settings.

Net: keep pairwise judging (it’s still very practical), but treat it as a noisy signal and mitigate with randomization, swaps, and calibration.

#### 1.3 Converting a checklist into an “objective” rubric means adding anchors and pass/fail gates
What makes checklists feel subjective is ambiguous scoring. You can tighten this by:
- Adding 0/1/2 anchors for each dimension (what “0” looks like; what “2” looks like).
- Adding more must-fail gates aligned to known “prompt defect” categories (ambiguity, missing constraints, contradictory requirements, unclear responsibility for inputs).
- Maintaining a small “gold” set of draft→engineered pairs you agree are excellent/acceptable/bad, and using that set to calibrate both humans and LLM judges.

### Recommendations (concrete)
1. Keep your current checklist, but add scoring anchors (0/1/2) and a short “examples” appendix (one good, one bad).
2. Keep LLM pairwise judging, but mitigate bias:
   - Randomize A/B order and run a second evaluation with swapped order; require consistency.
   - If you’re using a single “best judge model”, still treat it as noisy; track disagreement rate.
   - Consider mixing protocols: pairwise for sensitivity + pointwise scoring for robustness (especially when outputs can game superficial features).
3. Add one checklist dimension: “Template risk / format sensitivity”:
   - If results differ materially with small formatting changes, treat that as instability and avoid concluding “this format is optimal.”

## 2) Baseline Engineered Prompt Format: Is it Optimal?

### Sub-questions investigated
1. Do best-practice prompting guides converge on a common structure?
2. Do real-world LLM apps use structured templates?
3. Is there evidence that prompt format affects outcomes enough that “optimal” is context-dependent?

### Findings

#### 2.1 Strong convergence on: clarity, constraints, and explicit success criteria
- Major prompting guides emphasize being clear and direct, using structure, and defining what “good” looks like.
- Pattern catalogs frame prompts as reusable “prompt patterns” that can be composed: role, output format, constraints, etc.

#### 2.2 Real-world systems use prompt templates with repeated components
- Analyses of prompt templates in production LLM apps show repeated component patterns and co-occurrences (instructions + context + placeholders + output format + constraints, etc.).
- Your baseline format is compatible with this: it’s essentially a “task brief” template for a downstream agent.

#### 2.3 There is no universally best format; template choice can dominate performance
- Research on prompt templates shows that small format differences can drastically change performance, and the best template may not transfer across models or setups.
- Net: the right way to decide “optimal format” for PromptPad is: keep one default, but run empirical evaluation on multiple formats against your target models and tasks (your benchmark harness is exactly the right direction).

### Recommendations (concrete)
1. Treat the current baseline format as a strong default for agentic coding prompts.
2. Create 2-3 alternative “rewrite styles” and benchmark them:
   - “Concise brief” (fewer sections, shorter).
   - “Execution-first” (explicit ordered steps up front).
   - “Decision-first” (forces decisions early, then requirements).
3. Make the prompt engineer choose a style based on draft classification (e.g., “dictation/uncertain” vs “already structured”).

## 3) Workflow: Iterative Refinement + Clarifying Questions in PromptPad

### Sub-questions investigated
1. Does iteration improve outputs in practice?
2. Do interactive tools exist that embody this workflow?
3. What does this imply for PromptPad’s design?

### Findings

#### 3.1 Iterative refine loops improve outputs (research-backed)
- Self-Refine shows repeated feedback/refinement cycles improve outputs and are preferred by humans versus one-shot generation.
- Prompt optimization frameworks/tools similarly rely on iterative critique/refine cycles.

#### 3.2 Interactive prompt tooling exists and is effective
- PromptAid (visual analytics) is explicitly about helping users iterate via exploration/perturbation/testing with reduced overhead.
- Anthropic’s “prompt improver” product flow is: generate improved prompt, then accept feedback, then improve again.

#### 3.3 Implication for PromptPad: split “saved artifact” from “interactive loop”
To keep the saved prompt clean (engineered prompt only) while still enabling iteration:
- Keep the engineered prompt in the file as the single artifact injected back to CLI.
- Run the iterative loop in a side panel:
  - The assistant asks the “User Inputs to Request” questions directly.
  - User answers.
  - Assistant regenerates the engineered prompt incorporating the answers, shrinking the “User Inputs to Request” section over time.
- This matches how iteration tools work without polluting the final prompt.

### Recommendations (concrete)
1. Add an “Iterate” mode that:
   - Extracts the “User Inputs to Request” bullets as interactive questions.
   - Lets the user answer inline.
   - Rewrites the prompt again with answers embedded.
2. Keep a hard rule: only the engineered prompt is written to disk; chat/history stays in app state (or optional local log).
3. Benchmark iteration cost separately (agent RTT is network bound, but the editor must remain responsive).

## Hypothesis Tracking

| Hypothesis | Confidence | Supporting Evidence | Contradicting Evidence |
|---|---|---|---|
| H1: The current checklist covers the most important prompt-quality failure modes for your use case. | Medium-High | Vendor eval guidance emphasizes success criteria + empirical testing; prompt defect taxonomies match many checklist dimensions. | Checklist lacks explicit scoring anchors and doesn’t explicitly address judge bias/format sensitivity. |
| H2: Pairwise LLM judging is “objective enough” to be your sole arbiter of prompt quality. | Low | LLMs can discriminate well; pairwise is common in practice. | Multiple studies show position bias, non-transitivity, shortcut biases; single-judge decisions can be unstable. |
| H3: The baseline prompt format is near-optimal across models and tasks. | Medium-Low | Real-world templates converge on similar components; pattern catalogs support structure. | Template format can dominate performance and transfer poorly across models; needs empirical validation. |
| H4: Iterative refinement with user Q&A improves engineered prompts. | High | Self-Refine; PromptWizard; PromptAid; Anthropic prompt improver. | Iteration can increase latency/cost; needs UI discipline to keep editor fast. |

## Verification Status

### Verified (2+ sources)
- “Define success criteria + build empirical evals” is core to prompt engineering cycles in production. (Anthropic eval docs + OpenAI eval best practices)
- LLM-as-judge has known biases/instabilities (position bias, non-transitivity, shortcut cues). (multiple 2024-2025 papers)
- Prompt format/template choice can materially change outcomes and may not transfer across models. (template-format research + prompt-template analysis)
- Iterative refine loops can improve output quality. (Self-Refine + prompt-optimization tooling)

### Unverified / needs more targeted evidence
- A single best “engineered prompt template” exists for agentic coding tasks specifically (likely false; not supported by literature I found).

## Limitations & Gaps
- Most research focuses on evaluating model outputs or prompt templates for task accuracy; there is less direct literature on “prompt rewrite quality” for downstream coding agents specifically.
- The best choice for PromptPad still needs empirical confirmation using your actual benchmark harness and your target downstream agents/models.

## Sources (quality filtered)
| Source | URL | Quality | Accessed |
|---|---|---|---|
| OpenAI: Evaluation best practices | https://platform.openai.com/docs/guides/evaluation-best-practices | High (official) | 2026-02-15 |
| OpenAI: Prompting best practices | https://help.openai.com/en/articles/6654000-guidance-for-writing-effective-prompts | High (official) | 2026-02-15 |
| Anthropic: Prompt engineering overview | https://docs.anthropic.com/en/docs/prompt-engineering | High (official) | 2026-02-15 |
| Anthropic: Define success criteria | https://docs.anthropic.com/en/docs/empirical-performance-evaluations | High (official) | 2026-02-15 |
| Anthropic: Create strong empirical evaluations | https://docs.anthropic.com/en/docs/test-and-evaluate/develop-tests | High (official) | 2026-02-15 |
| Anthropic: Prompt improver docs | https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/prompt-improver | High (official) | 2026-02-15 |
| Anthropic: Prompt improver announcement | https://www.anthropic.com/news/prompt-improver | High (vendor) | 2026-02-15 |
| Self-Refine paper | https://arxiv.org/abs/2303.17651 | High (peer-reviewed preprint; highly cited) | 2026-02-15 |
| PromptAid paper | https://arxiv.org/abs/2304.01964 | High (peer-reviewed preprint) | 2026-02-15 |
| PromptWizard (Microsoft Research blog) | https://www.microsoft.com/en-us/research/blog/promptwizard-the-future-of-prompt-optimization-through-feedback-driven-self-evolving-prompts/ | High (lab) | 2026-02-15 |
| Mind Your Format paper | https://arxiv.org/abs/2401.06766 | High (peer-reviewed preprint) | 2026-02-15 |
| Mind Your Format (ACL Findings entry) | https://aclanthology.org/2024.findings-acl.375/ | High (publisher index) | 2026-02-15 |
| From Prompts to Templates paper | https://arxiv.org/abs/2504.02052 | High (peer-reviewed preprint) | 2026-02-15 |
| Prompt patterns catalog paper | https://arxiv.org/abs/2302.11382 | High (peer-reviewed preprint) | 2026-02-15 |
| Position bias in LLM-as-judge | https://arxiv.org/abs/2406.07791 | High (peer-reviewed preprint) | 2026-02-15 |
| Non-transitivity in LLM-as-judge | https://arxiv.org/abs/2502.14074 | High (peer-reviewed preprint) | 2026-02-15 |
| Pairwise vs pointwise bias study | https://arxiv.org/abs/2504.14716 | High (peer-reviewed preprint) | 2026-02-15 |
| PromptBench (framework) | https://github.com/microsoft/promptbench | High (reputable OSS) | 2026-02-15 |
