# TurboDraft Autonomous Prompt-Eval Master Plan (Codex CLI Grounded)
Date: 2026-03-01
Version: v3.0
Execution Mode: No-human-in-loop (autonomous)
Runtime Grounding: Codex 5.3 on Codex CLI with multi-agent enabled

---

## 1) Runtime Grounding (explicit)
This plan is grounded to the **actual runtime capabilities available now**:
- Codex CLI multi-agent primitives (`spawn_agent`, `send_input`, `wait`, `close_agent`)
- Specialized subagent roles:
  - `explorer`: codebase investigation and authoritative findings
  - `worker`: implementation ownership
  - `awaiter`: mandatory for long-running commands (tests/benchmarks/monitoring)
- Parallel tool orchestration (`multi_tool_use.parallel`) for independent tasks
- Local shell and file operations via `exec_command` and `apply_patch`

No step in this plan assumes tools that are not available in this runtime.

---

## 2) Objective
Autonomously produce, validate, and promote prompt presets that outperform baseline with statistically defensible evidence, reproducibility, and automatic regression guardrails.

Completion requires all preset families to pass confirmatory holdout gates and CI protection gates.

---

## 3) Non-negotiable invariants
1. Holdout never used for tuning.
2. Gate policy/judge prompt/scoring frozen per cycle.
3. Two-phase promotion commit (stage -> verify -> activate).
4. Every task idempotent and replay-safe.
5. Every decision backed by artifacts + reason codes.
6. Critical integrity violation => SAFE_MODE.
7. Missing/invalid gate-manifest fields => fail-closed (halt phase).

---

## 4) Research-grounded principles (2025-2026)
1. Prefer pairwise/classification evals for model judging tasks.
2. Calibrate and stress-test LLM judges for consistency before trusting scores.
3. Combine deterministic checks with model-graded checks.
4. Use orchestrator-worker parallel design with durable checkpoints.
5. Run continuous eval loops in CI (PR fast, nightly full, protected holdout).

## 4.1) Holistic source policy (required)
Every cycle must keep a frozen research artifact with coverage across:
- OpenAI official docs
- Anthropic official docs
- Google/Gemini official docs
- Promptfoo official docs
- Recent non-provider literature (>= 2025-06)

Enforcement:
- `gate_manifest.v1.json -> source_policy`
- `validate_holistic_sources.py` in phase0 bootstrap

---

## 5) Agent topology and ownership
## 5.1 Control-plane
- `orchestrator_agent` (default): owns phase transitions and policy freeze.
- `audit_agent` (default): validates invariants, leakage, and anti-gaming checks.

## 5.2 Work-plane
- `dataset_agent` (worker): split curation, dedup, contamination defense.
- `judge_agent` (worker): judge prompts, calibration, consistency diagnostics.
- `preset_agent_<family>` (worker): candidate drafting prompts per family.
- `eval_agent` (worker): Promptfoo + custom harness execution.
- `stats_agent` (worker): CIs, hypothesis tests, multiplicity correction.
- `ci_agent` (worker): workflow wiring, cache keys, artifact publishing.
- `repair_agent` (worker): root-cause patch loops.

## 5.3 Long-running rule
All long-running runs (test suites, benchmark waves, CI polling) must be launched through `awaiter` agents.

---

## 6) Durable scheduler contract
Task lifecycle:
`queued -> leased -> running -> succeeded | failed | dead_letter`

Required task fields:
- `task_id`, `phase`, `preset_family`, `attempt`
- `idempotency_key`, `lease_expiry`, `lease_token`
- `input_hash`, `output_hash`, `reason_codes[]`

Lease safety:
- heartbeat every 30s
- stale lease reclaim
- stale completion write rejected on lease-token mismatch

Dead-letter policy:
- classify dead letters as `critical` or `non_critical`
- phase exit requires zero unresolved `critical` dead letters
- any critical dead letter forces SAFE_MODE and incident record

---

## 7) Artifact contract (must exist)
## 7.1 Promptfoo configs
- `bench/prompt_eval/config/base.promptfoo.yaml`
- `bench/prompt_eval/config/dev.promptfoo.yaml`
- `bench/prompt_eval/config/adversarial.promptfoo.yaml`
- `bench/prompt_eval/config/holdout.promptfoo.yaml`
- `bench/prompt_eval/config/providers.yaml`

## 7.2 Policy + manifests
- `bench/prompt_eval/config/gate_manifest.v1.json`
- `bench/prompt_eval/config/run_manifest.schema.json`
- `bench/prompt_eval/config/environment_contract.v1.json`
- `bench/prompt_eval/config/candidate_registry.v1.json`

## 7.3 Datasets
- `bench/prompt_eval/datasets/calibration/*.jsonl`
- `bench/prompt_eval/datasets/dev/*.jsonl`
- `bench/prompt_eval/datasets/adversarial/*.jsonl`
- `bench/prompt_eval/datasets/holdout/*.jsonl`

## 7.4 Reports
- `bench/prompt_eval/reports/<cycle>/<phase>/...`

