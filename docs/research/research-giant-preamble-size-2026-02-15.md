# Research: Giant preamble sizing for PromptPad prompt-engineering agent
Date: 2026-02-15
Depth: Full

## Executive Summary
A very large preamble (for example ~60K tokens) is unlikely to be optimal for PromptPad's default flow. The current evidence suggests a better quality/latency tradeoff is a **large but bounded preamble** in the **~3K-8K token range** for Codex-Spark usage, with a hard cap around **~10K-12K** unless benchmark evidence proves otherwise.

Why:
- Codex-Spark has a 128K context window, but long-context papers consistently show quality degradation as input length rises, even when retrieval is perfect.
- OpenAI latency guidance indicates input-token cuts are often small latency wins for normal prompts, but large contexts are explicitly the exception.
- Prompt caching can materially reduce repeated-prefix latency when cache conditions are met, but cache hit behavior is not guaranteed under all routing/load patterns.

Recommended default for PromptPad:
- Keep current core preamble for default interactive path.
- Add a "large" profile at **~4K-6K tokens**.
- Avoid 60K by default.
- Keep web search off by default for rewrite latency; add opt-in research mode.

## Request decomposition (Self-Ask)
Main question:
- What preamble size is optimal for prompt-rewriting quality while preserving latency and avoiding long-context degradation?

Sub-questions:
1. What is the model context budget and practical implication for Codex-Spark?
2. How does input length affect latency and cache behavior?
3. What does research say about long-context quality degradation?
4. Given a short draft (~<1K tokens), what practical size band should a "large" preamble use?
5. Should web search be part of the default rewrite path?

## Source quality filter log
| Source | URL | Quality | Recency | Notes |
|---|---|---|---|---|
| OpenAI Codex-Spark launch | https://openai.com/index/introducing-gpt-5-3-codex-spark/ | High | 2026-02 | Primary source for model context and speed framing |
| OpenAI latency optimization guide | https://developers.openai.com/api/docs/guides/latency-optimization | High | 2026 | Primary source for token-latency principles |
| OpenAI prompt caching guide | https://developers.openai.com/api/docs/guides/prompt-caching | High | 2026 | Primary source for cache thresholds and behavior |
| OpenAI prompt engineering guide | https://developers.openai.com/api/docs/guides/prompt-engineering | High | 2026 | Official guidance on context-window planning and GPT vs reasoning prompting |
| OpenAI prompt best practices (Help Center) | https://help.openai.com/en/articles/6654000-guidance-for-writing-effective-prompts | Medium-High | Updated 2026 | Secondary but official guidance |
| Anthropic long-context tips | https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/long-context-tips | High | 2025 crawl | Useful vendor cross-check on long-context prompt structure |
| Anthropic prompt caching | https://platform.claude.com/docs/en/build-with-claude/prompt-caching | High | 2025 crawl | Cross-vendor cache behavior comparison |
| Lost in the Middle (arXiv/TACL) | https://arxiv.org/abs/2307.03172 | High | 2023/2024 | Foundational long-context position-sensitivity evidence |
| RULER benchmark (arXiv/COLM) | https://arxiv.org/abs/2404.06654 | High | 2024 | Strong benchmark evidence of context-length performance drop |
| Context Length Alone Hurts LLM Performance... (arXiv/EMNLP Findings) | https://arxiv.org/abs/2510.05381 | Medium-High | 2025 | Recent evidence that sheer length hurts even with perfect retrieval |

Rejected sources:
- General news/listicle summaries and non-primary SEO pages were excluded for core claims.

## Detailed findings

### 1) Context budget facts relevant to this decision
- OpenAI states Codex-Spark launches with a **128K context window** (text-only in research preview).
- OpenAI prompt engineering docs emphasize context windows are finite and model-specific.

Implication:
- A 60K preamble consumes ~47% of Spark's total context before user draft + output + any additional context.

### 2) Latency behavior from primary docs
- OpenAI latency guidance:
  - Output token count is usually the dominant latency driver.
  - Input token reduction is often smaller impact for ordinary prompt sizes, but this changes for truly massive contexts.
- OpenAI also notes smaller/faster models can benefit from longer, more detailed prompts when quality requires it.

Implication:
- Adding some instruction mass can help quality on fast models, but very large preambles can still become expensive in prefill and risk context-side quality effects.

### 3) Caching behavior and why it matters
- OpenAI prompt caching:
  - Works for prompts >=1024 tokens.
  - Exact prefix match matters.
  - Static prefix first, variable content later improves cacheability.
  - Reported potential is up to 80% latency reduction and up to 90% input-token cost reduction in favorable scenarios.
- Anthropic caching guidance is directionally similar (cache static prefix at the beginning).

Implication:
- A large static preamble can be viable if requests repeatedly reuse an identical prefix and cache hit conditions hold.
- But cache effectiveness depends on routing/load/prefix consistency; it should be treated as an optimization, not a guarantee.

### 4) Long-context quality degradation evidence
Cross-verified across 3 independent papers:
- Lost in the Middle: long-context performance degrades, especially when relevant info is in the middle.
- RULER: many models that claim long windows still show substantial drops as length and task complexity increase.
- Context Length Alone Hurts (2025): even with perfect retrieval, performance drops significantly as input gets longer.

