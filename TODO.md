## Prompt Eval Repo Split (2026-03-12)

- [x] Bootstrap standalone prompt-eval repo: `../prompt-eval-turbodraft`
- [x] Keep TurboDraft runtime repo focused on product/runtime/integration work
- [ ] Design PromptPack/import boundary so prompt content ownership can move cleanly
- [ ] Update TurboDraft runtime to consume exported prompt artifacts instead of repo-local prompt content

## Forge TODO — TurboDraft Product Track (2026-03-12)

## Goal

Use the prompt-eval split to refocus this repo on TurboDraft product/runtime work only.

## Milestones

- [x] T1: Core drafting UX hardening + right-panel productization + required validation gating
- [x] T2: Session-context receiver design / TurboDraft-side integration prep for invoking CLIs
- [x] T3: Expand product QA coverage for real Ctrl+G/Ctrl+Q/sidebar/queue/drafting flows beyond T1 gating
- [x] T5: Add a lazy Settings window for common TurboDraft configuration without regressing launch/open performance
- [ ] T4: Revisit PromptPack/import boundary only after T1-T3 are stable and prompt-eval output shape is real

## Current recommendation

Start with **T1**. It should combine:

- Improve Prompt / Chat Refine state and error surfacing,
- right-panel productization (queue visibility/settings, agent-agnostic copy, panel IA, minimal queue UX gaps),
- and promotion of queue/sidebar/drafting regressions into required validation.

Do **not** start with PromptPack/import work. Temporary prompt duplication is intentional until the external prompt-eval repo produces a real finalized artifact boundary.

### T1 progress

- [x] Queue settings, agent-agnostic queue copy, selection-seeded queue creation, and required validation-gate expansion
- [x] Drafting state/error surfacing follow-up

### T2 progress

- [x] Add receiver-side session-context handoff support (protocol metadata, `turbodraft` env passthrough, drafting-agent injection, docs, tests)

### T3 progress

- [x] Add a repeatable local product-QA runner covering required editor validation plus API open/close regression smoke, with optional real Ctrl+G/Ctrl+Q probing
- [x] Add attached-session API smoke coverage for queue/context handoff metadata and open telemetry validation
- [x] Fix the full-suite JSON-RPC socket test crash so the required Swift suite is stable again
- [x] Make the real UI probe default to low-overhead Ctrl+G dispatch and validate the end-to-end local product-QA run with `RUN_REAL_UI=1`

### T5 progress

- [x] Research current config/menu surface and define a minimal settings scope
- [x] Land a lazy AppKit settings window/controller off the hot path
- [x] Add shared config mutation paths so menu + settings stay in sync
- [x] Add runtime propagation for queue-related settings and validate no open-path regression

# Forge TODO — Prompt Eval Recommendation Execution

## Goal

Proceed with approved prompt-eval recommendations:

- keep Codex 5.3 xhigh as primary judge,
- add Gemini 3.1 Pro + Opus 4.6 escalation on uncertain cases,
- optimize pairwise mirroring/repeats by risk tier,
- add telemetry and guardrails.

## Milestones

- [x] M1: Multi-runner escalation + 2-of-3 consensus in eval runner
- [x] M2: Risk-tier pairwise mirroring/repeats + uncertainty trigger controls
- [x] M3: Provider contract/config updates + telemetry fields
- [x] M4: Review, tests, install, and summary

---

# Forge TODO — Judge Prompt Production Hardening (2026-03-04)

## Goal

Make the LLM judge prompt + pairwise judgment path production-quality for TurboDraft prompt-eval.

## Milestones

- [x] M1: Re-baseline judge prompts (v1-v6) on calibration + symmetry/repeatability
- [x] M2: Adversarial/second-opinion review on winner prompt + pairwise policy
- [x] M3: Implement improvements (prompt + runner rules), add/extend tests
- [x] M4: Run regression eval pack (mini repeated + dev split), verify gates and error budgets
- [x] M5: Final production-readiness decision with explicit pass/fail criteria

## Success criteria

- Zero provider parsing failures in judge path on repeated mini runs
- Stable orientation behavior within configured tolerance
- Judge calibration remains strong on labeled set
- Regression suite green and install complete

## Final decision (current)

- ✅ Infrastructure hardening goals met (errors/timeouts/parsing/tests/install).
- ⚠️ Promotion gate remains **red** under strict evaluation due insufficient family coverage/sample floors and orientation stability threshold.
- ✅ Current recommended judge prompt default: `judge_pairwise_v2.md` (post-fix).

## Notes

