#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import statistics
import subprocess
import sys
import time
from datetime import datetime
from typing import Any, Dict, List, Tuple

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
from bench_stats import bootstrap_ci_median, percentile_nearest_rank


def parse_csv(s: str) -> List[str]:
    return [x.strip() for x in (s or "").split(",") if x.strip()]


def load_drafts(drafts_file: str, drafts_csv: str) -> List[str]:
    if drafts_csv.strip():
        return parse_csv(drafts_csv)
    if not os.path.isfile(drafts_file):
        raise SystemExit(f"drafts file not found: {drafts_file}")
    rows = [
        ln.strip()
        for ln in open(drafts_file, "r", encoding="utf-8", errors="replace").read().splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    ]
    if not rows:
        raise SystemExit(f"drafts file is empty: {drafts_file}")
    return rows


def parse_variants(spec: str) -> List[Tuple[str, str]]:
    out: List[Tuple[str, str]] = []
    for tok in parse_csv(spec):
        if "=" not in tok:
            raise SystemExit(f"invalid variant token (expected label=path): {tok}")
        label, path = tok.split("=", 1)
        label = label.strip()
        path = path.strip()
        if not label or not path:
            raise SystemExit(f"invalid variant token (blank label/path): {tok}")
        if not os.path.isfile(path):
            raise SystemExit(f"preamble file not found for variant '{label}': {path}")
        out.append((label, path))
    if not out:
        raise SystemExit("no preamble variants configured")
    return out


def summarize_results(obj: Dict[str, Any]) -> Dict[str, Any]:
    rows: List[Dict[str, Any]] = obj.get("results") or []
    backend_times: Dict[str, List[float]] = {"exec": [], "app_server_warm": []}
    quality: Dict[str, Dict[str, int]] = {
        "exec": {"pass": 0, "total": 0},
        "app_server_warm": {"pass": 0, "total": 0},
    }
    pairwise: Dict[str, Dict[str, int]] = {
        "exec": {"win": 0, "loss": 0, "tie": 0},
        "app_server_warm": {"win": 0, "loss": 0, "tie": 0},
    }

    for row in rows:
        for backend in ("exec", "app_server_warm"):
            bd = row.get(backend) or {}
            backend_times[backend].extend([float(x) for x in (bd.get("times_s") or [])])

            ev = bd.get("eval") or {}
            qp = ev.get("quality_pass") or {}
            quality[backend]["pass"] += int(qp.get("pass") or 0)
            quality[backend]["total"] += int(qp.get("total") or 0)

            pw = (ev.get("pairwise_result") or {}).get("sample") or []
            for x in pw:
                if x in pairwise[backend]:
                    pairwise[backend][x] += 1

    exec_times = backend_times["exec"]
    app_times = backend_times["app_server_warm"]
    exec_ci_low, exec_ci_high = bootstrap_ci_median(exec_times)
    app_ci_low, app_ci_high = bootstrap_ci_median(app_times)
    exec_pw_total = pairwise["exec"]["win"] + pairwise["exec"]["loss"] + pairwise["exec"]["tie"]
    app_pw_total = pairwise["app_server_warm"]["win"] + pairwise["app_server_warm"]["loss"] + pairwise["app_server_warm"]["tie"]
    return {
        "exec_runs": len(exec_times),
        "app_runs": len(app_times),
        "exec_median_s": statistics.median(exec_times) if exec_times else None,
        "exec_p95_s": percentile_nearest_rank(exec_times, 0.95) if exec_times else None,
        "exec_median_ci95_low_s": exec_ci_low,
        "exec_median_ci95_high_s": exec_ci_high,
        "app_median_s": statistics.median(app_times) if app_times else None,
        "app_p95_s": percentile_nearest_rank(app_times, 0.95) if app_times else None,
        "app_median_ci95_low_s": app_ci_low,
        "app_median_ci95_high_s": app_ci_high,
        "exec_quality_pass_rate": (quality["exec"]["pass"] / quality["exec"]["total"]) if quality["exec"]["total"] else None,
        "app_quality_pass_rate": (
            quality["app_server_warm"]["pass"] / quality["app_server_warm"]["total"]
        ) if quality["app_server_warm"]["total"] else None,
        "exec_pairwise_win": pairwise["exec"]["win"],
        "exec_pairwise_loss": pairwise["exec"]["loss"],
        "exec_pairwise_tie": pairwise["exec"]["tie"],
        "exec_pairwise_total": exec_pw_total,
        "exec_pairwise_win_rate": (pairwise["exec"]["win"] / exec_pw_total) if exec_pw_total else None,
        "app_pairwise_win": pairwise["app_server_warm"]["win"],
        "app_pairwise_loss": pairwise["app_server_warm"]["loss"],
        "app_pairwise_tie": pairwise["app_server_warm"]["tie"],
        "app_pairwise_total": app_pw_total,
        "app_pairwise_win_rate": (
            pairwise["app_server_warm"]["win"] / app_pw_total
        ) if app_pw_total else None,
    }


