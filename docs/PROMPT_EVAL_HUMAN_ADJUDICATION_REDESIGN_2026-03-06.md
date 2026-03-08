# Prompt Eval Human Adjudication Redesign (2026-03-06)

## Executive verdict
The current human-adjudication flow is **over-instrumented for the primary goal**.

What matters most for judge lock is whether humans can reliably say **which engineered prompt is better** on realistic cases.
That means the primary label should be:
- winner (`A` / `B` / `Tie` / `BothBad`)
- confidence (`High` / `Medium` / `Low`)
- optional note

Requiring per-candidate `0-100` scores and routine notes adds a lot of burden while providing comparatively weak extra signal.

## What should change

### 1. Make the primary dataset pairwise-first
Primary adjudication lane:
- blinded pairwise judgment only
- required fields:
  - `winner`
  - `confidence`
- optional fields:
  - `note`
  - `needs_tiebreak`

This becomes the main source of lock-grade evidence for:
- pairwise agreement,
- hard-case agreement,
- confidence-weighted agreement,
- disagreement routing,
- judge-vs-human ranking quality.

Recommended overlap policy:
- every case gets **2 blind human raters**,
- any disagreement, `Tie`, `BothBad`, or `Low`-confidence case gets a **3rd blind tie-break rater**,
- lock metrics use the blind-first labels only.

### 2. Stop asking normal raters for 0-100 scores
Reason:
- it creates fake precision,
- it slows reviewers down,
- it increases inconsistency,
- it is not the core label we need.

If numeric absolute scoring is still desired, create a **small secondary anchor lane** reviewed by a smaller expert group on a much smaller prompt set.
That anchor lane should not burden the main adjudication flow.

### 3. Use markdown workbooks, not CSVs, for humans
Recommended reviewer artifact:
- one markdown workbook per rater,
- language-specific packet,
- 8-12 cases ideal, 15 max.

Per case:
- Winner
  - [ ] A
  - [ ] B
  - [ ] Tie
  - [ ] BothBad
- Confidence
  - [ ] High
  - [ ] Medium
  - [ ] Low
- Optional note

This is enough for the main lane.

### 4. Do not show AI assist first
Showing an AI recommendation before the human makes a blind decision creates anchoring bias.
That makes the human label less trustworthy as ground truth.

Optimal usage of the secondary AI assist lane:
- **run it first internally**, yes,
- but **do not show it to the human on first pass**.

Instead use the secondary AI in a second-pass assist lane:
1. human makes a blind first-pass choice,
2. if confidence is low, or if two humans disagree, reveal the AI recommendation,
3. human can keep or revise,
4. record whether the human changed after seeing Gemini.

Critical rule:
- store both `blind_winner` and `post_assist_winner`,
- use `blind_winner` only for judge-lock ground truth,
- treat `post_assist_winner` as secondary workflow/analysis data.

This gives us:
- cleaner human labels,
- useful AI-vs-human comparison data,
- a better tie-break workflow,
- lower bias.

### 5. Split the workflow into 3 lanes

#### Lane A — Blind human primary lane
Used for lock-grade human ground truth.

Fields:
- winner
- confidence
- optional note

#### Lane B — AI assist lane
Used only after blind human first pass, for:
- low-confidence cases,
- ties,
- both-bad,
- human disagreement.

Fields to capture:
- AI recommendation
- AI confidence
- short AI rationale
- whether human changed after seeing AI

#### Lane C — Absolute-score anchor lane (small)
Optional and much smaller.
Used only if we still need absolute-score calibration.

## Recommended packet UX

### Packet structure
- one language per packet
- 8-12 cases ideal
- one markdown file the human edits directly
- one separate AI-assist appendix file
- randomize displayed candidate order per case and store hidden mapping internally

### Human workbook case block
```md
## Case 07 — review_ci_failure_en

### Draft
...

### Candidate A
...

### Candidate B
...

### Your decision
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
```

### AI assist appendix block
```md
## Case 07 — AI second opinion
- AI pick: B
- AI confidence: Medium
- AI rationale: Candidate B preserves the failure-analysis scope and explicit reporting constraint better.
```

This appendix should be viewed only after the blind decision is recorded.

## Confidence rubric
- **High** — clear winner; one option is materially better on multiple important criteria, and you would make the same call again without much hesitation.
- **Medium** — likely winner; one option seems better, but there is at least one meaningful tradeoff or ambiguity.
- **Low** — close call; hard to distinguish, or the choice depends on uncertain interpretation. These cases should usually receive tie-break attention.

## What we gain
- much lower reviewer burden
- faster throughput
- less annotation fatigue
- less fake precision
- cleaner pairwise labels
- better match to actual lock objective

## What we lose
- dense per-candidate numeric labels in the main lane
- some direct absolute-score calibration data

## Why that trade is worth it
Because the primary goal is not “have humans generate many shaky numbers.”
The primary goal is “know whether the judge can pick the better engineered prompt the way humans do.”

That is fundamentally a pairwise task.

## Recommended next implementation
1. Replace reviewer CSV workflow with markdown workbook workflow.
2. Build a parser for workbook checkboxes + optional note.
3. In the compatibility layer only, synthesize legacy numeric fields from `winner + confidence` so the current lock pipeline still runs without asking humans for fake-precision scores.
4. Add a secondary-AI prelabel tool that creates a separate AI-assist appendix.
5. Route low-confidence / disagreement cases into AI-assisted tie-break.
6. Keep a small optional expert-only anchor-score lane if absolute calibration is still needed.

## Immediate recommendation
Do **not** ask regular reviewers to keep doing `0-100` scoring.
Switch the human UX to:
- winner
- confidence
- optional note

and treat the secondary AI as a **post-blind assist**, not a first-view label.
