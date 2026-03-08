# Prompt Eval Hybrid Adjudication Workflow (2026-03-08)

## Executive decision

Use **two adjudication lanes**:

1. **Blind gold lane** for lock-grade evidence.
2. **AI-assisted expansion lane** for throughput, disagreement analysis, and cheap scaling.

Do **not** mix them when deciding whether the judge is locked.

## Why

Non-expert humans often cannot reliably decide which of two polished prompts is better just by reading them.
If we show AI first, we gain throughput but lose independence.

So the workflow must separate:
- **independent evidence** from
- **assisted workflow signal**.

## Lane A — blind gold lane

Purpose:
- lock-grade calibration evidence for the judge.

Properties:
- human sees no AI recommendation,
- human records winner + confidence + optional note,
- at least 2 blind raters,
- disagreement / Tie / BothBad / Low-confidence goes to tie-break or escalation.

Tools:
- `build_human_adjudication_workbook.py`
- `build_human_adjudication_guided_workbook.py`
- `parse_human_adjudication_workbook.py`

Recommended variant for non-expert raters:
- use the **guided blind-core** workbook when the case is still lock-grade eligible but humans need checklist/disqualifier aids.
- preserve the same blind-first rule and the same parse/compile/import path.

Metadata expectation:
- `review_metadata.adjudication_lane = blind_gold`
- `review_metadata.lock_eligible = true`

## Lane B — AI-assisted expansion lane

Purpose:
- help non-expert humans,
- scale labeling throughput,
- study human-vs-AI agreement patterns,
- collect secondary evidence on harder or lower-value cases.

Properties:
- human sees AI model assessment first,
- human records whether they agree or override,
- final human decision is still captured,
- this lane is **not lock-grade**.

Tools:
- `generate_human_adjudication_ai_assist.py`
- `build_human_adjudication_assisted_workbook.py`
- `parse_human_adjudication_assisted_workbook.py`

Metadata expectation:
- `review_metadata.adjudication_lane = assisted_expansion`
- `review_metadata.lock_eligible = false`

## Human UX for assisted lane

Per case:
- AI pick
- AI confidence
- AI rationale
- Human relation to AI:
  - Agree
  - Disagree / override
- Final winner:
  - A / B / Tie / BothBad
- Confidence:
  - High / Medium / Low
- Optional note

## What counts for judge lock

Only **Lane A**.

Lane B can inform:
- candidate triage,
- disagreement analysis,
- rater training,
- future dataset curation,
- judge prompt iteration,

but not final lock promotion by itself.

## When to use which lane

### Use blind gold lane when:
- the case is central to lock decisions,
- we need independent human evidence,
- the case is strong enough that humans can adjudicate it without AI help.

### Use assisted expansion lane when:
- cases are too difficult for non-expert blind raters,
- we want more throughput,
- we are collecting secondary/non-lock evidence,
- we want to measure human-AI agreement.

## Case selection guidance

Blind gold lane should contain:
- adjudicable cases,
- meaningful but legible differences,
- strong relevance to real TurboDraft prompt engineering.

Assisted lane can absorb:
- more ambiguous cases,
- harder close calls,
- lower-priority breadth coverage,
- exploratory prompt families.

## Bottom line

Do not force one lane to do both jobs.

Use:
- a **small, clean blind core** for truth,
- a **larger AI-assisted expansion set** for speed.