def fmt_num(x: Any, nd: int = 3) -> str:
    if x is None:
        return "-"
    if isinstance(x, (int, float)):
        if isinstance(x, float) and (math.isnan(x) or math.isinf(x)):
            return "-"
        return f"{x:.{nd}f}"
    return str(x)


def main() -> int:
    ap = argparse.ArgumentParser(description="Run matrix benchmark for TurboDraft prompt engineering (preamble x web_search).")
    ap.add_argument("--bench-script", default="scripts/bench_codex_prompt_engineer.py")
    ap.add_argument("--drafts-file", default="bench/fixtures/profiles/profile_set.txt")
    ap.add_argument("--drafts", default="", help="Optional comma-separated drafts override")
    ap.add_argument("--preamble-variants", default="core=bench/preambles/core.md,large_opt=bench/preambles/large-optimized-v1.md,extended=bench/preambles/extended.md")
    ap.add_argument("--web-search-modes", default="disabled,cached")
    ap.add_argument("--models", default="gpt-5.3-codex-spark")
    ap.add_argument("--efforts", default="low")
    ap.add_argument("--summary", default="auto", choices=["auto", "concise", "detailed", "none"])
    ap.add_argument("--backend", default="both", choices=["both", "exec", "app-server"])
    ap.add_argument("-n", type=int, default=7)
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--quality-min", type=int, default=70)
    ap.add_argument("--pairwise", dest="pairwise", action="store_true", help="Enable pairwise A/B evaluation")
    ap.add_argument("--no-pairwise", dest="pairwise", action="store_false", help="Disable pairwise A/B evaluation")
    ap.set_defaults(pairwise=True)
    ap.add_argument("--pairwise-model", default="gpt-5.3-codex")
    ap.add_argument("--pairwise-effort", default="xhigh")
    ap.add_argument("--pairwise-summary", default="auto", choices=["auto", "concise", "detailed", "none"])
    ap.add_argument("--pairwise-n", type=int, default=3)
    ap.add_argument("--pairwise-timeout", type=float, default=240.0)
    ap.add_argument("--pairwise-baseline-dir", default="bench/baselines/profiles")
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    drafts = load_drafts(args.drafts_file, args.drafts)
    variants = parse_variants(args.preamble_variants)
    web_modes = parse_csv(args.web_search_modes)
    if not web_modes:
        raise SystemExit("web-search-modes cannot be empty")

    bench_script = args.bench_script
    if not os.path.isfile(bench_script):
        raise SystemExit(f"bench script not found: {bench_script}")

    if not args.out_dir:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        args.out_dir = os.path.join("tmp", f"bench_matrix_{stamp}")
    os.makedirs(args.out_dir, exist_ok=True)

    drafts_csv = ",".join(drafts)
    matrix_rows: List[Dict[str, Any]] = []

    for variant_label, preamble_path in variants:
        for web_mode in web_modes:
            run_id = f"{variant_label}__web-{web_mode}"
            run_dir = os.path.join(args.out_dir, run_id)
            os.makedirs(run_dir, exist_ok=True)
            json_out = os.path.join(run_dir, "results.json")
            save_outputs = os.path.join(run_dir, "outputs")

            cmd = [
                "python3",
                bench_script,
                "--drafts",
                drafts_csv,
                "--system-preamble-file",
                preamble_path,
                "--backend",
                args.backend,
                "--models",
                args.models,
                "--efforts",
                args.efforts,
                "--summary",
                args.summary,
                "--web-search",
                web_mode,
                "-n",
                str(args.n),
                "--timeout",
                str(args.timeout),
                "--quality-min",
                str(args.quality_min),
                "--save-outputs",
                save_outputs,
                "--json-out",
                json_out,
            ]
            if args.pairwise:
                cmd.extend(
                    [
                        "--pairwise",
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
                        args.pairwise_baseline_dir,
                    ]
                )
            if args.verbose:
                cmd.append("--verbose")

            t0 = time.perf_counter()
            p = subprocess.run(cmd)
            dt = time.perf_counter() - t0
            if p.returncode != 0:
                raise SystemExit(f"matrix run failed ({run_id}) rc={p.returncode}")
            if not os.path.isfile(json_out):
                raise SystemExit(f"missing result json for run {run_id}: {json_out}")

            obj = json.load(open(json_out, "r", encoding="utf-8", errors="replace"))
            agg = summarize_results(obj)
            row: Dict[str, Any] = {
                "run_id": run_id,
                "variant": variant_label,
                "preamble_file": os.path.abspath(preamble_path),
                "web_search": web_mode,
                "wall_clock_s": dt,
                "results_json": os.path.abspath(json_out),
            }
            row.update(agg)
            matrix_rows.append(row)

    summary_json = os.path.join(args.out_dir, "matrix_summary.json")
    with open(summary_json, "w", encoding="utf-8") as f:
        json.dump({"rows": matrix_rows}, f, indent=2)

    summary_tsv = os.path.join(args.out_dir, "matrix_summary.tsv")
    headers = [
        "run_id",
        "variant",
        "web_search",
        "exec_median_s",
        "exec_p95_s",
        "exec_median_ci95_low_s",
        "exec_median_ci95_high_s",
        "app_median_s",
        "app_p95_s",
        "app_median_ci95_low_s",
        "app_median_ci95_high_s",
        "exec_quality_pass_rate",
        "app_quality_pass_rate",
        "exec_pairwise_win_rate",
        "app_pairwise_win_rate",
        "exec_pairwise_win",
        "exec_pairwise_loss",
        "exec_pairwise_tie",
        "app_pairwise_win",
        "app_pairwise_loss",
        "app_pairwise_tie",
        "wall_clock_s",
        "results_json",
    ]
    with open(summary_tsv, "w", encoding="utf-8") as f:
        f.write("\t".join(headers) + "\n")
        for r in matrix_rows:
            f.write(
                "\t".join(
                    [
                        str(r.get("run_id") or ""),
                        str(r.get("variant") or ""),
                        str(r.get("web_search") or ""),
                        fmt_num(r.get("exec_median_s")),
                        fmt_num(r.get("exec_p95_s")),
                        fmt_num(r.get("exec_median_ci95_low_s")),
                        fmt_num(r.get("exec_median_ci95_high_s")),
                        fmt_num(r.get("app_median_s")),
                        fmt_num(r.get("app_p95_s")),
                        fmt_num(r.get("app_median_ci95_low_s")),
                        fmt_num(r.get("app_median_ci95_high_s")),
                        fmt_num(r.get("exec_quality_pass_rate")),
                        fmt_num(r.get("app_quality_pass_rate")),
                        fmt_num(r.get("exec_pairwise_win_rate")),
                        fmt_num(r.get("app_pairwise_win_rate")),
                        str(r.get("exec_pairwise_win") or 0),
                        str(r.get("exec_pairwise_loss") or 0),
                        str(r.get("exec_pairwise_tie") or 0),
                        str(r.get("app_pairwise_win") or 0),
                        str(r.get("app_pairwise_loss") or 0),
                        str(r.get("app_pairwise_tie") or 0),
                        fmt_num(r.get("wall_clock_s")),
                        str(r.get("results_json") or ""),
                    ]
                )
                + "\n"
            )

    print(
        "run_id\tvariant\tweb_search\texec_median_s\texec_p95_s\tapp_median_s\tapp_p95_s\t"
        "exec_pairwise_win_rate\tapp_pairwise_win_rate\texec_quality_pass_rate\tapp_quality_pass_rate\twall_clock_s"
    )
    for r in matrix_rows:
        print(
            f"{r['run_id']}\t{r['variant']}\t{r['web_search']}\t"
            f"{fmt_num(r.get('exec_median_s'))}\t{fmt_num(r.get('exec_p95_s'))}\t"
            f"{fmt_num(r.get('app_median_s'))}\t{fmt_num(r.get('app_p95_s'))}\t"
            f"{fmt_num(r.get('exec_pairwise_win_rate'))}\t{fmt_num(r.get('app_pairwise_win_rate'))}\t"
            f"{fmt_num(r.get('exec_quality_pass_rate'))}\t{fmt_num(r.get('app_quality_pass_rate'))}\t"
            f"{fmt_num(r.get('wall_clock_s'))}"
        )

    print(f"\nsummary_json\t{summary_json}")
    print(f"summary_tsv\t{summary_tsv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
