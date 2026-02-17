#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import subprocess
import sys
from typing import List


def run(cmd: List[str], *, cwd: pathlib.Path) -> int:
    p = subprocess.run(cmd, cwd=str(cwd))
    return int(p.returncode)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Editor-only benchmark suite (startup/open/save/reflect). No prompt-quality benchmarking."
    )
    ap.add_argument("--path", default="bench/fixtures/dictation_flush_mode.md")
    ap.add_argument("--warm", type=int, default=50)
    ap.add_argument("--cold", type=int, default=8)
    ap.add_argument("--baseline", default="bench/editor/baseline.json")
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--with-launch-matrix", action="store_true")
    ap.add_argument("--launch-matrix-warm", type=int, default=12)
    ap.add_argument("--launch-matrix-cold", type=int, default=4)
    args = ap.parse_args()

    repo = pathlib.Path(__file__).resolve().parents[1]
    out_dir = pathlib.Path(args.out_dir) if args.out_dir else (repo / "tmp" / f"bench_editor_{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}")
    out_dir.mkdir(parents=True, exist_ok=True)

    result_json = out_dir / "editor_metrics.json"
    print(f"[editor] running promptpad bench run -> {result_json}")
    rc = run(
        [
            str(repo / ".build/release/promptpad"),
            "bench",
            "run",
            "--path",
            str((repo / args.path).resolve()) if not os.path.isabs(args.path) else args.path,
            "--warm",
            str(args.warm),
            "--cold",
            str(args.cold),
            "--out",
            str(result_json),
        ],
        cwd=repo,
    )
    if rc != 0:
        print(f"[editor] bench run failed rc={rc}", file=sys.stderr)
        return rc

    print(f"[editor] checking thresholds against {args.baseline}")
    rc = run(
        [
            str(repo / ".build/release/promptpad"),
            "bench",
            "check",
            "--baseline",
            str((repo / args.baseline).resolve()) if not os.path.isabs(args.baseline) else args.baseline,
            "--results",
            str(result_json),
        ],
        cwd=repo,
    )
    if rc != 0:
        print(f"[editor] threshold check failed rc={rc}", file=sys.stderr)
        return rc

    if args.with_launch_matrix:
        print("[editor] running launch matrix")
        rc = run(
            [
                "python3",
                str(repo / "scripts/bench_launch_matrix.py"),
                "--warm",
                str(args.launch_matrix_warm),
                "--cold",
                str(args.launch_matrix_cold),
            ],
            cwd=repo,
        )
        if rc != 0:
            print(f"[editor] launch matrix failed rc={rc}", file=sys.stderr)
            return rc

    manifest = {
        "suite": "editor",
        "metrics_file": str(result_json),
        "baseline_file": str((repo / args.baseline).resolve()) if not os.path.isabs(args.baseline) else args.baseline,
        "warm": args.warm,
        "cold": args.cold,
        "launch_matrix": bool(args.with_launch_matrix),
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"[editor] ok -> {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
