#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import pathlib
import random
from typing import Any

from armj_common import median, write_json

REPO = pathlib.Path(__file__).resolve().parents[3]
DEFAULT_PHASE_SUMMARY = REPO / "bench/prompt_eval/fixtures/split_eval_summary.simulated.json"


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def wilson_lower(wins: int, total: int, z: float = 1.959963984540054) -> float:
    if total <= 0:
        return 0.0
    p = wins / total
    denom = 1 + (z**2 / total)
    center = p + (z**2 / (2 * total))
    margin = z * ((p * (1 - p) / total + z**2 / (4 * total**2)) ** 0.5)
    return (center - margin) / denom


def normal_cdf(x: float) -> float:
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def pvalue_one_sided_gt_half(wins: int, losses: int) -> float:
    total = wins + losses
    if total <= 0:
        return 1.0
    p0 = 0.5
    phat = wins / total
    sd = math.sqrt(max(1e-12, p0 * (1 - p0) / total))
    z = (phat - p0) / sd
    return float(max(0.0, min(1.0, 1.0 - normal_cdf(z))))


def holm_adjust(pvalues: dict[str, float]) -> dict[str, float]:
    ordered = sorted(pvalues.items(), key=lambda kv: kv[1])
    m = len(ordered)
    adjusted: dict[str, float] = {}
    running = 0.0
    for idx, (name, p) in enumerate(ordered):
        factor = m - idx
        candidate = min(1.0, p * factor)
        running = max(running, candidate)
        adjusted[name] = running
    return adjusted


