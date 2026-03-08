#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
from typing import Any


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def safe_load(path: pathlib.Path) -> dict[str, Any] | None:
    if path.exists():
        return load_json(path)
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Self-review phase outcomes and propose repair plan")
    ap.add_argument("--report-dir", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    root = pathlib.Path(args.report_dir).resolve()
    gate = safe_load(root / "gate_report.json") or {}
    summary = safe_load(root / "summary.json") or {}
    timing = safe_load(root / "timing.json") or {}

    checks = gate.get("checks", {}) if isinstance(gate.get("checks"), dict) else {}
    failed_checks = [k for k, v in checks.items() if not v]

    perf_flags: list[str] = []
    elapsed = float(timing.get("elapsed_seconds", 0.0) or 0.0)
    if elapsed > 1800:
        perf_flags.append("RUN_TOO_SLOW")

    avg_det = None
    if isinstance(summary.get("results"), dict):
        vals = []
        for variant, info in summary["results"].items():
            if isinstance(info, dict) and "avg_deterministic_score" in info:
                vals.append(float(info["avg_deterministic_score"]))
        if vals:
            avg_det = sum(vals) / len(vals)
            if avg_det < 85:
                perf_flags.append("DETERMINISTIC_SCORE_LOW")

    recommendations: list[str] = []
    if failed_checks:
        recommendations.append("Run repair loop focused on failed checks, then rerun same phase from checkpoint")
    if "RUN_TOO_SLOW" in perf_flags:
        recommendations.append("Lower concurrency and prune low-value candidates to reduce runtime")
    if "DETERMINISTIC_SCORE_LOW" in perf_flags:
        recommendations.append("Tighten preset-specific instruction templates to improve structural compliance")
    if not recommendations:
        recommendations.append("Proceed to next phase")

    out = {
        "ok": True,
        "failed_checks": failed_checks,
        "performance_flags": perf_flags,
        "avg_deterministic_score": avg_det,
        "recommendations": recommendations,
    }

    out_path = pathlib.Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"ok": True, "out": str(out_path), "review": out}, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