---

## 8) Statistical framework (pre-registered)
Primary confirmatory test per preset family:
- one-sided exact binomial on non-tie pairwise outcomes
- H0: p <= 0.50, H1: p > 0.50, alpha=0.05
- 95% Wilson CI lower bound must exceed 0.50

Tie policy:
- primary: ties excluded from denominator
- sensitivity A: ties = 0.5 win
- sensitivity B: ties = loss

Multiplicity:
- Holm-Bonferroni across preset families on confirmatory p-values
- sequential-look control across reruns on same holdout: alpha-spending with O'Brien-Fleming style boundaries

Power targets (non-tie pairs per family):
- +10pp uplift target: ~160
- +7pp uplift target: ~320
- +5pp uplift target: ~620

Default operating target: **>=320 non-tie holdout pairs per family**.

Critical hard-failure reliability gate:
- 0 critical failures over >=300 cases/cycle (95% upper bound <1%).

Holdout reuse policy:
- holdout has a max look budget per cycle (`max_holdout_looks = 1` confirmatory look)
- if cycle fails and retries are needed, use next lockbox holdout partition
- previously used holdout partitions are retired from tuning loops

---

## 9) Judge reliability protocol
Before any candidate promotion run:
1. judge prompt bake-off (>=2 prompts)
2. calibration set evaluation
3. symmetry A/B swap evaluation
4. repeatability (5-10 repeat seeds)
5. transitivity triad diagnostics
6. shadow-judge drift check
7. truth-anchor check against immutable adjudicated gold set

Judge gates:
- invalid judge JSON rate = 0
- calibration accuracy >= 0.85
- symmetry >= 0.95
- repeat agreement >= 0.90
- transitivity-violation CI upper <= 0.10
- shadow judge disagreement <= 0.08
- gold-anchor accuracy >= 0.80

---

## 10) Candidate generation policy
Per preset family, generate:
- B0 baseline
- C1 precision-focused
- C2 contract-stability-focused
- C3 robustness-focused (optional)

Mandatory static lint gates before eval:
- no role leakage (`drafting_agent` / `execution_agent`)
- required section presence
- schema/contract format validity
- forbidden-pattern checks

---

## 11) Promptfoo vs custom harness responsibilities
Promptfoo:
- matrix orchestration
- deterministic assertions
- model-graded assertions (`llm-rubric`, `select-best`, `max-score` where applicable)
- CI-visible artifacts

Custom scripts:
- judge calibration/symmetry/repeat/transitivity
- advanced statistics and robustness diagnostics
- gate adjudication and reason-code synthesis

---

## 12) Autonomous phase execution (parallel)
## Phase 0: Control-plane bootstrap
Parallel:
- scheduler/checkpoint implementation
- manifest schema + gate manifest
- fail-safe state machine wiring
Exit:
- replay and lease-reclaim tests pass

## Phase A: Policy freeze
Parallel:
- preset contract freeze
- selection policy freeze
- scoring/gate freeze
Exit:
- immutable cycle policy snapshot signed

## Phase B: Judge reliability
Parallel:
- calibration expansion
- judge bake-off
- reliability diagnostics
Exit:
- all judge gates pass

## Phase C: Candidate generation
Parallel:
- one worker lane per preset family
- shared static-lint lane
Exit:
- candidate set validated

## Phase D: Dev wave (exploratory)
Parallel:
- promptfoo dev runs
- failure clustering
- pruning
Exit:
- top-2 per family

## Phase E: Adversarial wave
Parallel:
- adversarial eval
- anti-gaming perturbation tests
- robustness scoring
Exit:
- one finalist per family

## Phase F: Holdout confirmatory wave
Parallel:
- locked finalist holdout runs
- significance + CI + multiplicity
- shadow-judge drift audit
Exit:
- pass/fail decision per family

## Phase G: Promotion + guardrails
Parallel:
- two-phase promotion commit
- CI gate activation
- rollback snapshot + smoke test
Exit:
- cycle complete if all required families pass or are policy-deferred

---

## 13) Promotion gate (all required)
Per preset family:
1. judge gates pass
2. critical hard failures = 0 over >=300 evaluated cases
3. holdout win-rate lower 95% CI > 0.50
4. Holm-adjusted p < 0.05
5. non-loss rate >= 0.65
6. no critical adversarial regression
7. repeat stability stddev(win_rate) <= 0.03 over >=5 repeats
8. holdout non-tie sample size >=320 for the family (default target)
9. shadow-judge drift <= 0.08
10. gold-anchor accuracy gate remains green in same cycle

---

## 14) Self-repair protocol
Trigger classes:
- JUDGE_FAILURE
- DATA_LEAKAGE
- PROMPT_REGRESSION
- CI_INSTABILITY
- COST_OVERRUN

Loop limits:
- max 5 attempts per phase
- plateau (no improvement in 2 consecutive attempts) => SAFE_MODE
- each attempt logs root cause, patch, expected gain, observed gain
- repair agent cannot mutate frozen gate manifest in-cycle