Implication:
- "Fits in context" is not equivalent to "maintains quality".
- Very large preambles raise risk of quality regression from length alone.

### 5) Prompt structure guidance relevant to rewrite agents
- OpenAI and Anthropic both emphasize clarity, specificity, and step-structured instructions.
- OpenAI best-practice guidance also recommends placing instructions clearly and reducing fluff.

Implication:
- Better quality often comes from better structure and precision, not raw token volume.

## Hypothesis tracking
| Hypothesis | Confidence | Supporting evidence | Contradicting evidence |
|---|---|---|---|
| H1: A giant (~60K) preamble will generally produce best rewrite quality | Low | More instruction capacity can improve steerability in some cases | Long-context degradation literature; no direct evidence giant is better for rewrite tasks |
| H2: A bounded "large" preamble (~3K-8K) is a better default tradeoff | High | OpenAI latency + prompting guidance; long-context papers; observed PromptPad benchmark behavior | Could be suboptimal on some rare edge prompts requiring domain-heavy policy detail |
| H3: Caching can make large prefixes practical when prefix reuse is high | Medium-High | OpenAI/Anthropic caching docs | Cache hit is workload-dependent and not guaranteed |
| H4: Web search in default rewrite path hurts latency more than it helps | Medium | Added external retrieval introduces network/tool overhead; rewrite task is usually transformation, not retrieval | Some prompts truly require external facts; research mode could improve quality there |

## Recommended sizing policy
For models near 128K context (including current Spark usage), for draft size D and expected output O:

- Suggested budget formula:
  - `P_max = min(12000, floor(0.10 * C - D - O - S))`
  - where:
    - `C` = model context window
    - `D` = draft tokens
    - `O` = expected completion tokens
    - `S` = safety reserve (1000-2000)

For PromptPad typical rewrite case (`C=128000`, `D~500-1200`, `O~1200-3000`, `S~1500`):
- practical max lands around high single-digit thousands.
- recommended **large profile target: 4K-6K** tokens.
- recommended **hard cap: 10K-12K** unless benchmarks beat baseline.

## Recommended runtime modes
1. `core` (default): low-latency daily use, shortest stable preamble.
2. `large` (opt-in): 4K-6K token preamble for harder draft-to-prompt transformations.
3. `research` (opt-in): enables web search/tooling and longer timeout; not default.

## Verification status
### Verified (2+ sources)
- Long-context quality can degrade as length increases even when model supports long windows. (Lost in the Middle + RULER + Context Length Alone Hurts)
- Prompt caching relies on prefix reuse and can significantly reduce latency when hit conditions are met. (OpenAI prompt-caching docs + Anthropic prompt-caching docs)
- Clear, specific, structured instructions are consistently recommended by major providers. (OpenAI + Anthropic docs)

### Unverified / uncertain
- Exact "optimal" preamble size for Codex-Spark rewrite tasks is not published by OpenAI; must be measured in-house.
- Cache hit rates for Codex CLI/app-server paths under your exact workload are unknown without telemetry.

### Conflicts and interpretation
- OpenAI docs mention that longer detailed prompts can improve quality with smaller/fast models.
- Long-context research warns that excessive context length can hurt quality.

Resolution:
- Use a bounded large prompt (not giant), then benchmark quality/latency pairwise against baseline.

## Self-critique
- Completeness: Addressed size, latency, quality, caching, and web-search tradeoff.
- Source quality: Prioritized official docs + peer-reviewed/major benchmark papers.
- Bias check: Included both "longer can help" and "longer can hurt" evidence.
- Remaining gap: No Codex-Spark-specific public curve for preamble-size vs rewrite quality.

## Actionable plan
1. Keep default on core preamble.
2. Introduce large preamble profile in 4K-6K range.
3. Run matrix benchmark across:
   - preamble size tiers: core, 2K, 4K, 6K, 8K, 12K
   - web search: disabled vs cached
4. Compare pairwise win rate vs xhigh baseline plus latency median/p95.
5. Promote only if quality gains hold with acceptable latency cost.

## Sources
- OpenAI: Introducing GPT-5.3-Codex-Spark
  https://openai.com/index/introducing-gpt-5-3-codex-spark/
- OpenAI: Latency optimization guide
  https://developers.openai.com/api/docs/guides/latency-optimization
- OpenAI: Prompt caching guide
  https://developers.openai.com/api/docs/guides/prompt-caching
- OpenAI: Prompt engineering guide
  https://developers.openai.com/api/docs/guides/prompt-engineering
- OpenAI Help Center: Best practices for prompt engineering
  https://help.openai.com/en/articles/6654000-guidance-for-writing-effective-prompts
- Anthropic: Long context prompting tips
  https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/long-context-tips
- Anthropic: Prompt caching
  https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- Liu et al. (2023/2024): Lost in the Middle
  https://arxiv.org/abs/2307.03172
- Hsieh et al. (2024): RULER
  https://arxiv.org/abs/2404.06654
- Du et al. (2025): Context Length Alone Hurts LLM Performance Despite Perfect Retrieval
  https://arxiv.org/abs/2510.05381
