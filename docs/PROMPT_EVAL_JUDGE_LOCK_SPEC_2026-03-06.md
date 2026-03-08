# Prompt Eval Judge Lock Spec (Frozen v1)

Last updated: 2026-03-06  
Status: ACTIVE (must be frozen before any R5 execution)

## Purpose
Prevent metric gaming and moving-goalpost decisions while locking the LLM judge.

## Rule 0 (immutability)
After first R5 run starts, this spec cannot change. Any change invalidates the run and requires a new version + full rerun.

## Lock levels
- **Level J (Judge Lock):** judge-only reliability/calibration lock.
- **Level P (Production Lock):** Level J + outcome-grounded external-validity lock (Arm O).

Promotion to production requires **Level P**.

## Dataset gates (hard)
1. Adjudicated pairwise labels: `N >= 500`
2. Sealed set labels: `N >= 200`
3. Prompt-family floor: `>= 5` families, each `>= 40` items
4. Language floor: `>= 2` languages, each `>= 80` items
5. Any single family share: `<= 40%` of total
6. Sealed provenance: `0` synthetic-derived items
7. Split leakage: `0` lineage collisions across dev/tune/sealed

## Arm J gates (hard)
All must pass on sealed split:
1. Human-agreement (pairwise accuracy): `>= 0.78`
2. Chance-corrected agreement (Krippendorff alpha): `>= 0.55`
3. Critical-defect recall: `>= 0.90`
4. Mirror symmetry error (A/B swap disagreement): `<= 0.10`
5. Repeatability error (same input repeated): `<= 0.12`
6. Invariance/adversarial fail rate: `<= 0.08`
7. Reliability caps:
   - invalid JSON or unparseable: `<= 0.5%`
   - runtime/provider failures: `<= 1.0%`
   - timeout: `<= 1.0%`
8. Replication seeds: pass on `>= 2` seeds

## Noise-floor gate (hard)
Candidate improvements must exceed A/A noise envelope:
- `delta(candidate, baseline) > max(0.02 absolute, 1.5 * aa_ci_halfwidth)`

## Arm O gates (hard for Level P)
1. Outcome metric delta vs baseline: `>= +0.03` absolute
2. Tail-failure rate does not regress by `> 0.01` absolute
3. Reliability caps same as Arm J
4. Replication pass on `>= 2` seeds

## Decision policy
- Any hard-gate failure => `NO_LOCK`
- Level J pass + Level P fail => `J_LOCK_ONLY` (not production)
- Level J pass + Level P pass => `LOCK`

## Artifact requirements
Each run must write:
- frozen config snapshot
- dataset manifest + provenance audit
- gate metrics JSON
- decision memo JSON

Path root:
`bench/prompt_eval/reports/`

