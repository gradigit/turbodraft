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


def kill_promptpad(socket_path: pathlib.Path) -> None:
    subprocess.run(["pkill", "-f", "promptpad-app"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        socket_path.unlink(missing_ok=True)
    except Exception:
        pass
    time.sleep(0.10)


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
    mode = str(record.get("benchmarkMode") or "")

    if rc != 0:
        reasons.append(f"returnCode={rc}")
    if mode != "startup":
        reasons.append(f"unexpected_benchmarkMode={mode}")
    if numeric(record.get("ctrlGToPromptPadActiveMs")) is None:
        reasons.append("missing_ctrlGToPromptPadActiveMs")
    if numeric(record.get("ctrlGToEditorCommandReturnMs")) is None:
        reasons.append("missing_ctrlGToEditorCommandReturnMs")
    if numeric(record.get("ctrlGToTextFocusMs")) is None:
        reasons.append("missing_ctrlGToTextFocusMs")

    return (len(reasons) == 0, reasons)


def metric_values(records: List[Dict[str, Any]], key: str) -> List[float]:
    out: List[float] = []
    for r in records:
        x = numeric(r.get(key))
        if x is not None:
            out.append(x)
    return out


def summarize_mode(records_all: List[Dict[str, Any]], records_valid: List[Dict[str, Any]]) -> Dict[str, Any]:
    keys = [
        "ctrlGToPromptPadActiveMs",
        "ctrlGToEditorCommandReturnMs",
        "ctrlGToTextFocusMs",
        "phasePromptPadReadyMs",
    ]
    out: Dict[str, Any] = {
        "attempted_runs": len(records_all),
        "valid_runs": len(records_valid),
        "valid_rate": (len(records_valid) / len(records_all)) if records_all else None,
    }
    for key in keys:
        out[f"{key}_all"] = summarize(metric_values(records_all, key))
        out[f"{key}_valid"] = summarize(metric_values(records_valid, key))
    return out


def run_mode(
    mode: str,
    target_valid: int,
    max_attempts: int,
    timeout_s: float,
    harness_process_name: str,
    socket_path: pathlib.Path,
    log_path: pathlib.Path,
    offset: int,
    harness_proc: Optional[subprocess.Popen] = None,
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
        try:
            if mode == "cold":
                kill_promptpad(socket_path)

            trigger_ctrl_g(harness_process_name)
            rec, offset = wait_for_record(log_path, offset, timeout_s=timeout_s)
            rec["mode"] = mode
            rec["attempt"] = attempts
            active_ms = numeric(rec.get("ctrlGToPromptPadActiveMs"))
            ready_ms = numeric(rec.get("ctrlGToEditorCommandReturnMs"))
            if active_ms is not None and ready_ms is not None and ready_ms >= active_ms:
                rec["phasePromptPadReadyMs"] = ready_ms - active_ms

            ok, reasons = is_record_valid(rec)
            rec["valid"] = ok
            rec["invalidReasons"] = reasons
            if ok:
                valid.append(rec)
            else:
                invalid.append(rec)
        except Exception as ex:
            errors.append({"mode": mode, "attempt": attempts, "error": str(ex)})

    return ModeResult(attempts=attempts, target_valid=target_valid, valid=valid, invalid=invalid, errors=errors), offset


def main() -> int:
    ap = argparse.ArgumentParser(description="Editor startup trace benchmark (no automation typing/saving path).")
    ap.add_argument("--cold", type=int, default=10, help="Required count of valid cold runs")
    ap.add_argument("--warm", type=int, default=40, help="Required count of valid warm runs")
    ap.add_argument("--max-attempt-multiplier", type=int, default=3, help="Max attempts per mode = target_valid * multiplier")
    ap.add_argument("--min-valid-rate", type=float, default=0.98, help="Minimum valid/attempted rate required per mode")
    ap.add_argument("--timeout-s", type=float, default=8.0)
    ap.add_argument("--harness-process-name", default="promptpad-e2e-harness")
    ap.add_argument("--fixture", default="bench/fixtures/dictation_flush_mode.md")
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--socket-path", default=str(pathlib.Path.home() / "Library/Application Support/PromptPad/promptpad.sock"))
    args = ap.parse_args()

    repo = pathlib.Path(__file__).resolve().parents[1]
    promptpad_bin = repo / ".build/release/promptpad"
    harness_bin = repo / ".build/release/promptpad-e2e-harness"
    if not promptpad_bin.exists():
        raise SystemExit(f"missing binary: {promptpad_bin}")
    if not harness_bin.exists():
        raise SystemExit(f"missing binary: {harness_bin}")

    out_dir = pathlib.Path(args.out_dir) if args.out_dir else (repo / "tmp" / f"bench_editor_startup_{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}")
    out_dir.mkdir(parents=True, exist_ok=True)
    log_path = out_dir / "harness.jsonl"

    fixture_source = pathlib.Path(args.fixture)
    if not fixture_source.is_absolute():
        fixture_source = (repo / fixture_source).resolve()
    if not fixture_source.exists():
        raise SystemExit(f"fixture not found: {fixture_source}")

    fixture_path = out_dir / "startup-fixture.md"
    fixture_path.write_text(fixture_source.read_text(encoding="utf-8"), encoding="utf-8")

    env = os.environ.copy()
    env["PROMPTPAD_BIN"] = str(promptpad_bin)
    env["PROMPTPAD_E2E_FILE"] = str(fixture_path.resolve())
    env["PROMPTPAD_E2E_LOG"] = str(log_path.resolve())
    env["PROMPTPAD_E2E_MODE"] = "startup"

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
        mult = max(1, int(args.max_attempt_multiplier))

        cold_result, offset = run_mode(
            mode="cold",
            target_valid=max(0, args.cold),
            max_attempts=max(1, max(0, args.cold) * mult),
            timeout_s=float(args.timeout_s),
            harness_process_name=args.harness_process_name,
            socket_path=socket_path,
            log_path=log_path,
            offset=offset,
            harness_proc=harness_proc,
        )
        warm_result, offset = run_mode(
            mode="warm",
            target_valid=max(0, args.warm),
            max_attempts=max(1, max(0, args.warm) * mult),
            timeout_s=float(args.timeout_s),
            harness_process_name=args.harness_process_name,
            socket_path=socket_path,
            log_path=log_path,
            offset=offset,
            harness_proc=harness_proc,
        )

        cold_all = cold_result.valid + cold_result.invalid
        warm_all = warm_result.valid + warm_result.invalid
        cold_summary = summarize_mode(cold_all, cold_result.valid)
        warm_summary = summarize_mode(warm_all, warm_result.valid)

        gates = {
            "cold_valid_count_pass": len(cold_result.valid) >= cold_result.target_valid,
            "warm_valid_count_pass": len(warm_result.valid) >= warm_result.target_valid,
            "cold_valid_rate_pass": cold_summary.get("valid_rate") is not None and cold_summary["valid_rate"] >= float(args.min_valid_rate),
            "warm_valid_rate_pass": warm_summary.get("valid_rate") is not None and warm_summary["valid_rate"] >= float(args.min_valid_rate),
        }
        gates["all_pass"] = all(bool(v) for v in gates.values())

        report = {
            "timestamp": dt.datetime.utcnow().isoformat() + "Z",
            "suite": "editor_startup_trace",
            "targets": {
                "cold_valid_runs": args.cold,
                "warm_valid_runs": args.warm,
                "max_attempt_multiplier": mult,
                "min_valid_rate": args.min_valid_rate,
            },
            "records": {
                "cold_valid": cold_result.valid,
                "cold_invalid": cold_result.invalid,
                "warm_valid": warm_result.valid,
                "warm_invalid": warm_result.invalid,
            },
            "summary": {
                "cold": cold_summary,
                "warm": warm_summary,
            },
            "errors": cold_result.errors + warm_result.errors,
            "gates": gates,
            "statistics": {
                "percentile_method": "nearest_rank",
                "median_ci": "bootstrap_95",
                "bootstrap_rounds": 2000,
                "reporting": "startup metrics only, no typing/saving automation phase",
            },
        }

        out_json = out_dir / "report.json"
        out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")

        print(f"startup_report\t{out_json}")
        print(f"cold_ctrl_g_to_promptpad_active_p95_ms\t{cold_summary['ctrlGToPromptPadActiveMs_valid']['p95_ms']}")
        print(f"warm_ctrl_g_to_promptpad_active_p95_ms\t{warm_summary['ctrlGToPromptPadActiveMs_valid']['p95_ms']}")
        print(f"warm_ctrl_g_to_editor_ready_p95_ms\t{warm_summary['ctrlGToEditorCommandReturnMs_valid']['p95_ms']}")
        print(f"warm_promptpad_ready_phase_p95_ms\t{warm_summary['phasePromptPadReadyMs_valid']['p95_ms']}")
        print(f"cold_valid_rate\t{cold_summary['valid_rate']}")
        print(f"warm_valid_rate\t{warm_summary['valid_rate']}")
        print(f"gates_all_pass\t{gates['all_pass']}")
        return 0 if gates["all_pass"] else 2
    finally:
        harness_proc.terminate()
        try:
            harness_proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            harness_proc.kill()
        harness_log.close()
        harness_err.close()


if __name__ == "__main__":
    raise SystemExit(main())
