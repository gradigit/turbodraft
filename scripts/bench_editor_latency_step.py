#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import pathlib
import shlex
import statistics
import subprocess
import sys
import time

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
from bench_stats import bootstrap_ci_median, percentile_nearest_rank


def now_ts() -> str:
    return dt.datetime.now().strftime("%Y-%m-%dT%H-%M-%S")


def run_cmd(cmd, cwd: pathlib.Path, timeout_s: int):
    start = time.perf_counter()
    p = subprocess.run(
        cmd,
        cwd=str(cwd),
        capture_output=True,
        text=True,
        timeout=timeout_s,
    )
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    return p, elapsed_ms


def command_latency_ms(cmd, cwd: pathlib.Path, n: int, timeout_s: int):
    samples = []
    errors = []
    for _ in range(n):
        try:
            p, elapsed_ms = run_cmd(cmd, cwd=cwd, timeout_s=timeout_s)
            if p.returncode == 0:
                samples.append(elapsed_ms)
            else:
                errors.append(
                    {
                        "returncode": p.returncode,
                        "stderr_tail": p.stderr[-500:],
                        "stdout_tail": p.stdout[-500:],
                    }
                )
        except subprocess.TimeoutExpired as exc:
            errors.append({"timeout": True, "stderr_tail": (exc.stderr or "")[-500:]})
    samples.sort()
    median_ci95_low_ms, median_ci95_high_ms = bootstrap_ci_median(samples)
    return {
        "n_ok": len(samples),
        "n_err": len(errors),
        "p50_ms": percentile_nearest_rank(samples, 0.50),
        "p95_ms": percentile_nearest_rank(samples, 0.95),
        "mean_ms": statistics.mean(samples) if samples else None,
        "median_ci95_low_ms": median_ci95_low_ms,
        "median_ci95_high_ms": median_ci95_high_ms,
        "errors": errors[:5],
    }


