#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import pathlib
import random
import statistics
import subprocess
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple


def percentile_nearest_rank(samples: List[float], p: float) -> Optional[float]:
    if not samples:
        return None
    xs = sorted(float(x) for x in samples)
    clamped = max(0.0, min(1.0, float(p)))
    if clamped <= 0.0:
        return xs[0]
    idx = max(0, min(len(xs) - 1, math.ceil(clamped * len(xs)) - 1))
    return xs[idx]


def bootstrap_ci_median(samples: List[float], rounds: int = 2000, seed: int = 17) -> Tuple[Optional[float], Optional[float]]:
    if len(samples) < 2:
        return (None, None)
    xs = [float(x) for x in samples]
    rng = random.Random(seed + len(xs))
    medians: List[float] = []
    for _ in range(max(100, rounds)):
        resampled = [xs[rng.randrange(len(xs))] for _ in range(len(xs))]
        medians.append(float(statistics.median(resampled)))
    medians.sort()
    lo = medians[int(math.floor(0.025 * len(medians)))]
    hi = medians[max(0, int(math.ceil(0.975 * len(medians)) - 1))]
    return (lo, hi)


def summarize(samples: List[float]) -> Dict[str, Any]:
    if not samples:
        return {
            "n": 0,
            "median_ms": None,
            "p95_ms": None,
            "min_ms": None,
            "max_ms": None,
            "mean_ms": None,
            "median_ci95_low_ms": None,
            "median_ci95_high_ms": None,
        }
    lo, hi = bootstrap_ci_median(samples)
    return {
        "n": len(samples),
        "median_ms": float(statistics.median(samples)),
        "p95_ms": percentile_nearest_rank(samples, 0.95),
        "min_ms": float(min(samples)),
        "max_ms": float(max(samples)),
        "mean_ms": float(statistics.mean(samples)),
        "median_ci95_low_ms": lo,
        "median_ci95_high_ms": hi,
    }


def run_osascript(script: str, timeout_s: float = 10.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["osascript"],
        input=script,
        text=True,
        capture_output=True,
        timeout=timeout_s,
    )


def apple_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("\"", "\\\"")


def trigger_ctrl_g(harness_process_name: str) -> None:
    script = f'''
tell application "System Events"
  if not (exists process "{apple_escape(harness_process_name)}") then error "Harness process not found: {apple_escape(harness_process_name)}"
  tell process "{apple_escape(harness_process_name)}"
    set frontmost to true
    keystroke "g" using control down
  end tell
end tell
'''
    cp = run_osascript(script, timeout_s=8.0)
    if cp.returncode != 0:
        raise RuntimeError(f"failed to send Ctrl+G to harness: {cp.stderr.strip()}")


def automate_turbodraft_edit(token: str, timeout_s: float = 10.0, autosave_settle_s: float = 0.20) -> None:
    safe_token = apple_escape(token)
    script = f'''
tell application "System Events"
  set found to false
  set targetProc to missing value
  set startedAt to (current date)
  repeat while ((current date) - startedAt) < {max(1.0, float(timeout_s))}
    if exists process "TurboDraft" then
      set targetProc to process "TurboDraft"
    else if exists process "turbodraft-app" then
      set targetProc to process "turbodraft-app"
    else if exists process "turbodraft-app.debug" then
      set targetProc to process "turbodraft-app.debug"
    else
      set targetProc to missing value
    end if
    if targetProc is not missing value then
      if frontmost of targetProc is true then
        set found to true
        exit repeat
      end if
    end if
    delay 0.01
  end repeat
  if found is false then error "TurboDraft did not become frontmost"
  delay 0.04
  -- Click near center to force text focus before typing.
  try
    tell targetProc
      if (count of windows) > 0 then
        set w to front window
        set {{px, py}} to position of w
        set {{sx, sy}} to size of w
        click at {{px + (sx div 2), py + (sy div 2)}}
      end if
    end tell
  end try
  delay 0.02
  keystroke "{safe_token}"
  delay {autosave_settle_s:.2f}
  keystroke "s" using command down
  delay 0.05
  keystroke "w" using command down
end tell
'''
    cp = run_osascript(script, timeout_s=timeout_s + 3.0)
    if cp.returncode != 0:
        raise RuntimeError(f"failed to automate TurboDraft edit/close: {cp.stderr.strip()}")


