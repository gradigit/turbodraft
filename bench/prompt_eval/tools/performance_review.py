#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
from typing import Any


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    ap = argparse.ArgumentParser(description="Cycle-level performance review for prompt eval")
    ap.add_argument("--reports-root", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    root = pathlib.Path(args.reports_root).resolve()
    cycle_summary = load_json(root / "cycle_summary.json")

    phase_timings: dict[str, float] = {}
    for phase in (cycle_summary.get("phase_results") or {}):
        timing_path = root / phase / "timing.json"
        if timing_path.exists():
            t = load_json(timing_path)
            phase_timings[phase] = float(t.get("elapsed_seconds", 0.0) or 0.0)

    total = sum(phase_timings.values())
    slow = sorted(phase_timings.items(), key=lambda x: x[1], reverse=True)[:3]

    recommendations: list[str] = []
    for phase, sec in slow:
        if sec > 240:
            recommendations.append(f"{phase}: high runtime ({sec:.1f}s), reduce max-cases for inner loop and run strict holdout only after pruning")
    if phase_timings.get("phaseB_judge_reliability", 0.0) > 300:
        recommendations.append("phaseB_judge_reliability: cache calibration outputs and run delta-only recalibration when judge prompt unchanged")
    if phase_timings.get("phaseD_dev", 0.0) + phase_timings.get("phaseE_adversarial", 0.0) > 240:
        recommendations.append("phaseD/phaseE: run candidate pre-pruning before pairwise judging to reduce expensive calls")

    if not recommendations:
        recommendations.append("No critical performance bottleneck detected")

    out = {
        "ok": True,
        "total_elapsed_seconds": round(total, 3),
        "phase_elapsed_seconds": phase_timings,
        "top_slowest_phases": [{"phase": p, "elapsed_seconds": s} for p, s in slow],
        "recommendations": recommendations,
    }

    out_path = pathlib.Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"ok": True, "out": str(out_path), "review": out}, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