---

## 15) Fail-safe state machine
Modes:
- NORMAL
- SEQUENTIAL_MODE (single-agent fallback with same policies/gates)
- SAFE_MODE (diagnostics-only)
- RECOVERY_MODE (rollback + replay)
- RESEED_MODE (dataset regeneration)

Transition rules:
- NORMAL -> SAFE_MODE on invariant breach or repeated critical failure
- NORMAL -> SEQUENTIAL_MODE on multi-agent health degradation
- SEQUENTIAL_MODE -> NORMAL only after multi-agent health probe passes
- SEQUENTIAL_MODE -> SAFE_MODE on invariant breach or repeated critical failure
- SAFE_MODE -> RECOVERY_MODE only after incident report emitted
- RECOVERY_MODE -> NORMAL only after replay + invariant pass
- RESEED_MODE entry only from SAFE_MODE
- mode oscillation >2 in one cycle => halt cycle and archive incident

---

## 16) Checkpointing and replay
Atomic checkpoint:
1. append WAL event
2. write snapshot tmp
3. compute checksum + manifest hash
4. fsync
5. atomic rename

Replay:
- restore last valid hash-matching snapshot
- quarantine corrupt snapshots
- requeue leased/running tasks with incremented attempts

---

## 17) CI/CD topology
Required workflows:
1. `prompt-eval-pr-fast.yml` (dev split, PR)
2. `prompt-eval-nightly.yml` (dev + adversarial + repeats)
3. `prompt-eval-holdout.yml` (protected)
4. `prompt-promotion.yml` (gates green only)
5. `prompt-recovery.yml` (rollback + revalidation)

All workflows publish:
- run manifest
- gate report
- decision report
- reproducibility bundle (config hash, dataset hash, model/judge versions)

Budget circuit breakers (all workflows):
- per-cycle max token budget
- per-cycle max cost budget
- per-cycle max wall-clock budget
- 80% budget usage => warning + concurrency reduction
- 100% budget usage => stop model calls and enter SAFE_MODE

---

## 18) Continuous research refresh (mandatory)
Run refresh before changing gates/judge/scoring/tie policy:
1. broad landscape scan
2. targeted deep dive
3. 2+ source verification per major claim
4. contradiction log
5. confidence annotation
6. policy-change proposal

Recency preference:
- prioritize sources >= 2025-06 unless foundational methods are required.

Truth-anchor maintenance:
- maintain immutable gold adjudication set (versioned)
- any gold-set edit requires new version and fresh calibration cycle

---

## 19) Completion criteria
Complete only when:
1. each preset family has promoted winner OR formal deferred status with reason
2. holdout confirmatory evidence archived per family
3. CI guardrails enabled and green on main
4. rollback tested and passing
5. no open critical incidents

---

## 20) First execution backlog (fully autonomous)
1. create Promptfoo configs + manifests
2. create split datasets and leakage scanner
3. run judge reliability cycle and lock judge
4. generate per-family candidates
5. execute dev/adversarial waves + prune
6. execute holdout confirmatory wave
7. promote winners via two-phase commit
8. enable CI regression gates and archive cycle report

---

## 21) Codex CLI multi-agent safeguards (runtime-specific)
Codex docs label multi-agent collaboration as experimental; enforce runtime guards:

1. **Feature-health probe at cycle start**
   - launch 2 trivial subagents and verify spawn/wait/close lifecycle.
   - if probe fails, downgrade cycle to `SEQUENTIAL_MODE`.

2. **Controlled concurrency**
   - default max parallel subagents = 6
   - if transient spawn/wait failure rate > 5% in a phase, reduce parallelism by 50%.
   - if still > 5%, force `SEQUENTIAL_MODE` for remaining phase tasks.

3. **Long-running-task isolation**
   - all long tests/evals run through `awaiter` agents only.
   - kill/requeue if no heartbeat or no progress event for timeout window.

4. **Deterministic handoff envelope**
   - each agent task includes immutable input payload hash, expected outputs, and time budget.
   - reject outputs missing required envelope fields.

5. **Fallback continuity**
   - `SEQUENTIAL_MODE` must preserve the same gates/artifact contracts.
   - no policy relaxation permitted during fallback.

---

## 22) Fail-closed gate manifest contract (machine-enforced)
`gate_manifest.v1.json` must include explicit numeric/enumerated values for:
- required preset families
- per-family minimum sample floors
- judge thresholds
- promotion thresholds
- drift thresholds
- repeat thresholds
- budget caps
- holdout look budget

Validation rule:
- missing key, invalid type/range, or schema mismatch => hard stop before eval.

---

## 23) Holdout isolation enforcement (mechanical)
Access control rules:
1. Candidate-generation and repair agents cannot read holdout files.
2. Holdout files are readable only by confirmatory-phase eval/stats agents.
3. Holdout outputs are write-only into report artifacts; not writable back into datasets.
4. Any out-of-phase holdout access attempt => SAFE_MODE + incident report.