def kill_turbodraft(socket_path: pathlib.Path, bin_path: Optional[pathlib.Path] = None) -> None:
    if bin_path:
        # Targeted kill: match exact binary path to avoid killing unrelated processes.
        subprocess.run(["pkill", "-9", "-f", str(bin_path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        try:
            ps = subprocess.run(
                ["ps", "-axo", "pid=,command="],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
            )
            for line in ps.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                parts = line.split(None, 1)
                if len(parts) != 2:
                    continue
                pid_s, cmd = parts
                if "turbodraft-app" not in cmd:
                    continue
                try:
                    os.kill(int(pid_s), 15)
                except Exception:
                    pass
        except Exception:
            pass
    try:
        socket_path.unlink(missing_ok=True)
    except Exception:
        pass
    time.sleep(0.10)


def measure_applescript_overhead(process_name: str, n: int = 10) -> Dict[str, float]:
    """Measure bare AppleScript round-trip overhead for calibration."""
    script = f'''
tell application "System Events"
    get frontmost of process "{apple_escape(process_name)}"
end tell
'''
    samples: List[float] = []
    for _ in range(n):
        t0 = time.perf_counter()
        try:
            run_osascript(script, timeout_s=5.0)
        except Exception:
            continue
        samples.append((time.perf_counter() - t0) * 1000.0)
    if not samples:
        return {"median_ms": 0.0, "p95_ms": 0.0}
    return {
        "median_ms": float(statistics.median(samples)),
        "p95_ms": float(percentile_nearest_rank(samples, 0.95) or 0.0),
    }


def wait_for_record(log_path: pathlib.Path, offset: int, timeout_s: float) -> Tuple[Dict[str, Any], int]:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if log_path.exists():
            data = log_path.read_bytes()
            if len(data) > offset:
                tail = data[offset:]
                nl = tail.find(b"\n")
                if nl >= 0:
                    new_offset = offset + nl + 1
                    line = tail[:nl].decode("utf-8", errors="replace").strip()
                    if not line:
                        offset = new_offset
                        continue
                    try:
                        obj = json.loads(line)
                    except (json.JSONDecodeError, ValueError):
                        obj = {"_parse_error": True, "_raw": line[:200]}
                    return obj, new_offset
        time.sleep(0.02)
    raise TimeoutError(f"timed out waiting for harness record ({timeout_s}s)")


def numeric(v: Any) -> Optional[float]:
    if isinstance(v, bool) or v is None:
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


def metric_values(records: List[Dict[str, Any]], key: str) -> List[float]:
    out: List[float] = []
    for r in records:
        x = numeric(r.get(key))
        if x is not None:
            out.append(x)
    return out


def summarize_mode(records_all: List[Dict[str, Any]], records_valid: List[Dict[str, Any]]) -> Dict[str, Any]:
    metric_keys = [
        "ctrlGToTurboDraftActiveMs",
        "ctrlGToEditorWaitReturnMs",
        "ctrlGToHarnessReactivatedMs",
        "ctrlGToTextFocusMs",
        "phaseTurboDraftInteractionMs",
        "phaseReturnToHarnessMs",
        "phaseEndToEndRoundTripMs",
    ]
    out: Dict[str, Any] = {
        "attempted_runs": len(records_all),
        "valid_runs": len(records_valid),
        "valid_rate": (len(records_valid) / len(records_all)) if records_all else None,
    }
    for key in metric_keys:
        out[f"{key}_all"] = summarize(metric_values(records_all, key))
        out[f"{key}_valid"] = summarize(metric_values(records_valid, key))
    return out


@dataclass
class ModeResult:
    attempts: int
    target_valid: int
    valid: List[Dict[str, Any]]
    invalid: List[Dict[str, Any]]
    errors: List[Dict[str, Any]]


def is_record_valid(record: Dict[str, Any]) -> Tuple[bool, List[str]]:
    reasons: List[str] = []
    rc = int(record.get("returnCode") or 0)
    token_applied = bool(record.get("tokenApplied"))

    if rc != 0:
        reasons.append(f"returnCode={rc}")
    if not token_applied:
        reasons.append("token_not_applied")
    if numeric(record.get("ctrlGToTurboDraftActiveMs")) is None:
        reasons.append("missing_ctrlGToTurboDraftActiveMs")
    if numeric(record.get("ctrlGToTextFocusMs")) is None:
        reasons.append("missing_ctrlGToTextFocusMs")

    return (len(reasons) == 0, reasons)


def run_mode(
    mode: str,
    target_valid: int,
    max_attempts: int,
    timeout_s: float,
    harness_process_name: str,
    socket_path: pathlib.Path,
    log_path: pathlib.Path,
    fixture_path: pathlib.Path,
    offset: int,
    harness_proc: Optional[subprocess.Popen] = None,
    autosave_settle_s: float = 0.20,
    bin_path: Optional[pathlib.Path] = None,
) -> Tuple[ModeResult, int]:
    valid: List[Dict[str, Any]] = []
    invalid: List[Dict[str, Any]] = []
    errors: List[Dict[str, Any]] = []

    attempts = 0
    while attempts < max_attempts and len(valid) < target_valid:
        if harness_proc is not None and harness_proc.poll() is not None:
            errors.append({"mode": mode, "attempt": attempts + 1, "error": f"harness died (rc={harness_proc.returncode})"})
            break
        attempts += 1
        # Short token (6 chars) to minimize AppleScript keystroke overhead.
        token = f"{mode[0]}{attempts}{int(time.time()) % 10000:04d}"

        try:
            if mode == "cold":
                kill_turbodraft(socket_path, bin_path=bin_path)

            trigger_ctrl_g(harness_process_name)
            automate_turbodraft_edit(token, timeout_s=max(5.0, timeout_s - 2.0), autosave_settle_s=autosave_settle_s)
            rec, offset = wait_for_record(log_path, offset, timeout_s=timeout_s)
            rec["mode"] = mode
            rec["attempt"] = attempts
            rec["tokenExpected"] = token
            fixture_text = fixture_path.read_text(encoding="utf-8")
            rec["tokenApplied"] = token in fixture_text

            open_ms = numeric(rec.get("ctrlGToTurboDraftActiveMs"))
            wait_ms = numeric(rec.get("ctrlGToEditorWaitReturnMs"))
            back_ms = numeric(rec.get("ctrlGToHarnessReactivatedMs"))
            text_focus_ms = numeric(rec.get("ctrlGToTextFocusMs"))

            if open_ms is not None and wait_ms is not None and wait_ms >= open_ms:
                rec["phaseTurboDraftInteractionMs"] = wait_ms - open_ms
            if back_ms is not None and wait_ms is not None and back_ms >= wait_ms:
                rec["phaseReturnToHarnessMs"] = back_ms - wait_ms
            elif text_focus_ms is not None and wait_ms is not None and text_focus_ms >= wait_ms:
                rec["phaseReturnToHarnessMs"] = text_focus_ms - wait_ms
            if text_focus_ms is not None:
                rec["phaseEndToEndRoundTripMs"] = text_focus_ms

            ok, reasons = is_record_valid(rec)
            rec["valid"] = ok
            rec["invalidReasons"] = reasons
            if ok:
                valid.append(rec)
            else:
                invalid.append(rec)
        except Exception as ex:
            errors.append({"mode": mode, "attempt": attempts, "error": str(ex)})

    return (
        ModeResult(
            attempts=attempts,
            target_valid=target_valid,
            valid=valid,
            invalid=invalid,
            errors=errors,
        ),
        offset,
    )


def main() -> int:
    ap = argparse.ArgumentParser(description="True E2E UX benchmark: Ctrl+G -> TurboDraft edit -> save/close -> focus return.")
    ap.add_argument("--cold", type=int, default=10, help="Required count of valid cold runs")
    ap.add_argument("--warm", type=int, default=30, help="Required count of valid warm runs")
    ap.add_argument("--max-attempt-multiplier", type=int, default=4, help="Max attempts per mode = target_valid * multiplier")
    ap.add_argument("--min-valid-rate", type=float, default=0.95, help="Minimum valid/attempted rate required per mode")
    ap.add_argument("--timeout-s", type=float, default=20.0)
    ap.add_argument("--harness-process-name", default="turbodraft-e2e-harness")
    ap.add_argument("--fixture", default="bench/fixtures/dictation_flush_mode.md")
    ap.add_argument("--autosave-settle-s", type=float, default=0.20, help="Delay after typing before Cmd+S, must exceed autosave debounce")
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--socket-path", default=str(pathlib.Path.home() / "Library/Application Support/TurboDraft/turbodraft.sock"))
    args = ap.parse_args()

    repo = pathlib.Path(__file__).resolve().parents[1]
    turbodraft_bin = repo / ".build/release/turbodraft-bench"
    harness_bin = repo / ".build/release/turbodraft-e2e-harness"
    if not turbodraft_bin.exists():
        raise SystemExit(f"missing binary: {turbodraft_bin}")
    if not harness_bin.exists():
        raise SystemExit(f"missing binary: {harness_bin}")

    out_dir = pathlib.Path(args.out_dir) if args.out_dir else (repo / "tmp" / f"bench_editor_e2e_{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}")
    out_dir.mkdir(parents=True, exist_ok=True)
    log_path = out_dir / "harness.jsonl"

    fixture_source = pathlib.Path(args.fixture)
    if not fixture_source.is_absolute():
        fixture_source = (repo / fixture_source).resolve()
    if not fixture_source.exists():
        raise SystemExit(f"fixture not found: {fixture_source}")

    fixture_path = out_dir / "e2e-fixture.md"
    fixture_path.write_text(fixture_source.read_text(encoding="utf-8"), encoding="utf-8")

    env = os.environ.copy()
    env["TURBODRAFT_BIN"] = str(turbodraft_bin)
    env["TURBODRAFT_E2E_FILE"] = str(fixture_path.resolve())
    env["TURBODRAFT_E2E_LOG"] = str(log_path.resolve())

    harness_log = open(out_dir / "harness_stdout.log", "w")
    harness_err = open(out_dir / "harness_stderr.log", "w")
    harness_proc = subprocess.Popen(
        [str(harness_bin)],
        cwd=str(repo),
        env=env,
        stdout=harness_log,
        stderr=harness_err,
    )

    try:
        # Wait for harness readiness: poll for log file or process death, then settle.
        _startup_deadline = time.time() + 3.0
        while time.time() < _startup_deadline:
            if harness_proc.poll() is not None:
                raise SystemExit(f"harness exited immediately with rc={harness_proc.returncode}")
            if log_path.exists():
                break
            time.sleep(0.05)
        time.sleep(0.5)
        socket_path = pathlib.Path(args.socket_path).expanduser()
        offset = 0
        multiplier = max(1, int(args.max_attempt_multiplier))

        # Calibrate AppleScript overhead before benchmark runs.
        overhead = measure_applescript_overhead(args.harness_process_name, n=10)
        overhead_median_ms = overhead["median_ms"]
        print(f"applescript_overhead_median_ms\t{overhead_median_ms:.1f}")
        print(f"applescript_overhead_p95_ms\t{overhead['p95_ms']:.1f}")

        cold_result, offset = run_mode(
            mode="cold",
            target_valid=max(0, args.cold),
            max_attempts=max(1, max(0, args.cold) * multiplier),
            timeout_s=float(args.timeout_s),
            harness_process_name=args.harness_process_name,
            socket_path=socket_path,
            log_path=log_path,
            fixture_path=fixture_path,
            offset=offset,
            harness_proc=harness_proc,
            autosave_settle_s=float(args.autosave_settle_s),
            bin_path=harness_bin.parent / "turbodraft-app",
        )

        warm_result, offset = run_mode(
            mode="warm",
            target_valid=max(0, args.warm),
            max_attempts=max(1, max(0, args.warm) * multiplier),
            timeout_s=float(args.timeout_s),
            harness_process_name=args.harness_process_name,
            socket_path=socket_path,
            log_path=log_path,
            fixture_path=fixture_path,
            offset=offset,
            harness_proc=harness_proc,
            autosave_settle_s=float(args.autosave_settle_s),
            bin_path=harness_bin.parent / "turbodraft-app",
        )

        # Add adjusted interaction metric (subtracting AppleScript overhead).
        for rec in warm_result.valid + warm_result.invalid:
            interaction_ms = numeric(rec.get("phaseTurboDraftInteractionMs"))
            if interaction_ms is not None:
                rec["phaseTurboDraftInteractionMs_adjusted"] = max(0.0, interaction_ms - overhead_median_ms)

        cold_all = cold_result.valid + cold_result.invalid
        warm_all = warm_result.valid + warm_result.invalid
        summary_cold = summarize_mode(cold_all, cold_result.valid)
        summary_warm = summarize_mode(warm_all, warm_result.valid)

        gates = {
            "cold_valid_count_pass": len(cold_result.valid) >= cold_result.target_valid,
            "warm_valid_count_pass": len(warm_result.valid) >= warm_result.target_valid,
            "cold_valid_rate_pass": (
                summary_cold.get("valid_rate") is not None and summary_cold["valid_rate"] >= float(args.min_valid_rate)
            ),
            "warm_valid_rate_pass": (
                summary_warm.get("valid_rate") is not None and summary_warm["valid_rate"] >= float(args.min_valid_rate)
            ),
        }
        gates["all_pass"] = all(bool(v) for v in gates.values())

        report = {
            "timestamp": dt.datetime.utcnow().isoformat() + "Z",
            "suite": "editor_e2e_ux",
            "targets": {
                "cold_valid_runs": args.cold,
                "warm_valid_runs": args.warm,
                "max_attempt_multiplier": multiplier,
                "min_valid_rate": args.min_valid_rate,
            },
            "records": {
                "cold_valid": cold_result.valid,
                "cold_invalid": cold_result.invalid,
                "warm_valid": warm_result.valid,
                "warm_invalid": warm_result.invalid,
            },
            "summary": {
                "cold": summary_cold,
                "warm": summary_warm,
            },
            "errors": cold_result.errors + warm_result.errors,
            "gates": gates,
            "statistics": {
                "percentile_method": "nearest_rank",
                "median_ci": "bootstrap_95",
                "bootstrap_rounds": 2000,
                "reporting": "p95 is computed from valid runs only",
                "applescript_overhead_median_ms": overhead_median_ms,
                "applescript_overhead_p95_ms": overhead["p95_ms"],
                "adjusted_metrics_note": "phaseTurboDraftInteractionMs_adjusted subtracts AppleScript overhead (approximate)",
            },
        }

        out_json = out_dir / "report.json"
        out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")

        print(f"e2e_report\t{out_json}")
        cold_open = report["summary"]["cold"]["ctrlGToTurboDraftActiveMs_valid"]["p95_ms"]
        warm_open = report["summary"]["warm"]["ctrlGToTurboDraftActiveMs_valid"]["p95_ms"]
        warm_focus = report["summary"]["warm"]["ctrlGToTextFocusMs_valid"]["p95_ms"]
        print(f"cold_ctrl_g_to_turbodraft_active_p95_ms\t{cold_open}")
        print(f"warm_ctrl_g_to_turbodraft_active_p95_ms\t{warm_open}")
        print(f"warm_ctrl_g_to_text_focus_p95_ms\t{warm_focus}")
        warm_interaction = report["summary"]["warm"]["phaseTurboDraftInteractionMs_valid"]["p95_ms"]
        warm_return = report["summary"]["warm"]["phaseReturnToHarnessMs_valid"]["p95_ms"]
        print(f"warm_turbodraft_interaction_p95_ms\t{warm_interaction}")
        print(f"warm_return_to_harness_p95_ms\t{warm_return}")
        print(f"cold_valid_rate\t{report['summary']['cold']['valid_rate']}")
        print(f"warm_valid_rate\t{report['summary']['warm']['valid_rate']}")
        print(f"gates_all_pass\t{report['gates']['all_pass']}")

        return 0 if report["gates"]["all_pass"] else 2
    finally:
        harness_proc.terminate()
        try:
            harness_proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            harness_proc.kill()
        harness_log.close()
        harness_err.close()
        kill_turbodraft(socket_path, bin_path=harness_bin.parent / "turbodraft-app")


if __name__ == "__main__":
    raise SystemExit(main())
