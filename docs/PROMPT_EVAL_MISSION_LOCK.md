# Prompt Eval Mission Lock

Date: 2026-03-05

## Core objective
Lock an LLM judge that can accurately evaluate **real prompt engineering quality** for TurboDraft.

## Non-goals
- Do not treat synthetic perturbation-only wins as lock-grade evidence.
- Do not optimize drafting presets before judge lock.

## Required evidence order
1. Real engineered prompt benchmark (primary evidence).
2. Judge calibration + robustness + reliability on that benchmark.
3. Sealed holdout pass for lock eligibility.
4. Drafting prompt optimization with locked judge.

## Evidence labeling
Every report must label itself as:
- `primary` (real engineered benchmark), or
- `secondary` (synthetic sanity).

## Promotion rule
No judge-prompt promotion without primary + sealed evidence.
