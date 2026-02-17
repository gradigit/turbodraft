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
        description="Prompt-quality benchmark suite (agent output latency/quality/pairwise). No editor latency benchmarking."
    )
    ap.add_argument("--drafts-file", default="bench/fixtures/profiles/profile_set.txt")
    ap.add_argument("--preamble-variants", default="core=bench/preambles/core.md,large_opt=bench/preambles/large-optimized-v1.md,extended=bench/preambles/extended.md")
    ap.add_argument("--web-search-modes", default="disabled,cached")
    ap.add_argument("--models", default="gpt-5.3-codex-spark")
    ap.add_argument("--efforts", default="low")
    ap.add_argument("--backend", default="both", choices=["both", "exec", "app-server"])
    ap.add_argument("--summary", default="auto", choices=["auto", "concise", "detailed", "none"])
    ap.add_argument("--quality-min", type=int, default=70)
    ap.add_argument("--n", type=int, default=7)
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--pairwise", dest="pairwise", action="store_true")
    ap.add_argument("--no-pairwise", dest="pairwise", action="store_false")
    ap.set_defaults(pairwise=True)
    ap.add_argument("--pairwise-model", default="gpt-5.3-codex")
    ap.add_argument("--pairwise-effort", default="xhigh")
    ap.add_argument("--pairwise-summary", default="auto", choices=["auto", "concise", "detailed", "none"])
    ap.add_argument("--pairwise-n", type=int, default=3)
    ap.add_argument("--pairwise-timeout", type=float, default=240.0)
    ap.add_argument("--pairwise-baseline-dir", default="bench/baselines/profiles")
    ap.add_argument("--baseline", default="bench/prompt/baseline.json")
    ap.add_argument("--out-dir", default="")
    args = ap.parse_args()

    repo = pathlib.Path(__file__).resolve().parents[1]
    out_dir = pathlib.Path(args.out_dir) if args.out_dir else (repo / "tmp" / f"bench_prompt_{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}")
    out_dir.mkdir(parents=True, exist_ok=True)

    matrix_cmd = [
        "python3",
        str(repo / "scripts/bench_prompt_engineer_matrix.py"),
        "--drafts-file",
        str((repo / args.drafts_file).resolve()) if not os.path.isabs(args.drafts_file) else args.drafts_file,
        "--preamble-variants",
        args.preamble_variants,
        "--web-search-modes",
        args.web_search_modes,
        "--models",
        args.models,
        "--efforts",
        args.efforts,
        "--summary",
        args.summary,
        "--backend",
        args.backend,
        "-n",
        str(args.n),
        "--timeout",
        str(args.timeout),
        "--quality-min",
        str(args.quality_min),
        "--pairwise-model",
        args.pairwise_model,
        "--pairwise-effort",
        args.pairwise_effort,
        "--pairwise-summary",
        args.pairwise_summary,
        "--pairwise-n",
        str(args.pairwise_n),
        "--pairwise-timeout",
        str(args.pairwise_timeout),
        "--pairwise-baseline-dir",
        str((repo / args.pairwise_baseline_dir).resolve()) if not os.path.isabs(args.pairwise_baseline_dir) else args.pairwise_baseline_dir,
        "--out-dir",
        str(out_dir),
    ]
    if args.pairwise:
        matrix_cmd.append("--pairwise")
    else:
        matrix_cmd.append("--no-pairwise")

    print("[prompt] running matrix suite")
    rc = run(matrix_cmd, cwd=repo)
    if rc != 0:
        print(f"[prompt] matrix run failed rc={rc}", file=sys.stderr)
        return rc

    summary_json = out_dir / "matrix_summary.json"
    check_cmd = [
        "python3",
        str(repo / "scripts/check_prompt_benchmark.py"),
        "--summary",
        str(summary_json),
        "--baseline",
        str((repo / args.baseline).resolve()) if not os.path.isabs(args.baseline) else args.baseline,
    ]
    print("[prompt] checking thresholds")
    rc = run(check_cmd, cwd=repo)
    if rc != 0:
        print(f"[prompt] threshold check failed rc={rc}", file=sys.stderr)
        return rc

    manifest = {
        "suite": "prompt",
        "summary_file": str(summary_json),
        "baseline_file": str((repo / args.baseline).resolve()) if not os.path.isabs(args.baseline) else args.baseline,
        "n": args.n,
        "backend": args.backend,
        "pairwise": args.pairwise,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"[prompt] ok -> {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
