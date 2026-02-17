#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import pathlib
import sys
from typing import Any, Dict, List, Tuple


def as_float(v: Any) -> float | None:
    if v is None:
        return None
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        x = float(v)
        if math.isnan(x) or math.isinf(x):
            return None
        return x
    if isinstance(v, str):
        s = v.strip()
        if not s:
            return None
        try:
            x = float(s)
            if math.isnan(x) or math.isinf(x):
                return None
            return x
        except Exception:
            return None
    return None


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Validate prompt-quality benchmark summary against prompt baseline thresholds."
    )
    ap.add_argument("--summary", required=True, help="Path to matrix_summary.json")
    ap.add_argument("--baseline", default="bench/prompt/baseline.json", help="Path to prompt baseline threshold JSON")
    args = ap.parse_args()

    summary_path = pathlib.Path(args.summary)
    baseline_path = pathlib.Path(args.baseline)
    if not summary_path.is_file():
        raise SystemExit(f"summary file not found: {summary_path}")
    if not baseline_path.is_file():
        raise SystemExit(f"baseline file not found: {baseline_path}")

    summary_obj = json.loads(summary_path.read_text(encoding="utf-8"))
    base = json.loads(baseline_path.read_text(encoding="utf-8"))
    rows: List[Dict[str, Any]] = list(summary_obj.get("rows") or [])
    if not rows:
        raise SystemExit("matrix summary has no rows")

    checks: List[Tuple[str, str, float]] = [
        ("exec_quality_pass_rate", "min_exec_quality_pass_rate", float(base.get("min_exec_quality_pass_rate", 0.0))),
        ("exec_pairwise_win_rate", "min_exec_pairwise_win_rate", float(base.get("min_exec_pairwise_win_rate", 0.0))),
        ("app_quality_pass_rate", "min_app_quality_pass_rate", float(base.get("min_app_quality_pass_rate", 0.0))),
        ("app_pairwise_win_rate", "min_app_pairwise_win_rate", float(base.get("min_app_pairwise_win_rate", 0.0))),
    ]

    failures: List[str] = []
    for row in rows:
        run_id = str(row.get("run_id") or "unknown")
        for metric_key, baseline_key, threshold in checks:
            val = as_float(row.get(metric_key))
            if val is None:
                if threshold > 0:
                    failures.append(
                        f"{run_id}: {metric_key}=None (missing) vs {baseline_key}={threshold:.3f}"
                    )
                continue
            if val < threshold:
                failures.append(
                    f"{run_id}: {metric_key}={val:.3f} < {baseline_key}={threshold:.3f}"
                )

    if failures:
        print("prompt benchmark check failed:", file=sys.stderr)
        for line in failures:
            print(f"- {line}", file=sys.stderr)
        return 2

    print("prompt benchmark check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
