#!/usr/bin/env python3
"""Compare two benchmark result files and report statistical significance.

Usage:
    python3 scripts/bench_ab_compare.py --a tmp/baseline.json --b tmp/after_fix.json
    python3 scripts/bench_ab_compare.py --a tmp/baseline.json --b tmp/after_fix.json --threshold-pct 10 --out tmp/comparison.json
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def mann_whitney_u(a: List[float], b: List[float]) -> Tuple[float, float]:
    """Mann-Whitney U test with normal approximation.

    Returns (U statistic, two-sided p-value).
    Requires len(a) >= 3 and len(b) >= 3 for meaningful results.
    """
    n1, n2 = len(a), len(b)
    if n1 < 2 or n2 < 2:
        return (0.0, 1.0)

    combined = sorted([(v, i) for i, v in enumerate(a + b)])
    ranks: List[float] = [0.0] * (n1 + n2)

    i = 0
    while i < len(combined):
        j = i + 1
        while j < len(combined) and combined[j][0] == combined[i][0]:
            j += 1
        avg_rank = (i + 1 + j) / 2.0
        for k in range(i, j):
            ranks[combined[k][1]] = avg_rank
        i = j

    r1 = sum(ranks[i] for i in range(n1))
    u1 = r1 - n1 * (n1 + 1) / 2.0
    u2 = n1 * n2 - u1

    u = min(u1, u2)
    mu = n1 * n2 / 2.0
    sigma = math.sqrt(n1 * n2 * (n1 + n2 + 1) / 12.0)

    if sigma == 0:
        return (u, 1.0)

    z = abs(u - mu) / sigma
    # Two-sided p-value approximation using error function
    p = 2.0 * (1.0 - 0.5 * (1.0 + math.erf(z / math.sqrt(2.0))))
    return (u, p)


def compare_metric(
    key: str,
    samples_a: List[float],
    samples_b: List[float],
    threshold_pct: float,
) -> Dict[str, Any]:
    """Compare two sample sets for a single metric."""
    median_a = statistics.median(samples_a)
    median_b = statistics.median(samples_b)
    delta_pct = (median_b - median_a) / median_a * 100 if median_a != 0 else (
        0.0 if median_b == 0 else float("inf")
    )
    _, p_value = mann_whitney_u(samples_a, samples_b)
    significant = p_value < 0.05

    if significant and delta_pct > threshold_pct:
        verdict = "REGRESSION"
    elif significant and delta_pct < -threshold_pct:
        verdict = "IMPROVEMENT"
    else:
        verdict = "NO_CHANGE"

    return {
        "metric": key,
        "n_a": len(samples_a),
        "n_b": len(samples_b),
        "median_a": round(median_a, 3),
        "median_b": round(median_b, 3),
        "delta_pct": round(delta_pct, 2),
        "p_value": round(p_value, 4),
        "significant": significant,
        "verdict": verdict,
    }


def print_table(results: List[Dict[str, Any]]) -> None:
    """Print a formatted comparison table."""
    if not results:
        print("No comparable metrics found.")
        return

    header = f"{'Metric':<40} {'Med A':>8} {'Med B':>8} {'Delta%':>8} {'p-value':>8} {'Verdict':>12}"
    sep = "-" * len(header)
    print(sep)
    print(header)
    print(sep)
    for r in sorted(results, key=lambda x: x["metric"]):
        verdict = r["verdict"]
        print(
            f"{r['metric']:<40} {r['median_a']:>8.2f} {r['median_b']:>8.2f} "
            f"{r['delta_pct']:>+7.1f}% {r['p_value']:>8.4f} {verdict:>12}"
        )
    print(sep)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Compare two benchmark result JSON files for statistical significance."
    )
    ap.add_argument("--a", required=True, help="Baseline results JSON path")
    ap.add_argument("--b", required=True, help="Current results JSON path")
    ap.add_argument(
        "--threshold-pct",
        type=float,
        default=5.0,
        help="Minimum delta%% to classify as regression/improvement (default: 5.0)",
    )
    ap.add_argument("--out", help="Output JSON path for comparison results")
    args = ap.parse_args()

    path_a = Path(args.a)
    path_b = Path(args.b)
    if not path_a.exists():
        print(f"error: baseline file not found: {path_a}", file=sys.stderr)
        return 1
    if not path_b.exists():
        print(f"error: current file not found: {path_b}", file=sys.stderr)
        return 1

    a = json.loads(path_a.read_text())
    b = json.loads(path_b.read_text())

    raw_a = a.get("rawSamples", {})
    raw_b = b.get("rawSamples", {})

    if not raw_a:
        print("error: baseline JSON has no rawSamples — was it generated with the new bench format?", file=sys.stderr)
        return 1
    if not raw_b:
        print("error: current JSON has no rawSamples — was it generated with the new bench format?", file=sys.stderr)
        return 1

    common_keys = sorted(set(raw_a.keys()) & set(raw_b.keys()))
    if not common_keys:
        print("error: no common metrics found in rawSamples between the two files.", file=sys.stderr)
        return 1

    results: List[Dict[str, Any]] = []
    for key in common_keys:
        samples_a = [float(x) for x in raw_a[key] if x is not None]
        samples_b = [float(x) for x in raw_b[key] if x is not None]
        if len(samples_a) < 2 or len(samples_b) < 2:
            continue
        results.append(compare_metric(key, samples_a, samples_b, args.threshold_pct))

    print_table(results)

    regressions = [r for r in results if r["verdict"] == "REGRESSION"]
    improvements = [r for r in results if r["verdict"] == "IMPROVEMENT"]
    unchanged = [r for r in results if r["verdict"] == "NO_CHANGE"]

    print()
    print(f"Summary: {len(results)} metrics compared")
    print(f"  Regressions:  {len(regressions)}")
    print(f"  Improvements: {len(improvements)}")
    print(f"  No change:    {len(unchanged)}")

    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        report = {
            "baseline": str(path_a),
            "current": str(path_b),
            "threshold_pct": args.threshold_pct,
            "results": results,
            "summary": {
                "total": len(results),
                "regressions": len(regressions),
                "improvements": len(improvements),
                "no_change": len(unchanged),
            },
        }
        out_path.write_text(json.dumps(report, indent=2))
        print(f"\nResults written to: {out_path}")

    if regressions:
        print(f"\nFAILED: {len(regressions)} metric(s) regressed beyond {args.threshold_pct}% threshold.", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
