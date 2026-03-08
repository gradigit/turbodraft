#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import random
from typing import Any

from armj_common import pearson, rank, write_json

REPO = pathlib.Path(__file__).resolve().parents[3]


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def spearman(xs: list[float], ys: list[float]) -> float:
    if len(xs) != len(ys) or len(xs) < 2:
        return 0.0
    return pearson(rank(xs), rank(ys))


def extract_ranking_from_summary(summary: dict[str, Any]) -> dict[str, float]:
    rankings: dict[str, float] = {}
    results = summary.get("results")
    baseline = str(summary.get("baseline_variant") or "overlay_baseline")
    if isinstance(results, dict):
        for variant, data in results.items():
            if variant == baseline or not isinstance(data, dict):
                continue
            pair = data.get("pairwise_vs_baseline") or {}
            if not isinstance(pair, dict):
                continue
            score = pair.get("win_rate")
            if isinstance(score, (int, float)) and not isinstance(score, bool):
                rankings[str(variant)] = float(score)
    if rankings:
        return rankings

    ranked_candidates = summary.get("ranked_candidates")
    if isinstance(ranked_candidates, list):
        for row in ranked_candidates:
            if not isinstance(row, dict):
                continue
            variant = row.get("variant")
            score = row.get("outcome_score")
            if isinstance(variant, str) and isinstance(score, (int, float)) and not isinstance(score, bool):
                rankings[variant] = float(score)
    return rankings


def bootstrap_ci(
    *,
    variant_ids: list[str],
    judge_scores: dict[str, float],
    outcome_scores: dict[str, float],
    rounds: int,
    seed: int,
) -> tuple[float, float]:
    if len(variant_ids) < 2:
        return 0.0, 0.0
    rng = random.Random(seed)
    values: list[float] = []
    for _ in range(max(1, rounds)):
        sampled = [variant_ids[rng.randrange(len(variant_ids))] for _ in range(len(variant_ids))]
        xs = [judge_scores[vid] for vid in sampled]
        ys = [outcome_scores[vid] for vid in sampled]
        values.append(spearman(xs, ys))
    values.sort()
    lo_idx = int(0.025 * (len(values) - 1))
    hi_idx = int(0.975 * (len(values) - 1))
    return float(values[lo_idx]), float(values[hi_idx])


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Arm J vs Arm O rank meta-agreement check.")
    parser.add_argument("--repo", default=str(REPO))
    parser.add_argument("--judge-summary", required=True)
    parser.add_argument("--outcome-summary", required=True)
    parser.add_argument("--rho-min", type=float, default=0.50)
    parser.add_argument("--rho-ci95-lower-min", type=float, default=0.30)
    parser.add_argument("--min-shared-for-ci-floor", type=int, default=5)
    parser.add_argument("--bootstrap-rounds", type=int, default=500)
    parser.add_argument("--seed", type=int, default=20260305)
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    judge_summary_path = pathlib.Path(args.judge_summary).resolve()
    if not judge_summary_path.is_absolute():
        judge_summary_path = (repo / args.judge_summary).resolve()
    outcome_summary_path = pathlib.Path(args.outcome_summary).resolve()
    if not outcome_summary_path.is_absolute():
        outcome_summary_path = (repo / args.outcome_summary).resolve()

    judge_summary = load_json(judge_summary_path)
    outcome_summary = load_json(outcome_summary_path)
    judge_scores = extract_ranking_from_summary(judge_summary)
    outcome_scores = extract_ranking_from_summary(outcome_summary)

    shared = sorted(set(judge_scores).intersection(outcome_scores))
    if len(shared) < 2:
        raise RuntimeError(
            "meta-agreement requires at least two shared variants; "
            f"judge={len(judge_scores)} outcome={len(outcome_scores)} shared={len(shared)}"
        )

    judge_vals = [judge_scores[variant] for variant in shared]
    outcome_vals = [outcome_scores[variant] for variant in shared]
    rho = spearman(judge_vals, outcome_vals)
    rho_lo, rho_hi = bootstrap_ci(
        variant_ids=shared,
        judge_scores=judge_scores,
        outcome_scores=outcome_scores,
        rounds=max(1, int(args.bootstrap_rounds)),
        seed=int(args.seed),
    )
    checks = {
        "rho_floor": float(rho) >= float(args.rho_min),
        "rho_ci95_lower_floor": (
            True
            if len(shared) < int(args.min_shared_for_ci_floor)
            else float(rho_lo) >= float(args.rho_ci95_lower_min)
        ),
        "shared_variant_floor": len(shared) >= 2,
    }
    ok = all(checks.values())
    reason_codes = [f"CHECK_FAILED:{name}" for name, passed in checks.items() if not passed]

    payload = {
        "ok": ok,
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "inference_regime": str(outcome_summary.get("inference_regime") or ""),
        "judge_summary_path": str(judge_summary_path),
        "outcome_summary_path": str(outcome_summary_path),
        "shared_variants": shared,
        "shared_variant_count": len(shared),
        "rho_spearman": float(rho),
        "rho_ci95": [float(rho_lo), float(rho_hi)],
        "metrics": {
            "total_tasks": (
                (outcome_summary.get("metrics") or {}).get("total_tasks")
                if isinstance(outcome_summary.get("metrics"), dict)
                else None
            ),
            "family_non_tie_counts": (
                (outcome_summary.get("metrics") or {}).get("family_non_tie_counts")
                if isinstance(outcome_summary.get("metrics"), dict)
                else {}
            ),
            "exploration_share": (
                (outcome_summary.get("metrics") or {}).get("exploration_share")
                if isinstance(outcome_summary.get("metrics"), dict)
                else None
            ),
        },
        "checks": checks,
        "reason_codes": reason_codes,
        "thresholds": {
            "rho_min": float(args.rho_min),
            "rho_ci95_lower_min": float(args.rho_ci95_lower_min),
            "min_shared_for_ci_floor": int(args.min_shared_for_ci_floor),
        },
    }
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = pathlib.Path(args.out).resolve() if args.out else (repo / "bench/prompt_eval/reports" / f"meta_agreement_{stamp}" / "summary.json")
    write_json(out_path, payload)
    print(json.dumps({"ok": ok, "out": str(out_path), "summary": payload}, indent=2, ensure_ascii=False))
    return 0 if ok else 3


if __name__ == "__main__":
    raise SystemExit(main())