- CLAUDE.md/AGENTS.md mirror policy is enforced; no divergent forge sections added.
- Steering files are local-only and excluded via .git/info/exclude.

## Forge TODO — Judge Reboot Execution (2026-03-04)

## Goal

Execute the reboot design from:

- docs/PROMPT_EVAL_JUDGE_REBOOT_2026-03-04.md
- architect/research/llm-judge-eval-redesign-2026-03-04.md

## Milestones

- [x] M1: Build judge-quality dataset framework (gold + natural negatives + synthetic perturbations + split/blinding metadata)
- [x] M2: Implement Arm J runner set (calibration, invariance, injection-robustness, reliability gates)
- [x] M3: Implement Arm O lite with single sequential inference framework + exploration quota/tail recall audits
- [x] M4: Integrate lock criteria and multilingual/cache-drift hard gates into gate evaluation
- [x] M5: Run pilot cycle, produce lock/no-lock decision artifact, and document next promotion steps

## Global success criteria

- Judge lock decision uses sealed test and explicit CI-backed thresholds
- No mixed inferential regime in lock decision
- Family/language coverage and sample floors enforced as hard gates
- Reproducible run artifacts written under bench/prompt_eval/reports/

## Current lock outcome

- Status: **NO_LOCK** (strict lock remains red).
- Primary blocker: `judge_lock_pairwise_labels_floor` (M1 dataset has 225 labels vs required 500).


## Forge TODO — OpenAI Cookbook Deep Crawl (2026-03-05)

- [x] C1: Deep-crawl provided OpenAI Cookbook/GitHub links and relevant internal hyperlinks
- [x] C2: Browser-visit validation with agent-browser for focused source set
- [x] C3: Re-verify/triage external related_resources links into keep/deprecate policy
- [x] C4: Map findings into TurboDraft judge/drafting prompt architecture and eval pipeline recommendations

## Forge TODO — Careful v6 vs v7 Arm J Comparative (2026-03-05)

- [x] P1: Draft comparative rerun design
- [x] P2: Adversarial + performance plan review
- [x] P3: Revise plan with held-out split, A/A control, numeric margins, and cost-safe escalation
- [x] P4: Execute Stage 0–2 real-provider comparative runs (dev/tune + A/A) [completed with tranche caps: Stage1 p30 seeds 53/97; Stage2 p4 seeds 53/97]
- [x] P5: Execute sealed_test checkpoint and publish candidate disposition [completed at tranche caps: calibration p45 seed53 + invariance p4 seed53]


- [ ] P6: Replication block for invariance reliability (increase sealed invariance sample and second sealed seed)

## Forge TODO — Judge-Only Research Reset (2026-03-06)

### Goal
Do proper research-backed judge-only lock workflow using old + latest sources, with compaction-safe goal persistence.

### Milestones
- [x] R1: Reconcile old research and identify invalid assumptions (synthetic-overweight failure mode)
- [x] R2: Run updated external primary-source research refresh (OpenAI/Anthropic/Google/Promptfoo + 2025+ papers)
- [x] R3: Publish reset research synthesis and explicit judge-only lock checklist
- [x] R4: Persist compaction-safe goals in stable docs (AGENTS/CLAUDE + dedicated goals doc)
- [ ] R5: Execute rebuilt real-primary dataset plan and rerun strict lock cycle


## Forge TODO — Judge Lock Spec Freeze + R5 Launch (2026-03-06)

### Goal
Execute judge lock work with immutable numeric criteria and compaction-safe persistence.

### Milestones
- [x] S1: Reconcile old local research and current state
- [x] S2: Run fresh external 2025+ primary-source research and adversarial review
- [x] S3: Freeze canonical lock spec with numeric hard gates and Arm J/Arm O policy
- [ ] S4: Execute R5 against frozen spec (dataset rebuild, calibration, sealed gates, decision)

### Active references
- docs/PROMPT_EVAL_JUDGE_LOCK_SPEC_2026-03-06.md
- docs/PROMPT_EVAL_JUDGE_ONLY_GOALS.md
- architect/research/judge-only-research-refresh-2026-03-06.md
- architect/review-findings/judge-research-refresh-adversarial-2026-03-06.md
- architect/research/high-quality-prompt-sources-2026-03-06.md
- bench/prompt_eval/config/high_quality_prompt_sources.v1.json

