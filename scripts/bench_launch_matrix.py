#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import pathlib
import statistics
import subprocess
import sys
import time
from typing import Callable, Optional

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
  sys.path.insert(0, str(SCRIPT_DIR))
from bench_stats import bootstrap_ci_median, percentile_nearest_rank


def now_ms() -> float:
  return time.perf_counter() * 1000.0


def run(cmd, *, cwd: pathlib.Path, env: Optional[dict], timeout_s: int):
  start = now_ms()
  try:
    p = subprocess.run(
      [str(c) for c in cmd],
      cwd=str(cwd),
      env=env,
      capture_output=True,
      text=True,
      timeout=timeout_s,
    )
    return {
      "cmd": [str(c) for c in cmd],
      "rc": p.returncode,
      "timeout": False,
      "elapsed_ms": now_ms() - start,
      "stdout": p.stdout,
      "stderr": p.stderr,
    }
  except subprocess.TimeoutExpired as exc:
    return {
      "cmd": [str(c) for c in cmd],
      "rc": 124,
      "timeout": True,
      "elapsed_ms": now_ms() - start,
      "stdout": (exc.stdout.decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")),
      "stderr": (exc.stderr.decode("utf-8", "replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")),
    }


def summarize(samples, errors):
  xs = sorted(samples)
  median_ci95_low_ms, median_ci95_high_ms = bootstrap_ci_median(xs)
  return {
    "n_ok": len(xs),
    "n_err": len(errors),
    "p50_ms": percentile_nearest_rank(xs, 0.50),
    "p95_ms": percentile_nearest_rank(xs, 0.95),
    "mean_ms": statistics.mean(xs) if xs else None,
    "median_ci95_low_ms": median_ci95_low_ms,
    "median_ci95_high_ms": median_ci95_high_ms,
    "samples_ms": xs,
    "errors": errors[:5],
  }


def kill_apps():
  subprocess.run(["pkill", "-f", "turbodraft-app"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
  time.sleep(0.12)


def remove_socket(path: str):
  try:
    pathlib.Path(path).unlink(missing_ok=True)
  except Exception:
    pass


def default_socket_path() -> str:
  return str(pathlib.Path.home() / "Library" / "Application Support" / "TurboDraft" / "turbodraft.sock")


def start_app(app_bin: pathlib.Path, *, cwd: pathlib.Path, env: Optional[dict], args):
  p = subprocess.Popen(
    [str(app_bin), *args],
    cwd=str(cwd),
    env=env,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
  )
  time.sleep(0.45)
  return p


def stop_app(p):
  if p is None:
    return
  if p.poll() is not None:
    return
  p.terminate()
  try:
    p.wait(timeout=2)
  except subprocess.TimeoutExpired:
    p.kill()
    try:
      p.wait(timeout=2)
    except subprocess.TimeoutExpired:
      pass


def sample_open(
  turbodraft_bin: pathlib.Path,
  fixture: pathlib.Path,
  *,
  cwd: pathlib.Path,
  env: Optional[dict],
  n: int,
  open_timeout_ms: int,
  cmd_timeout_s: int,
  before_each: Optional[Callable[[], None]] = None,
  after_each: Optional[Callable[[], None]] = None,
):
  cmd = [turbodraft_bin, "open", "--path", fixture, "--timeout-ms", str(open_timeout_ms)]
  samples = []
  errors = []
  for _ in range(n):
    if before_each:
      before_each()
    res = run(cmd, cwd=cwd, env=env, timeout_s=cmd_timeout_s)
    if res["rc"] == 0 and not res["timeout"]:
      samples.append(res["elapsed_ms"])
    else:
      errors.append({
        "rc": res["rc"],
        "timeout": res["timeout"],
        "stderr_tail": (res["stderr"] or "")[-400:],
      })
    if after_each:
      after_each()
  return summarize(samples, errors)


def run_bench(
  turbodraft_bin: pathlib.Path,
  fixture: pathlib.Path,
  *,
  cwd: pathlib.Path,
  env: Optional[dict],
  warm_n: int,
  cold_n: int,
  timeout_s: int,
  out_json: pathlib.Path,
  stdout_log: pathlib.Path,
  stderr_log: pathlib.Path,
):
  cmd = [
    turbodraft_bin,
    "bench",
    "run",
    "--path",
    fixture,
    "--warm",
    str(warm_n),
    "--cold",
    str(cold_n),
    "--out",
    out_json,
  ]
  res = run(cmd, cwd=cwd, env=env, timeout_s=timeout_s)
  stdout_log.write_text(res["stdout"], encoding="utf-8")
  stderr_log.write_text(res["stderr"], encoding="utf-8")
  metrics = None
  if out_json.exists():
    try:
      metrics = json.loads(out_json.read_text(encoding="utf-8"))
    except Exception:
      metrics = None
  return {
    "status": {
      "cmd": [str(c) for c in cmd],
      "rc": res["rc"],
      "timeout": res["timeout"],
      "elapsed_ms": res["elapsed_ms"],
    },
    "metrics": metrics,
    "out_file": str(out_json),
    "stdout_log": str(stdout_log),
    "stderr_log": str(stderr_log),
  }


def m(v):
  if v is None:
    return "NA"
  if isinstance(v, float):
    return f"{v:.2f}"
  return str(v)


def write_mode_config(path: pathlib.Path, socket_path: str):
  cfg = {
    "socketPath": socket_path,
    "autosaveDebounceMs": 50,
    "agent": {
      "enabled": True,
      "backend": "exec",
      "command": "codex",
      "model": "gpt-5.3-codex-spark",
      "timeoutMs": 60_000,
      "webSearch": "cached",
      "promptProfile": "large_opt",
      "reasoningEffort": "low",
      "reasoningSummary": "auto",
      "args": [],
    },
    "theme": "system",
    "editorMode": "reliable",
  }
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_text(json.dumps(cfg), encoding="utf-8")


def main():
  ap = argparse.ArgumentParser(description="Benchmark TurboDraft launch/lifecycle modes with strict cold/warm comparison.")
  ap.add_argument("--fixture", default="bench/fixtures/dictation_flush_mode.md")
  ap.add_argument("--warm", type=int, default=12)
  ap.add_argument("--cold", type=int, default=4)
  ap.add_argument("--bench-warm", type=int, default=6)
  ap.add_argument("--bench-cold", type=int, default=1)
  ap.add_argument("--open-timeout-ms", type=int, default=60_000)
  ap.add_argument("--cmd-timeout-s", type=int, default=12)
  ap.add_argument("--bench-timeout-s", type=int, default=240)
  ap.add_argument("--launchagent-label", default="com.turbodraft.app.bench")
  args = ap.parse_args()

  repo = pathlib.Path(__file__).resolve().parents[1]
  turbodraft_bin = repo / ".build/release/turbodraft"
  app_bin = repo / ".build/release/turbodraft-app"
  launch_script = repo / "scripts/turbodraft-launch-agent"
  fixture = repo / args.fixture

  stamp = dt.datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
  out_dir = repo / "docs/benchmarks/launch-matrix" / stamp
  logs_dir = out_dir / "logs"
  out_dir.mkdir(parents=True, exist_ok=True)
  logs_dir.mkdir(parents=True, exist_ok=True)

  uid = os.getuid()
  launch_env = os.environ.copy()
  launch_env["TURBODRAFT_LAUNCH_AGENT_LABEL"] = args.launchagent_label

  results = {
    "meta": {
      "timestamp": stamp,
      "fixture": str(fixture),
      "warm_n": args.warm,
      "cold_n": args.cold,
      "bench_warm_n": args.bench_warm,
      "bench_cold_n": args.bench_cold,
      "launchagent_label": args.launchagent_label,
    },
    "scenarios": {},
  }

  # Always start clean.
  kill_apps()
  run([launch_script, "uninstall"], cwd=repo, env=launch_env, timeout_s=30)

  try:
    print("scenario: no_launchagent", flush=True)
    s1 = {}
    kill_apps()
    p = start_app(app_bin, cwd=repo, env=None, args=["--start-hidden"])
    try:
      s1["warm_turbodraft_open"] = sample_open(
        turbodraft_bin,
        fixture,
        cwd=repo,
        env=None,
        n=args.warm,
        open_timeout_ms=args.open_timeout_ms,
        cmd_timeout_s=args.cmd_timeout_s,
      )
    finally:
      stop_app(p)
      kill_apps()

    s1["cold_turbodraft_open"] = sample_open(
      turbodraft_bin,
      fixture,
      cwd=repo,
      env=None,
      n=args.cold,
      open_timeout_ms=args.open_timeout_ms,
      cmd_timeout_s=args.cmd_timeout_s,
      before_each=lambda: (kill_apps(), remove_socket(default_socket_path())),
    )

    s1["bench"] = run_bench(
      turbodraft_bin,
      fixture,
      cwd=repo,
      env=None,
      warm_n=args.bench_warm,
      cold_n=args.bench_cold,
      timeout_s=args.bench_timeout_s,
      out_json=out_dir / "scenario1_no_launchagent.bench.json",
      stdout_log=logs_dir / "scenario1_no_launchagent.bench.stdout.log",
      stderr_log=logs_dir / "scenario1_no_launchagent.bench.stderr.log",
    )
    results["scenarios"]["no_launchagent"] = s1

    print("scenario: launchagent_resident", flush=True)
    s2 = {}
    kill_apps()
    s2["launchagent_install"] = run(
      [launch_script, "install", "--app", app_bin],
      cwd=repo,
      env=launch_env,
      timeout_s=30,
    )
    time.sleep(0.8)

    s2["warm_turbodraft_open"] = sample_open(
      turbodraft_bin,
      fixture,
      cwd=repo,
      env=None,
      n=args.warm,
      open_timeout_ms=args.open_timeout_ms,
      cmd_timeout_s=args.cmd_timeout_s,
    )

    def la_before_each():
      run(["launchctl", "kickstart", "-k", f"gui/{uid}/{args.launchagent_label}"], cwd=repo, env=None, timeout_s=30)
      time.sleep(0.35)

    s2["cold_turbodraft_open"] = sample_open(
      turbodraft_bin,
      fixture,
      cwd=repo,
      env=None,
      n=args.cold,
      open_timeout_ms=args.open_timeout_ms,
      cmd_timeout_s=args.cmd_timeout_s,
      before_each=la_before_each,
    )

    s2["bench"] = run_bench(
      turbodraft_bin,
      fixture,
      cwd=repo,
      env=None,
      warm_n=args.bench_warm,
      cold_n=args.bench_cold,
      timeout_s=args.bench_timeout_s,
      out_json=out_dir / "scenario2_launchagent.bench.json",
      stdout_log=logs_dir / "scenario2_launchagent.bench.stdout.log",
      stderr_log=logs_dir / "scenario2_launchagent.bench.stderr.log",
    )
    results["scenarios"]["launchagent_resident"] = s2

    print("scenario: lifecycle_compare", flush=True)
    s3 = {}
    tmp = pathlib.Path("/tmp/turbodraft-bench-lifecycle")
    stay_cfg = tmp / "stay" / "config.json"
    stay_socket = str(tmp / "stay" / "turbodraft.sock")
    term_cfg = tmp / "terminate" / "config.json"
    term_socket = str(tmp / "terminate" / "turbodraft.sock")
    write_mode_config(stay_cfg, stay_socket)
    write_mode_config(term_cfg, term_socket)

    env_stay = os.environ.copy()
    env_stay["TURBODRAFT_CONFIG"] = str(stay_cfg)
    env_term = os.environ.copy()
    env_term["TURBODRAFT_CONFIG"] = str(term_cfg)

    # Stay-resident variant
    kill_apps()
    p_stay = start_app(app_bin, cwd=repo, env=env_stay, args=["--start-hidden"])
    try:
      s3["stay_resident_warm_turbodraft_open"] = sample_open(
        turbodraft_bin,
        fixture,
        cwd=repo,
        env=env_stay,
        n=args.warm,
        open_timeout_ms=args.open_timeout_ms,
        cmd_timeout_s=args.cmd_timeout_s,
      )
    finally:
      stop_app(p_stay)
      kill_apps()

    s3["stay_resident_cold_turbodraft_open"] = sample_open(
      turbodraft_bin,
      fixture,
      cwd=repo,
      env=env_stay,
      n=args.cold,
      open_timeout_ms=args.open_timeout_ms,
      cmd_timeout_s=args.cmd_timeout_s,
      before_each=lambda: (kill_apps(), remove_socket(stay_socket)),
    )

    s3["stay_resident_bench"] = run_bench(
      turbodraft_bin,
      fixture,
      cwd=repo,
      env=env_stay,
      warm_n=args.bench_warm,
      cold_n=args.bench_cold,
      timeout_s=args.bench_timeout_s,
      out_json=out_dir / "scenario3_stay_resident.bench.json",
      stdout_log=logs_dir / "scenario3_stay_resident.bench.stdout.log",
      stderr_log=logs_dir / "scenario3_stay_resident.bench.stderr.log",
    )

    # Terminate-on-last-close variant.
    kill_apps()
    p_term = start_app(app_bin, cwd=repo, env=env_term, args=["--start-hidden", "--terminate-on-last-close"])
    try:
      s3["terminate_on_last_close_warm_turbodraft_open"] = sample_open(
        turbodraft_bin,
        fixture,
        cwd=repo,
        env=env_term,
        n=args.warm,
        open_timeout_ms=args.open_timeout_ms,
        cmd_timeout_s=args.cmd_timeout_s,
      )
    finally:
      stop_app(p_term)
      kill_apps()

    live_proc = []

    def term_before_each():
      kill_apps()
      live_proc.append(start_app(app_bin, cwd=repo, env=env_term, args=["--start-hidden", "--terminate-on-last-close"]))

    def term_after_each():
      if live_proc:
        stop_app(live_proc.pop())
      kill_apps()

    s3["terminate_on_last_close_cold_turbodraft_open"] = sample_open(
      turbodraft_bin,
      fixture,
      cwd=repo,
      env=env_term,
      n=args.cold,
      open_timeout_ms=args.open_timeout_ms,
      cmd_timeout_s=args.cmd_timeout_s,
      before_each=term_before_each,
      after_each=term_after_each,
    )

    # Warm-only built-in bench with terminate mode prestarted.
    p_term2 = start_app(app_bin, cwd=repo, env=env_term, args=["--start-hidden", "--terminate-on-last-close"])
    try:
      s3["terminate_on_last_close_bench_warm_only"] = run_bench(
        turbodraft_bin,
        fixture,
        cwd=repo,
        env=env_term,
        warm_n=args.bench_warm,
        cold_n=0,
        timeout_s=args.bench_timeout_s,
        out_json=out_dir / "scenario3_terminate_warm_only.bench.json",
        stdout_log=logs_dir / "scenario3_terminate_warm_only.bench.stdout.log",
        stderr_log=logs_dir / "scenario3_terminate_warm_only.bench.stderr.log",
      )
    finally:
      stop_app(p_term2)
      kill_apps()

    results["scenarios"]["lifecycle_compare"] = s3

  finally:
    run([launch_script, "uninstall"], cwd=repo, env=launch_env, timeout_s=30)
    kill_apps()

  # Persist artifacts.
  matrix_json = out_dir / "matrix.json"
  matrix_json.write_text(json.dumps(results, indent=2), encoding="utf-8")

  s1 = results["scenarios"].get("no_launchagent", {})
  s2 = results["scenarios"].get("launchagent_resident", {})
  s3 = results["scenarios"].get("lifecycle_compare", {})

  lines = []
  lines.append("# TurboDraft Launch/Lifecycle Benchmark Matrix")
  lines.append("")
  lines.append(f"- Timestamp: {stamp}")
  lines.append(f"- Fixture: {fixture}")
  lines.append(f"- warm_n: {args.warm}")
  lines.append(f"- cold_n: {args.cold}")
  lines.append("")
  lines.append("## Strict cold/warm comparison (`turbodraft open`)")
  lines.append("")
  lines.append("| Scenario | warm p50 (ms) | warm p95 (ms) | cold p50 (ms) | cold p95 (ms) | warm ok/err | cold ok/err |")
  lines.append("|---|---:|---:|---:|---:|---:|---:|")

  def row(name: str, source: dict, warm_key: str, cold_key: str):
    w = source.get(warm_key, {})
    c = source.get(cold_key, {})
    lines.append(
      f"| {name} | {m(w.get('p50_ms'))} | {m(w.get('p95_ms'))} | {m(c.get('p50_ms'))} | {m(c.get('p95_ms'))} | "
      f"{m(w.get('n_ok'))}/{m(w.get('n_err'))} | {m(c.get('n_ok'))}/{m(c.get('n_err'))} |"
    )

  row("No LaunchAgent", s1, "warm_turbodraft_open", "cold_turbodraft_open")
  row("LaunchAgent resident", s2, "warm_turbodraft_open", "cold_turbodraft_open")
  row("Lifecycle: stay-resident", s3, "stay_resident_warm_turbodraft_open", "stay_resident_cold_turbodraft_open")
  row("Lifecycle: terminate-on-last-close", s3, "terminate_on_last_close_warm_turbodraft_open", "terminate_on_last_close_cold_turbodraft_open")

  lines.append("")
  lines.append("## Built-in `turbodraft bench run` status")
  lines.append("")
  lines.append("| Scenario | rc | timeout | elapsed (ms) |")
  lines.append("|---|---:|---|---:|")

  def bench_row(name: str, value):
    status = (value or {}).get("status", {})
    lines.append(f"| {name} | {m(status.get('rc'))} | {m(status.get('timeout'))} | {m(status.get('elapsed_ms'))} |")

  bench_row("No LaunchAgent", s1.get("bench"))
  bench_row("LaunchAgent resident", s2.get("bench"))
  bench_row("Lifecycle: stay-resident", s3.get("stay_resident_bench"))
  bench_row("Lifecycle: terminate-on-last-close (warm-only)", s3.get("terminate_on_last_close_bench_warm_only"))

  lines.append("")
  lines.append("## Raw artifacts")
  lines.append("")
  lines.append(f"- matrix.json: {matrix_json}")
  lines.append(f"- logs/: {logs_dir}")
  lines.append("")
  lines.append("## Notes")
  lines.append("")
  lines.append("- LaunchAgent benchmark uses isolated label from --launchagent-label.")
  lines.append("- Lifecycle terminate-vs-stay uses dedicated TURBODRAFT_CONFIG paths under /tmp.")
  lines.append("- Terminate-mode built-in bench is warm-only because cold bench spawns without terminate flag.")

  report_md = out_dir / "REPORT.md"
  report_md.write_text("\n".join(lines) + "\n", encoding="utf-8")

  print(out_dir)
  print(report_md)
  print(matrix_json)


if __name__ == "__main__":
  main()
