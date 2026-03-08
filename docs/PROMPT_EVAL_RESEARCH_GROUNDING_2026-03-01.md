# Prompt Eval Grounding Research (Codex CLI + Promptfoo + LLM Judge)
Date: 2026-03-01
Scope: Re-ground autonomous plan with current docs and recent reliability findings

## Executive conclusions
1. Promptfoo is fit for orchestration and CI gating of prompt evals.
2. LLM judge outputs require explicit reliability diagnostics before use in promotion decisions.
3. Holdout must be confirmatory and statistically pre-registered (not iterative tuning data).
4. Codex CLI multi-agent execution is powerful but should be treated as experimental, with fallback controls.

## Evidence summary
### A) Promptfoo supports required orchestration features
- Configuration framework for prompt/model/test matrixes.
- Model-graded assertions and rubric-based grading.
- Comparative scoring modes including selection patterns.
- CI/CD integration guidance and workflow support.

### B) OpenAI eval guidance reinforces representative, repeatable eval design
- Evals should mirror real production tasks and edge cases.
- Datasets should contain representative and challenging examples.
- CI integration is recommended to catch regressions continuously.

### C) Judge reliability risk is real in recent literature
- Judge outputs can vary by context and framing; consistency is not guaranteed by default.
- Structured reliability checks (consistency/symmetry/repeatability) are required to trust promotion outcomes.

### D) Multi-agent architecture requires explicit orchestration controls
- Multi-agent systems benefit from decomposition and parallelism.
- They also require explicit coordination and robust state/recovery contracts.

## Plan implications
- Keep hybrid architecture: Promptfoo for orchestration + custom judge reliability diagnostics.
- Require judge calibration gates before any candidate comparison is considered valid.
- Use power-aware sample sizing by preset family for confirmatory holdout decisions.
- Add Codex multi-agent health probes, bounded concurrency, and sequential fallback mode.
- Enforce a holistic source policy gate (OpenAI + Anthropic + Google + Promptfoo + recent papers) via `validate_holistic_sources.py`.

## Sources (primary)
1. Promptfoo configuration reference
   https://www.promptfoo.dev/docs/configuration/reference/
2. Promptfoo model-graded assertions
   https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/
3. Promptfoo llm-rubric
   https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/llm-rubric/
4. Promptfoo select-best
   https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/select-best/
5. Promptfoo CI/CD integration
   https://www.promptfoo.dev/docs/integrations/ci-cd/
6. OpenAI Evals design guide
   https://platform.openai.com/docs/guides/evals-design
7. OpenAI Graders guide
   https://platform.openai.com/docs/guides/graders
8. OpenAI docs: multi-agent in Codex CLI (experimental)
   https://developers.openai.com/codex/cli/multi-agent/
9. Anthropic engineering: built a multi-agent research system
   https://www.anthropic.com/engineering/built-multi-agent-research-system
10. OpenAI cookbook: parallel agents pattern
    https://cookbook.openai.com/examples/agents_sdk/parallel_agents
11. 2025 reliability paper (ConsJudge)
    https://aclanthology.org/2025.findings-acl.306/
12. 2025 reliability paper (TrustJudge)
    https://arxiv.org/abs/2508.02768