### S4 execution status update (2026-03-06)
- [x] S4a: Implement lock preflight tool + tests + README wiring
- [x] S4b: Run preflight and produce current verdict artifact
- [x] S4b.2: Harden preflight against adversarial bypasses (dataset integrity gate, required-family enforcement, artifact-structure checks)
- [x] S4b.3: Integrate adversarial review fixes (near-duplicate fail-closed mode, provenance value validation, pairwise linkage policy)
- [x] S4b.4: Bind Arm J/Arm O artifacts to active dataset fingerprint (manifest payload + pairwise digest checks)
- [x] S4b.5: Rebuild `datasets_r5` under hardened schema and refresh preflight artifact
- [x] S4c.1: Implement human-adjudicated judge_quality import path + exact-per-family integrity mode
- [x] S4c.1b: Human adjudication UX + packet builder/compiler for import-ready triplets
- [x] S4c.1c: Curate blinded `batch1` reviewer kit + campaign plan
- [x] S4c.1d: Replace human-facing CSV flow with markdown workbook + post-blind Gemini appendix + compatibility parser
- [x] S4c.1e: Harden workbook flow against blind leakage, mint fresh blind candidate IDs, and prepare `batch3_blindfresh` reviewer kits
- [x] S4c.1f: Add guided blind-core workbooks, validate-only intake/readiness tooling, and a deficit-aware batch planner to reduce human-label friction
- [x] S4c.1g: Apply guided blind-core follow-up hardening (duplicate-rater rejection, strict readiness gating, canonical deficit-planner de-duplication)
- [x] S4c.1h: Generate `batch4_guidedcore` AI-assisted companion packs with Auggie GPT-5.4 for non-lock expansion review
- [ ] S4c.2: Import real-primary dataset and execute Arm J/Arm O strict runs on the `gpt-5.4 xhigh` judge baseline

Current verdict artifact:
- bench/prompt_eval/reports/judge_lock_readiness_20260306/summary.json (`NO_LOCK`)


## Forge TODO — Sidebar Chat Recovery + Shared Queue Integration (2026-03-08)

### Goal
Safely recover the stranded full sidebar-chat implementation from `wip/local-snapshot-2026-02-28`, then use that recovered right-panel surface as the foundation for optional Claude Pager shared-queue integration without regressing TurboDraft's agent-agnostic behavior.

### Milestones
- [x] Q1: Audit branches/worktrees/local folders and confirm where the sidebar-chat implementation lives
- [x] Q2: Write recovery architecture/brainstorm note covering agent-agnostic queue integration and panel design
- [x] Q3: Produce a careful port plan for the sidebar-chat recovery (recommended slices, risks, acceptance criteria)
- [x] Q4: Recover the sidebar shell + chat surface onto the current branch without queue behavior changes yet
- [x] Q5: Review/test recovered sidebar behavior, including no window-resize regression
- [x] Q6a: Fix authoritative `session.close` / `session.wait` semantics so Ctrl+Q only resolves after the target session UI is actually gone
- [x] Q6b: Freeze Claude Pager queue contract + metadata compatibility matrix before shared queue write/sync work
- [x] Q6c: Add optional external queue metadata handshake and session attachment plumbing
- [x] Q7: Implement shared queue file model with round-trip-safe reader/writer/watcher behavior
- [x] Q8: Implement queue tab UI on top of the recovered right-panel host

### Recovery constraints
- Do **not** assume the missing sidebar was never built; preserve prior work from `5dc675b` on `wip/local-snapshot-2026-02-28`.
- Do **not** blindly cherry-pick the full snapshot diff without audit.
- Keep TurboDraft agent-agnostic; Claude Pager queue UI must be optional and metadata-driven.
- Recovered panel resizing must never resize the entire app window.
- Do **not** write shared queue files until the line contract and unknown-field preservation policy are frozen.

---

## Forge TODO — Codex Drafting Backend Stabilization (2026-03-09)

### Goal
Finish the TurboDraft backend implementation so Codex-backed drafting is production-ready before the prompt-eval campaign finishes, allowing prompt/preset swaps later without more transport/runtime work.

### Milestones
- [x] B1: Audit current Codex exec/app-server behavior and freeze the routing policy for `drafting_agent`
- [x] B2: Fix app-server protocol/completion handling and make it a viable primary Codex route
- [x] B3: Add adaptive fallback / health handling for Codex drafting routes plus clearer route/error surfacing
- [x] B4: Add/expand regression coverage for real route semantics, review findings, install, and checkpoint commit

### Constraints
- Keep TurboDraft agent-agnostic at the product layer.
- Do not require prompt-eval completion to finish backend transport/runtime work.
- Do not hard-force app-server-only if exec remains needed as fallback.
