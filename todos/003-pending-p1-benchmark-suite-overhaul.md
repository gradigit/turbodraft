# Benchmark Suite Overhaul

**Status:** pending
**Priority:** p1
**Tags:** benchmark, quality, refactor

## Problem Statement

The prompt-engineering benchmark suite has accumulated integrity issues that make benchmark results unreliable. Fixtures are self-referential (about TurboDraft itself), already-refined (not raw user input), or corrupted. The quality scorer rewards structure over substance. The infrastructure has stale references and misplaced files.

This TODO captures all findings from the audit and provides a phased checklist for the overhaul.

## Findings

### A. Fixture Problems

- [ ] **dictation_flush_mode.md** — contains a prompt-engineer OUTPUT (with "Implementation Steps", "Agent Decisions" sections), not the original raw voice dictation. The original was never committed to git and is lost. Needs replacement with a real raw draft.
- [ ] **prompt_engineering_draft.md** — meta-circular fixture. Lines 1-11 are a short version of the system preamble ("You are an AI assistant that will be given a draft prompt..."). Lines 14-48 are an already-structured prompt about building TurboDraft with proper Goal/Requirements/Constraints/Deliverables/Acceptance Criteria. This is a softball — it scores 100/100 because it's already well-structured. Replace with a genuinely rough draft.
- [ ] **run_on_promptpad_vision.md** — raw dictation about building TurboDraft itself. Self-referential when the system preamble says "You are TurboDraft."
- [ ] **question_heavy_workflow_research.md** — references "prompt pad editor concept." Self-referential.
- [ ] **bug_heavy_agent_clipboard_fail.md** — references `[Image #1]` but no image exists. The benchmark can't evaluate how the model handles image references.
- [ ] **simple_server_feasibility.md** — mentions "spark model" (implicitly about Codex/TurboDraft infrastructure).
- [ ] **simple_high_work_implement_plan.md** — baseline exists in bench/baselines/profiles/ but no matching fixture exists.
- [ ] **No domain diversity** — all fixtures are software/tech/AI. No business planning, research, creative, non-English, or non-tech prompts.

### B. Quality Scoring Problems

- [ ] **Heuristic scorer rewards structure, not quality.** Points for headings (+10), bullets (+10), specific sections (acceptance criteria +10, deliverables +10). A verbose, template-looking output with garbage content can score 100. A correct, concise response to a simple question gets penalized.
- [ ] **Model-as-judge disabled by default.** The heuristic is the only thing that runs unless you explicitly pass --judge-model. The judge evaluates 6 semantic dimensions (fidelity, structure, specificity, constraints, testability, safety) but isn't used in normal runs.
- [ ] **Pairwise comparison disabled by default.** The baseline comparison that would catch quality regressions doesn't run unless you pass --pairwise.
- [ ] **No input-complexity scaling.** A one-liner bug report ("Nothing opens when I run the app") is evaluated with the same rubric as a 2800-char dictation. The scorer expects headings and acceptance criteria from both.

### C. Methodology Problems

- [ ] **Self-referential preamble.** System preamble says "You are TurboDraft, a prompt engineering assistant." When fixtures are also about TurboDraft, the model may conflate its identity with the task.
- [ ] **CWD is the TurboDraft repo.** While the model doesn't get codebase context by default, running from the repo dir risks leaking context in edge cases.
- [ ] **No regression tracking.** Each benchmark run is independent. No tracking of quality trends over time or between model versions.

### D. Infrastructure Issues (DONE)

- [x] **profile_set.txt stale reference** — fixed: run_on_turbodraft_vision.md → run_on_promptpad_vision.md
- [x] **Misplaced top-level baseline** — fixed: removed bench/baselines/dictation_flush_mode.md
- [x] **dictation_flush_mode.md corrupted with benchmark junk** — fixed: restored (note: content is still wrong — it's a prompt-engineer output, not raw dictation)

## Proposed Approach

### Phase 1: New Fixtures (replace self-referential and corrupted ones)

- [ ] Write 6-8 new fixtures that are:
  - Domain-diverse (at least: one software bug, one business/marketing, one research/analysis, one creative, one technical architecture, one short ambiguous request)
  - Genuinely rough (typos, incomplete sentences, stream-of-consciousness, voice dictation artifacts)
  - NOT about TurboDraft, prompt engineering, or AI tools
  - Varying length (one-liner to multi-paragraph)
- [ ] Create matching gold-standard baselines for each (manually reviewed)
- [ ] Remove or archive the self-referential fixtures
- [ ] Update profile_set.txt with new fixture list

### Phase 2: Scoring Improvements

- [ ] Make model-as-judge the default scorer (heuristic as sanity-check pre-filter only)
- [ ] Add input-complexity awareness: simple inputs (< 100 chars) shouldn't be penalized for missing sections
- [ ] Add a "fidelity" check: did the output preserve all explicit requirements from the input?
- [ ] Add a "no-hallucination" check: did the output add requirements that weren't in the input (without marking them as optional)?
- [ ] Consider per-fixture-category scoring rubrics (bug report vs vision statement vs research request)

### Phase 3: Methodology Fixes

- [ ] Rename preamble identity from "You are TurboDraft" to something generic ("You are a prompt-engineering assistant")
- [ ] Run benchmarks from a neutral temp directory, not the TurboDraft repo
- [ ] Add regression tracking: store results in a dated JSON file, compare across runs
- [ ] Enable pairwise comparison by default when baselines exist

## Acceptance Criteria

- [ ] All fixtures are raw, rough user input — not already-refined prompts
- [ ] No fixture references TurboDraft, PromptPad, or the benchmarking system itself
- [ ] Quality scores correlate with actual output quality (verified by manual review of edge cases)
- [ ] Model-as-judge runs by default
- [ ] Benchmark results are reproducible and tracked across runs
- [ ] Full fixture set covers at least 4 different domains