def write_text(path: pathlib.Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def as_text(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def main():
    ap = argparse.ArgumentParser(description="Run one editor-latency benchmark step and write logs/reports.")
    ap.add_argument("--label", required=True, help="Step label, e.g. baseline, opt1-launchagent")
    ap.add_argument("--warm", type=int, default=25)
    ap.add_argument("--cold", type=int, default=5)
    ap.add_argument("--cmd-n", type=int, default=15, help="Repetitions for command-latency samples.")
    ap.add_argument("--timeout-s", type=int, default=180)
    ap.add_argument("--cmd-timeout-s", type=int, default=8)
    ap.add_argument(
        "--fixture",
        default="bench/fixtures/dictation_flush_mode.md",
        help="Path to benchmark prompt file.",
    )
    args = ap.parse_args()

    repo = pathlib.Path(__file__).resolve().parents[1]
    release_turbodraft = repo / ".build/release/turbodraft"
    release_app = repo / ".build/release/turbodraft-app"
    release_open = repo / ".build/release/turbodraft-open"
    fixture = repo / args.fixture

    stamp = now_ts()
    out_dir = repo / "docs/benchmarks/optimization-runs" / f"{stamp}-{args.label}"
    out_dir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env["EDITOR"] = str(repo / "scripts/turbodraft-editor")
    env["VISUAL"] = str(repo / "scripts/turbodraft-editor")

    meta = {
        "timestamp": stamp,
        "label": args.label,
        "fixture": str(fixture),
        "warm": args.warm,
        "cold": args.cold,
    }
    write_text(out_dir / "meta.json", json.dumps(meta, indent=2))

    # Ensure old app processes do not skew cold runs.
    subprocess.run(["pkill", "-f", "turbodraft-app"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    bench_out = out_dir / "turbodraft-bench.json"
    bench_cmd = [
        str(release_turbodraft),
        "bench",
        "run",
        "--path",
        str(fixture),
        "--warm",
        str(args.warm),
        "--cold",
        str(args.cold),
        "--out",
        str(bench_out),
    ]
    bench_status = {"command": bench_cmd}
    try:
        p, elapsed_ms = run_cmd(bench_cmd, cwd=repo, timeout_s=args.timeout_s)
        bench_status["elapsed_ms"] = elapsed_ms
        bench_status["returncode"] = p.returncode
        write_text(out_dir / "bench.stdout.log", p.stdout)
        write_text(out_dir / "bench.stderr.log", p.stderr)
    except subprocess.TimeoutExpired as exc:
        bench_status["timeout"] = True
        bench_status["returncode"] = 124
        write_text(out_dir / "bench.stdout.log", as_text(exc.stdout))
        write_text(out_dir / "bench.stderr.log", as_text(exc.stderr))

    # Command-level A/B-friendly startup timings.
    # Warm path: keep app running.
    app_proc = None
    warm_cmd = [str(release_turbodraft), "open", "--path", str(fixture), "--timeout-ms", "60000"]
    open_cmd = [str(release_open), "--path", str(fixture), "--timeout-ms", "60000"]
    try:
        app_proc = subprocess.Popen(
            [str(release_app)],
            cwd=str(repo),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(0.35)
        warm_turbodraft = command_latency_ms(warm_cmd, cwd=repo, n=args.cmd_n, timeout_s=args.cmd_timeout_s)
        warm_open = command_latency_ms(open_cmd, cwd=repo, n=args.cmd_n, timeout_s=args.cmd_timeout_s)
    finally:
        if app_proc and app_proc.poll() is None:
            app_proc.terminate()
            try:
                app_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                app_proc.kill()
        subprocess.run(["pkill", "-f", "turbodraft-app"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Cold path: kill app each run.
    cold_turbodraft_samples = []
    cold_turbodraft_err = 0
    cold_open_samples = []
    cold_open_err = 0
    for _ in range(max(1, args.cold)):
        subprocess.run(["pkill", "-f", "turbodraft-app"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            p, elapsed_ms = run_cmd(warm_cmd, cwd=repo, timeout_s=args.cmd_timeout_s)
            if p.returncode == 0:
                cold_turbodraft_samples.append(elapsed_ms)
            else:
                cold_turbodraft_err += 1
        except subprocess.TimeoutExpired:
            cold_turbodraft_err += 1
        subprocess.run(["pkill", "-f", "turbodraft-app"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            p2, elapsed_ms2 = run_cmd(open_cmd, cwd=repo, timeout_s=args.cmd_timeout_s)
            if p2.returncode == 0:
                cold_open_samples.append(elapsed_ms2)
            else:
                cold_open_err += 1
        except subprocess.TimeoutExpired:
            cold_open_err += 1

    cold_turbodraft_samples.sort()
    cold_open_samples.sort()
    cold_turbodraft_ci_low, cold_turbodraft_ci_high = bootstrap_ci_median(cold_turbodraft_samples)
    cold_open_ci_low, cold_open_ci_high = bootstrap_ci_median(cold_open_samples)
    cold_turbodraft = {
        "n_ok": len(cold_turbodraft_samples),
        "n_err": cold_turbodraft_err,
        "p50_ms": percentile_nearest_rank(cold_turbodraft_samples, 0.50),
        "p95_ms": percentile_nearest_rank(cold_turbodraft_samples, 0.95),
        "median_ci95_low_ms": cold_turbodraft_ci_low,
        "median_ci95_high_ms": cold_turbodraft_ci_high,
    }
    cold_open = {
        "n_ok": len(cold_open_samples),
        "n_err": cold_open_err,
        "p50_ms": percentile_nearest_rank(cold_open_samples, 0.50),
        "p95_ms": percentile_nearest_rank(cold_open_samples, 0.95),
        "median_ci95_low_ms": cold_open_ci_low,
        "median_ci95_high_ms": cold_open_ci_high,
    }

    bench_metrics = {}
    if bench_out.exists():
        try:
            bench_metrics = json.loads(bench_out.read_text(encoding="utf-8"))
        except Exception:
            bench_metrics = {}

    summary = {
        "meta": meta,
        "bench_status": bench_status,
        "bench_metrics": bench_metrics,
        "warm_turbodraft_open": warm_turbodraft,
        "warm_turbodraft_open_cshim": warm_open,
        "cold_turbodraft_open": cold_turbodraft,
        "cold_turbodraft_open_cshim": cold_open,
    }
    write_text(out_dir / "summary.json", json.dumps(summary, indent=2))

    md = []
    md.append(f"# TurboDraft Optimization Benchmark: {args.label}")
    md.append("")
    md.append(f"- Timestamp: {stamp}")
    md.append(f"- Fixture: {fixture}")
    md.append(f"- Bench command return code: {bench_status.get('returncode')}")
    md.append("")
    md.append("## Command latency (ms)")
    md.append("")
    md.append(f"- warm `turbodraft open` p50: {warm_turbodraft.get('p50_ms')}")
    md.append(f"- warm `turbodraft open` p95: {warm_turbodraft.get('p95_ms')}")
    md.append(f"- warm `turbodraft-open` p50: {warm_open.get('p50_ms')}")
    md.append(f"- warm `turbodraft-open` p95: {warm_open.get('p95_ms')}")
    md.append(f"- cold `turbodraft open` p50: {cold_turbodraft.get('p50_ms')}")
    md.append(f"- cold `turbodraft open` p95: {cold_turbodraft.get('p95_ms')}")
    md.append(f"- cold `turbodraft-open` p50: {cold_open.get('p50_ms')}")
    md.append(f"- cold `turbodraft-open` p95: {cold_open.get('p95_ms')}")
    md.append("")
    if isinstance(bench_metrics, dict) and bench_metrics.get("metrics"):
        md.append("## turbodraft bench run metrics")
        md.append("")
        for k, v in sorted(bench_metrics["metrics"].items()):
            md.append(f"- {k}: {v}")
        md.append("")
    write_text(out_dir / "summary.md", "\n".join(md) + "\n")

    print(str(out_dir))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