def aggregate_from_phase_summaries(
    summaries: list[dict[str, Any]],
) -> tuple[str, dict[str, dict[str, float]], dict[str, int], list[str]]:
    baseline = "overlay_baseline"
    by_variant: dict[str, dict[str, float]] = {}
    by_family_counts: dict[str, int] = {}
    regimes: list[str] = []
    for summary in summaries:
        baseline = str(summary.get("baseline_variant") or baseline)
        regime = str(summary.get("inference_regime") or "").strip()
        if regime:
            regimes.append(regime)
        results = summary.get("results") or {}
        if isinstance(results, dict):
            for variant, data in results.items():
                if not isinstance(data, dict):
                    continue
                if variant == baseline:
                    continue
                pair = data.get("pairwise_vs_baseline") or {}
                if not isinstance(pair, dict):
                    continue
                acc = by_variant.setdefault(
                    str(variant),
                    {"wins": 0.0, "losses": 0.0, "ties": 0.0, "non_tie_n": 0.0, "n": 0.0},
                )
                wins = float(pair.get("wins", 0) or 0)
                losses = float(pair.get("losses", 0) or 0)
                ties = float(pair.get("ties", 0) or 0)
                non_tie = float(pair.get("non_tie_n", 0) or 0)
                n = float(pair.get("n", 0) or 0)
                if non_tie <= 0:
                    non_tie = max(0.0, wins + losses)
                if n <= 0:
                    n = max(0.0, wins + losses + ties)
                acc["wins"] += wins
                acc["losses"] += losses
                acc["ties"] += ties
                acc["non_tie_n"] += non_tie
                acc["n"] += n

        family_results = summary.get("family_results") or {}
        if isinstance(family_results, dict):
            for family, details in family_results.items():
                if not isinstance(details, dict):
                    continue
                pair = details.get("best_pairwise_vs_baseline") or {}
                if not isinstance(pair, dict):
                    continue
                non_tie = int(pair.get("non_tie_n", 0) or 0)
                if non_tie <= 0:
                    non_tie = int((pair.get("wins", 0) or 0) + (pair.get("losses", 0) or 0))
                by_family_counts[str(family)] = by_family_counts.get(str(family), 0) + max(0, non_tie)
    return baseline, by_variant, by_family_counts, regimes


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Arm O lite outcome aggregation and sequential selection.")
    parser.add_argument("--repo", default=str(REPO))
    parser.add_argument("--phase-summaries", nargs="+", default=[str(DEFAULT_PHASE_SUMMARY)])
    parser.add_argument("--alpha", type=float, default=0.05)
    parser.add_argument("--effect-ci95-lower-min", type=float, default=0.50)
    parser.add_argument("--required-inference-regime", default="frequentist_holm_one_sided")
    parser.add_argument("--allow-missing-inference-regime", action="store_true")
    parser.add_argument("--exploration-quota", type=int, default=2)
    parser.add_argument("--exploration-share-min", type=float, default=0.25)
    parser.add_argument("--require-total-tasks-min", type=int, default=200)
    parser.add_argument("--require-per-family-min", type=int, default=20)
    parser.add_argument("--simulate-no-provider", action="store_true")
    parser.add_argument("--seed", type=int, default=20260305)
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    summary_paths = [pathlib.Path(path).resolve() if pathlib.Path(path).is_absolute() else (repo / path).resolve() for path in args.phase_summaries]
    summaries = [load_json(path) for path in summary_paths]

    baseline, by_variant, by_family_counts, regimes = aggregate_from_phase_summaries(summaries)
    if not by_variant:
        raise RuntimeError("no candidate pairwise_vs_baseline data found in provided summaries")

    candidates: list[dict[str, Any]] = []
    pvalues: dict[str, float] = {}
    total_tasks = 0
    for variant, stats in sorted(by_variant.items()):
        wins = int(stats["wins"])
        losses = int(stats["losses"])
        ties = int(stats["ties"])
        non_tie_n = int(stats["non_tie_n"])
        n = int(stats["n"])
        total_tasks += n
        if non_tie_n <= 0:
            non_tie_n = max(0, wins + losses)
        win_rate = (wins / non_tie_n) if non_tie_n else 0.0
        non_loss_rate = ((wins + ties) / n) if n else 0.0
        ci95_lower = wilson_lower(wins, non_tie_n)
        p = pvalue_one_sided_gt_half(wins, losses)
        pvalues[variant] = p
        candidates.append(
            {
                "variant": variant,
                "wins": wins,
                "losses": losses,
                "ties": ties,
                "n": n,
                "non_tie_n": non_tie_n,
                "win_rate": win_rate,
                "non_loss_rate": non_loss_rate,
                "win_rate_ci95_lower": ci95_lower,
                "pvalue_one_sided_gt_half": p,
            }
        )

    holm = holm_adjust(pvalues)
    for candidate in candidates:
        candidate["holm_adjusted_pvalue"] = holm[candidate["variant"]]
        candidate["passes_stat_sig"] = candidate["holm_adjusted_pvalue"] <= float(args.alpha)
        candidate["passes_effect"] = candidate["win_rate_ci95_lower"] >= float(args.effect_ci95_lower_min)
        candidate["outcome_score"] = (
            (0.60 * float(candidate["win_rate"]))
            + (0.25 * float(candidate["non_loss_rate"]))
            + (0.15 * float(candidate["win_rate_ci95_lower"]))
        )

    ranked = sorted(candidates, key=lambda row: (float(row["outcome_score"]), float(row["win_rate"])), reverse=True)
    survivors = [row for row in ranked if row["passes_stat_sig"] and row["passes_effect"]]
    rejected = [row for row in ranked if not (row["passes_stat_sig"] and row["passes_effect"])]

    exploration_quota = max(0, int(args.exploration_quota))
    rng = random.Random(int(args.seed))
    tail_ids = [row["variant"] for row in rejected]
    rng.shuffle(tail_ids)
    exploration_variants = tail_ids[:exploration_quota]
    selected_variants = [row["variant"] for row in survivors] + exploration_variants

    candidate_count = max(1, len(ranked))
    exploration_share = len(exploration_variants) / candidate_count
    required_regime = str(args.required_inference_regime).strip()
    unique_regimes = sorted(set(regimes))
    regime_ok = True
    if unique_regimes:
        regime_ok = (len(unique_regimes) == 1) and (unique_regimes[0] == required_regime)
    else:
        regime_ok = bool(args.allow_missing_inference_regime)

    checks = {
        "single_inference_regime": regime_ok,
        "sample_floor_total_tasks": int(total_tasks) >= int(args.require_total_tasks_min),
        "sample_floor_per_family": (
            True
            if int(args.require_per_family_min) <= 0
            else (
                bool(by_family_counts)
                and all(count >= int(args.require_per_family_min) for count in by_family_counts.values())
            )
        ),
        "exploration_quota_applied": len(exploration_variants) >= min(exploration_quota, len(rejected)),
        "exploration_share_floor": (
            True
            if len(rejected) == 0 or exploration_quota <= 0
            else exploration_share >= float(args.exploration_share_min)
        ),
        "survivor_nonempty": len(survivors) > 0,
    }
    ok = all(checks.values())
    reason_codes = [f"CHECK_FAILED:{name}" for name, passed in checks.items() if not passed]

    out_payload = {
        "ok": ok,
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "simulate_no_provider": bool(args.simulate_no_provider),
        "inference_regime": required_regime,
        "input_inference_regimes": unique_regimes,
        "baseline_variant": baseline,
        "phase_summaries": [str(path) for path in summary_paths],
        "alpha": float(args.alpha),
        "effect_ci95_lc_min": float(args.effect_ci95_lower_min),
        "checks": checks,
        "reason_codes": reason_codes,
        "metrics": {
            "total_tasks": int(total_tasks),
            "family_non_tie_counts": by_family_counts,
            "candidate_count": len(ranked),
            "survivor_count": len(survivors),
            "exploration_count": len(exploration_variants),
            "exploration_share": exploration_share,
            "median_win_rate": median([float(row["win_rate"]) for row in ranked]) if ranked else 0.0,
            "median_holm_adjusted_pvalue": median([float(row["holm_adjusted_pvalue"]) for row in ranked]) if ranked else 1.0,
        },
        "ranked_candidates": ranked,
        "survivor_variants": [row["variant"] for row in survivors],
        "exploration_variants": exploration_variants,
        "selected_variants": selected_variants,
    }

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = (
        pathlib.Path(args.out).resolve()
        if args.out
        else (repo / "bench/prompt_eval/reports" / f"armo_lite_{stamp}" / "summary.json")
    )
    write_json(out_path, out_payload)
    print(json.dumps({"ok": ok, "out": str(out_path), "summary": out_payload}, indent=2, ensure_ascii=False))
    return 0 if ok else 3


if __name__ == "__main__":
    raise SystemExit(main())
