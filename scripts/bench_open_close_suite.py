#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import pathlib
import platform
import random
import shlex
import socket
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

try:
    import Quartz  # type: ignore
except Exception:  # pragma: no cover - optional dependency
    Quartz = None


# ---------- stats ----------

def percentile_nearest_rank(samples: List[float], p: float) -> Optional[float]:
    if not samples:
        return None
    xs = sorted(float(x) for x in samples)
    clamped = max(0.0, min(1.0, float(p)))
    if clamped <= 0.0:
        return xs[0]
    idx = max(0, min(len(xs) - 1, math.ceil(clamped * len(xs)) - 1))
    return xs[idx]


def bootstrap_ci_median(samples: List[float], rounds: int = 1500, seed: int = 17) -> Tuple[Optional[float], Optional[float]]:
    if len(samples) < 2:
        return (None, None)
    xs = [float(x) for x in samples]
    rng = random.Random(seed + len(xs))
    meds: List[float] = []
    for _ in range(max(100, rounds)):
        rs = [xs[rng.randrange(len(xs))] for _ in range(len(xs))]
        meds.append(float(statistics.median(rs)))
    meds.sort()
    lo = meds[int(math.floor(0.025 * len(meds)))]
    hi = meds[max(0, int(math.ceil(0.975 * len(meds)) - 1))]
    return (lo, hi)


def summarize(samples: List[float]) -> Dict[str, Any]:
    if not samples:
        return {
            "n": 0,
            "min_ms": None,
            "median_ms": None,
            "p95_ms": None,
            "max_ms": None,
            "mean_ms": None,
            "median_ci95_low_ms": None,
            "median_ci95_high_ms": None,
        }
    lo, hi = bootstrap_ci_median(samples)
    return {
        "n": len(samples),
        "min_ms": float(min(samples)),
        "median_ms": float(statistics.median(samples)),
        "p95_ms": percentile_nearest_rank(samples, 0.95),
        "max_ms": float(max(samples)),
        "mean_ms": float(statistics.mean(samples)),
        "median_ci95_low_ms": lo,
        "median_ci95_high_ms": hi,
    }


def detect_outliers_iqr(samples: List[Tuple[int, float]]) -> Dict[str, Any]:
    if len(samples) < 4:
        return {"method": "iqr_1.5", "low": None, "high": None, "cycles": []}
    vals = sorted(v for _, v in samples)
    q1 = percentile_nearest_rank(vals, 0.25)
    q3 = percentile_nearest_rank(vals, 0.75)
    if q1 is None or q3 is None:
        return {"method": "iqr_1.5", "low": None, "high": None, "cycles": []}
    iqr = q3 - q1
    low = q1 - 1.5 * iqr
    high = q3 + 1.5 * iqr
    out = [idx for idx, v in samples if v < low or v > high]
    return {"method": "iqr_1.5", "low": low, "high": high, "cycles": out}


# ---------- helpers ----------

def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


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
        except Exception:
            return None
        if math.isnan(x) or math.isinf(x):
            return None
        return x
    return None


def run_capture(cmd: List[str], timeout_s: float = 8.0) -> Tuple[int, str, str]:
    p = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout_s)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def shell_ok(cmd: str, timeout_s: float = 8.0) -> Tuple[bool, str]:
    try:
        p = subprocess.run(["/bin/zsh", "-lc", cmd], text=True, capture_output=True, timeout=timeout_s)
        text = (p.stdout + "\n" + p.stderr).strip()
        return (p.returncode == 0, text)
    except Exception as ex:
        return (False, str(ex))


def ensure_dir(path: pathlib.Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def apple_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


def run_osascript(script: str, timeout_s: float = 12.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["osascript"], input=script, text=True, capture_output=True, timeout=timeout_s)


# ---------- telemetry ----------

def wait_for_new_jsonl(
    path: pathlib.Path,
    offset: int,
    timeout_s: float,
    predicate,
) -> Tuple[Dict[str, Any], int]:
    deadline = time.time() + timeout_s
    cur = offset
    while time.time() < deadline:
        if path.exists():
            data = path.read_bytes()
            # File may be replaced/truncated by telemetry fallback writes; reset cursor.
            if len(data) < cur:
                cur = 0
            if len(data) > cur:
                tail = data[cur:]
                # consume line by line
                while True:
                    nl = tail.find(b"\n")
                    if nl < 0:
                        break
                    line = tail[:nl].decode("utf-8", errors="replace").strip()
                    cur += nl + 1
                    tail = tail[nl + 1:]
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    if predicate(obj):
                        return obj, cur
        time.sleep(0.02)
    raise TimeoutError(f"timed out waiting for telemetry record at {path}")


# ---------- RPC ----------

class JSONRPCSocketClient:
    def __init__(self, sock_path: pathlib.Path, timeout_s: float = 5.0):
        self.sock_path = sock_path
        self.timeout_s = timeout_s
        self.sock: Optional[socket.socket] = None

    def __enter__(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout_s)
        s.connect(str(self.sock_path))
        self.sock = s
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None

    def _send_obj(self, obj: Dict[str, Any]) -> None:
        assert self.sock is not None
        payload = json.dumps(obj, separators=(",", ":")).encode("utf-8")
        header = f"Content-Length: {len(payload)}\r\n\r\n".encode("ascii")
        self.sock.sendall(header + payload)

    def _recv_obj(self) -> Dict[str, Any]:
        assert self.sock is not None
        buf = b""
        deadline = time.time() + self.timeout_s
        while b"\r\n\r\n" not in buf:
            if time.time() > deadline:
                raise TimeoutError("timed out reading JSON-RPC headers")
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("socket closed while reading headers")
            buf += chunk
        head, rest = buf.split(b"\r\n\r\n", 1)
        length = None
        for line in head.decode("ascii", errors="replace").split("\r\n"):
            if line.lower().startswith("content-length:"):
                length = int(line.split(":", 1)[1].strip())
                break
        if length is None:
            raise ValueError("missing content-length header")
        while len(rest) < length:
            if time.time() > deadline:
                raise TimeoutError("timed out reading JSON-RPC payload")
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("socket closed while reading payload")
            rest += chunk
        payload = rest[:length]
        return json.loads(payload.decode("utf-8", errors="replace"))

    def request(self, req_id: int, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        req = {"jsonrpc": "2.0", "id": req_id, "method": method}
        if params is not None:
            req["params"] = params
        self._send_obj(req)
        resp = self._recv_obj()
        if "error" in resp and resp["error"] is not None:
            raise RuntimeError(f"rpc error for {method}: {resp['error']}")
        return resp


def send_app_quit(sock_path: pathlib.Path, timeout_s: float) -> float:
    t0 = time.perf_counter()
    with JSONRPCSocketClient(sock_path, timeout_s=timeout_s) as cli:
        _ = cli.request(9001, "turbodraft.app.quit", params={})
    return (time.perf_counter() - t0) * 1000.0


def send_session_close(sock_path: pathlib.Path, session_id: str, timeout_s: float) -> float:
    t0 = time.perf_counter()
    with JSONRPCSocketClient(sock_path, timeout_s=timeout_s) as cli:
        _ = cli.request(9002, "turbodraft.session.close", params={"sessionId": session_id})
    return (time.perf_counter() - t0) * 1000.0


# ---------- cleanup / preconditions ----------

def kill_turbodraft(socket_path: pathlib.Path, app_bin: pathlib.Path) -> None:
    subprocess.run(["pkill", "-9", "-f", str(app_bin)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Fallbacks for LaunchAgent/symlinked executables where argv may not include
    # the resolved build path.
    subprocess.run(["pkill", "-9", "-x", "turbodraft-app"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["pkill", "-9", "-x", "turbodraft-app.debug"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        socket_path.unlink(missing_ok=True)
    except Exception:
        pass
    time.sleep(0.08)


def preconditions(repo: pathlib.Path, turbodraft_bin: pathlib.Path, app_bin: pathlib.Path) -> Dict[str, Any]:
    problems: List[str] = []
    if not turbodraft_bin.exists():
        problems.append(f"missing binary: {turbodraft_bin}")
    if not app_bin.exists():
        problems.append(f"missing binary: {app_bin}")

    ok_status, status_out = shell_ok(f"cd {shlex.quote(str(repo))} && scripts/turbodraft-launch-agent status", timeout_s=10.0)

    if problems:
        raise SystemExit("precondition failed: " + "; ".join(problems))

    return {
        "launchAgentStatus": status_out,
        "launchAgentStatusOk": ok_status,
    }


# ---------- optional UI probe ----------

@dataclass
class UIProbeCycle:
    ok: bool
    close_command_to_disappear_ms: Optional[float]
    open_visible_ms: Optional[float]
    error: Optional[str]


def trigger_ctrl_g(harness_process_name: str) -> None:
    script = f'''
tell application "System Events"
  if not (exists process "{apple_escape(harness_process_name)}") then error "Harness process not found"
  tell process "{apple_escape(harness_process_name)}"
    set frontmost to true
    keystroke "g" using control down
  end tell
end tell
'''
    cp = run_osascript(script, timeout_s=8.0)
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip() or "failed to send Ctrl+G")


def automate_close_and_measure(
    token: str,
    open_timeout_s: float,
    close_timeout_s: float,
    autosave_settle_s: float,
) -> float:
    safe = apple_escape(token)
    script = f'''
tell application "System Events"
  set targetProc to missing value
  set startedAt to (current date)
  repeat while ((current date) - startedAt) < {max(1.0, float(open_timeout_s))}
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
        exit repeat
      end if
    end if
    delay 0.01
  end repeat
  if targetProc is missing value then error "TurboDraft process not found"

  delay 0.04
  keystroke "{safe}"
  delay {autosave_settle_s:.2f}
  keystroke "s" using command down
  delay 0.03
  set closeIssuedAt to (current date)
  keystroke "w" using command down
  return "ok"
end tell
'''
    cp = run_osascript(script, timeout_s=open_timeout_s + close_timeout_s + 5.0)
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip() or cp.stdout.strip() or "automation failed")
    t0 = time.perf_counter()
    deadline = t0 + max(1.0, float(close_timeout_s))
    while time.perf_counter() < deadline:
        if not is_turbodraft_window_open():
            return (time.perf_counter() - t0) * 1000.0
        time.sleep(0.002)
    raise RuntimeError("close_disappear_timeout")


def is_turbodraft_window_open() -> bool:
    if Quartz is not None:
        try:
            infos = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) or []
            for w in infos:
                owner = str(w.get("kCGWindowOwnerName", ""))
                if owner not in ("TurboDraft", "turbodraft-app", "turbodraft-app.debug"):
                    continue
                # User-visible top-level windows are layer 0.
                if int(w.get("kCGWindowLayer", 0)) == 0:
                    return True
            return False
        except Exception:
            # Fall through to osascript-based probe below.
            pass

    script = '''
tell application "System Events"
  set hasWindow to false
  if exists process "TurboDraft" then
    try
      tell process "TurboDraft"
        if (count of windows) > 0 then set hasWindow to true
      end tell
    end try
  end if
  if hasWindow is false and (exists process "turbodraft-app") then
    try
      tell process "turbodraft-app"
        if (count of windows) > 0 then set hasWindow to true
      end tell
    end try
  end if
  if hasWindow is false and (exists process "turbodraft-app.debug") then
    try
      tell process "turbodraft-app.debug"
        if (count of windows) > 0 then set hasWindow to true
      end tell
    end try
  end if
  if hasWindow then
    return "1"
  else
    return "0"
  end if
end tell
'''
    cp = run_osascript(script, timeout_s=4.0)
    if cp.returncode != 0:
        return False
    return cp.stdout.strip() == "1"


def wait_for_harness_record(log_path: pathlib.Path, offset: int, timeout_s: float) -> Tuple[Dict[str, Any], int]:
    deadline = time.time() + timeout_s
    cur = offset
    while time.time() < deadline:
        if log_path.exists():
            data = log_path.read_bytes()
            if len(data) > cur:
                tail = data[cur:]
                nl = tail.find(b"\n")
                if nl >= 0:
                    cur = cur + nl + 1
                    line = tail[:nl].decode("utf-8", errors="replace").strip()
                    if line:
                        try:
                            return json.loads(line), cur
                        except Exception:
                            return {"_parse_error": True, "_raw": line[:200]}, cur
        time.sleep(0.02)
    raise TimeoutError("timed out waiting for harness record")


# ---------- cycles ----------

@dataclass
class CycleAttemptResult:
    success: bool
    recoverable: bool
    reason: str
    cycle: Dict[str, Any]


def run_api_cycle_attempt(
    cycle_idx: int,
    attempt_idx: int,
    fixture_path: pathlib.Path,
    turbodraft_bin: pathlib.Path,
    socket_path: pathlib.Path,
    telemetry_path: pathlib.Path,
    open_timeout_s: float,
    close_timeout_s: float,
) -> CycleAttemptResult:
    cycle: Dict[str, Any] = {
        "cycle": cycle_idx,
        "attempt": attempt_idx,
        "startedAt": now_iso(),
        "probe": "api",
        "timestamps": {},
        "validation": {"ordering_ok": True, "ordering_errors": []},
    }
    telemetry_offset = telemetry_path.stat().st_size if telemetry_path.exists() else 0

    cmd = [str(turbodraft_bin), "open", "--path", str(fixture_path), "--wait", "--timeout-ms", str(int(max(1000, (open_timeout_s + close_timeout_s) * 1000)))]
    t_trigger = time.perf_counter()
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    cycle["timestamps"]["trigger_ns"] = time.perf_counter_ns()

    try:
        open_evt, telemetry_offset = wait_for_new_jsonl(
            telemetry_path,
            telemetry_offset,
            timeout_s=open_timeout_s,
            predicate=lambda o: o.get("event") == "cli_open",
        )
        cycle["openTelemetry"] = open_evt
        cycle["timestamps"]["open_event_received_ns"] = time.perf_counter_ns()

        # Close trigger via RPC session.close when possible (keeps app resident).
        # Fallback to app.quit for backward compatibility if session id telemetry
        # is unavailable.
        close_trigger_ns = time.perf_counter_ns()
        session_id = open_evt.get("sessionId")
        if isinstance(session_id, str) and session_id:
            close_rpc_ms = send_session_close(socket_path, session_id=session_id, timeout_s=max(1.0, close_timeout_s))
            cycle["closeMethod"] = "sessionClose"
        else:
            close_rpc_ms = send_app_quit(socket_path, timeout_s=max(1.0, close_timeout_s))
            cycle["closeMethod"] = "appQuit"
        cycle["timestamps"]["close_trigger_ns"] = close_trigger_ns
        cycle["closeRpcRoundtripMs"] = close_rpc_ms

        # Primary close metric: close trigger -> open command process exit.
        proc.wait(timeout=max(1.0, close_timeout_s))
        cycle["timestamps"]["proc_exit_ns"] = time.perf_counter_ns()

        wait_evt, telemetry_offset = wait_for_new_jsonl(
            telemetry_path,
            telemetry_offset,
            timeout_s=close_timeout_s,
            predicate=lambda o: o.get("event") == "cli_wait",
        )
        cycle["waitTelemetry"] = wait_evt
        cycle["timestamps"]["wait_event_received_ns"] = time.perf_counter_ns()

        stderr = (proc.stderr.read() if proc.stderr else "").strip()
        cycle["returnCode"] = int(proc.returncode)
        if stderr:
            cycle["stderrTail"] = stderr[-400:]

        t_done = time.perf_counter()
        cycle["apiOpenTotalMs"] = numeric(open_evt.get("totalMs"))
        cycle["apiOpenConnectMs"] = numeric(open_evt.get("connectMs"))
        cycle["apiOpenRpcMs"] = numeric(open_evt.get("rpcOpenMs"))
        cycle["apiCloseWaitMs"] = numeric(wait_evt.get("waitMs"))
        cycle["apiCloseTriggerToWaitEventMs"] = (
            float(cycle["timestamps"]["wait_event_received_ns"] - close_trigger_ns) / 1_000_000.0
        )
        cycle["apiCloseTriggerToExitMs"] = (
            float(cycle["timestamps"]["proc_exit_ns"] - close_trigger_ns) / 1_000_000.0
        )
        cycle["apiCloseWaitObservationLagMs"] = (
            cycle["apiCloseTriggerToWaitEventMs"] - cycle["apiCloseTriggerToExitMs"]
        )
        cycle["apiCycleWallMs"] = (t_done - t_trigger) * 1000.0

        # Ordering validation
        ord_errs: List[str] = []
        ts = cycle["timestamps"]
        if ts["trigger_ns"] > ts["open_event_received_ns"]:
            ord_errs.append("trigger_after_open_event")
        if ts["open_event_received_ns"] > ts["close_trigger_ns"]:
            ord_errs.append("open_event_after_close_trigger")
        if ts["close_trigger_ns"] > ts["proc_exit_ns"]:
            ord_errs.append("close_trigger_after_proc_exit")
        if ts["proc_exit_ns"] > ts["wait_event_received_ns"]:
            ord_errs.append("proc_exit_after_wait_event")
        if ts["close_trigger_ns"] > ts["wait_event_received_ns"]:
            ord_errs.append("close_trigger_after_wait_event")
        cycle["validation"]["ordering_errors"] = ord_errs
        cycle["validation"]["ordering_ok"] = len(ord_errs) == 0

        if proc.returncode != 0:
            return CycleAttemptResult(False, True, f"open command exited {proc.returncode}", cycle)
        if cycle["apiOpenTotalMs"] is None or cycle["apiCloseTriggerToExitMs"] is None:
            return CycleAttemptResult(False, True, "missing_primary_metrics", cycle)
        if not cycle["validation"]["ordering_ok"]:
            return CycleAttemptResult(False, True, "timestamp_ordering_invalid", cycle)

        cycle["ok"] = True
        return CycleAttemptResult(True, True, "ok", cycle)

    except TimeoutError as ex:
        try:
            proc.terminate()
            proc.wait(timeout=1.0)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        cycle["error"] = str(ex)
        cycle["ok"] = False
        return CycleAttemptResult(False, True, "timeout", cycle)
    except Exception as ex:
        try:
            proc.terminate()
            proc.wait(timeout=1.0)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        cycle["error"] = str(ex)
        cycle["ok"] = False
        return CycleAttemptResult(False, True, "exception", cycle)


def collect_ui_probe_cycle(
    cycle_idx: int,
    attempt_idx: int,
    harness_process_name: str,
    harness_log_path: pathlib.Path,
    harness_offset: int,
    open_timeout_s: float,
    close_timeout_s: float,
    autosave_settle_s: float,
    record_timeout_s: float,
) -> Tuple[UIProbeCycle, int]:
    try:
        token = f"ui{cycle_idx:03d}a{attempt_idx}"
        trigger_ctrl_g(harness_process_name)
        close_ms = automate_close_and_measure(
            token=token,
            open_timeout_s=open_timeout_s,
            close_timeout_s=close_timeout_s,
            autosave_settle_s=autosave_settle_s,
        )
        rec, harness_offset = wait_for_harness_record(harness_log_path, harness_offset, timeout_s=record_timeout_s)
        open_visible = numeric(rec.get("ctrlGToTurboDraftActiveMs"))
        return UIProbeCycle(True, close_ms, open_visible, None), harness_offset
    except Exception as ex:
        return UIProbeCycle(False, None, None, str(ex)), harness_offset


# ---------- reporting ----------

def metric_samples(cycles: List[Dict[str, Any]], key: str) -> List[float]:
    out: List[float] = []
    for c in cycles:
        x = numeric(c.get(key))
        if x is not None:
            out.append(x)
    return out


def metric_samples_with_cycle(cycles: List[Dict[str, Any]], key: str) -> List[Tuple[int, float]]:
    out: List[Tuple[int, float]] = []
    for c in cycles:
        x = numeric(c.get(key))
        if x is not None:
            out.append((int(c.get("cycle", 0)), x))
    return out


def print_table(title: str, stats: Dict[str, Any]) -> None:
    print(f"\n{title}")
    print("  n    min    median    p95    max")
    if not stats or stats.get("n", 0) == 0:
        print("  0    -      -         -      -")
        return
    print(
        "  {n:<4} {minv:<6} {med:<8} {p95:<6} {maxv:<6}".format(
            n=stats.get("n", 0),
            minv=f"{stats.get('min_ms', 0):.1f}",
            med=f"{stats.get('median_ms', 0):.1f}",
            p95=f"{stats.get('p95_ms', 0):.1f}",
            maxv=f"{stats.get('max_ms', 0):.1f}",
        )
    )


def build_metadata(repo: pathlib.Path, args: argparse.Namespace, binaries: Dict[str, pathlib.Path], precheck: Dict[str, Any]) -> Dict[str, Any]:
    model_ok, model = shell_ok("sysctl -n hw.model", timeout_s=4.0)
    sw_ok, sw_out = shell_ok("sw_vers", timeout_s=4.0)
    git_ok, git_rev = shell_ok(f"cd {shlex.quote(str(repo))} && git rev-parse --short HEAD", timeout_s=4.0)
    app_hash_ok, app_hash = shell_ok(f"shasum -a 256 {shlex.quote(str(binaries['app']))} | awk '{{print $1}}'", timeout_s=4.0)

    out = {
        "timestamp": now_iso(),
        "hostname": platform.node(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "platform": platform.platform(),
        "hwModel": model if model_ok else None,
        "osVersion": sw_out if sw_ok else None,
        "gitRevision": git_rev if git_ok else None,
        "appBinary": str(binaries["app"]),
        "benchBinary": str(binaries["bench"]),
        "appBinarySha256": app_hash if app_hash_ok else None,
        "args": vars(args),
        "environment": {
            "TURBODRAFT_SOCKET": os.environ.get("TURBODRAFT_SOCKET"),
            "TURBODRAFT_CONFIG": os.environ.get("TURBODRAFT_CONFIG"),
            "CI": os.environ.get("CI"),
        },
        "precheck": precheck,
    }
    if "harness" in binaries:
        out["harnessBinary"] = str(binaries["harness"])
    return out


def compare_with_previous(current: Dict[str, Any], previous_path: Optional[pathlib.Path], keys: List[str]) -> Dict[str, Any]:
    if previous_path is None or not previous_path.exists():
        return {"available": False, "path": str(previous_path) if previous_path else None, "metrics": {}}
    try:
        prev = json.loads(previous_path.read_text(encoding="utf-8"))
    except Exception as ex:
        return {"available": False, "path": str(previous_path), "error": str(ex), "metrics": {}}

    out: Dict[str, Any] = {"available": True, "path": str(previous_path), "metrics": {}}
    cur_stats = current.get("summary", {}).get("steadyState", {})
    prev_stats = prev.get("summary", {}).get("steadyState", {})
    for k in keys:
        cm = numeric((cur_stats.get(k) or {}).get("median_ms"))
        pm = numeric((prev_stats.get(k) or {}).get("median_ms"))
        cp95 = numeric((cur_stats.get(k) or {}).get("p95_ms"))
        pp95 = numeric((prev_stats.get(k) or {}).get("p95_ms"))
        m: Dict[str, Any] = {
            "current_median_ms": cm,
            "previous_median_ms": pm,
            "current_p95_ms": cp95,
            "previous_p95_ms": pp95,
        }
        if cm is not None and pm not in (None, 0):
            m["median_delta_ms"] = cm - pm
            m["median_delta_pct"] = ((cm - pm) / pm) * 100.0
        if cp95 is not None and pp95 not in (None, 0):
            m["p95_delta_ms"] = cp95 - pp95
            m["p95_delta_pct"] = ((cp95 - pp95) / pp95) * 100.0
        out["metrics"][k] = m
    return out


# ---------- main ----------

def main() -> int:
    ap = argparse.ArgumentParser(description="TurboDraft production open/close benchmark suite (API primary)")
    ap.add_argument("--cycles", type=int, default=20)
    ap.add_argument("--warmup", type=int, default=1)
    ap.add_argument("--retries", type=int, default=2, help="Per-cycle retries for recoverable failures")
    ap.add_argument("--open-timeout-s", type=float, default=12.0)
    ap.add_argument("--close-timeout-s", type=float, default=10.0)
    ap.add_argument("--inter-cycle-delay-s", type=float, default=0.10)
    ap.add_argument("--clean-slate", action="store_true", default=False)
    ap.add_argument("--no-clean-slate", action="store_false", dest="clean_slate")
    ap.add_argument("--inject-transient-failure-cycle", type=int, default=0, help="For validation: force first attempt failure for this cycle")
    ap.add_argument("--fixture", default="bench/preambles/core.md")
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--compare", default="", help="Optional previous report JSON for trend deltas")
    args = ap.parse_args()

    if args.cycles <= 0:
        raise SystemExit("--cycles must be > 0")
    if args.warmup < 0 or args.warmup >= args.cycles:
        raise SystemExit("--warmup must be >=0 and < cycles")

    repo = pathlib.Path(__file__).resolve().parents[1]
    bench_bin = repo / ".build" / "release" / "turbodraft-bench"
    app_bin = repo / ".build" / "release" / "turbodraft-app"
    socket_path = pathlib.Path.home() / "Library" / "Application Support" / "TurboDraft" / "turbodraft.sock"
    telemetry_path = pathlib.Path.home() / "Library" / "Application Support" / "TurboDraft" / "telemetry" / "editor-open.jsonl"

    out_dir = pathlib.Path(args.out_dir) if args.out_dir else (repo / "tmp" / f"bench_open_close_{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}")
    ensure_dir(out_dir)

    fixture_src = pathlib.Path(args.fixture)
    if not fixture_src.is_absolute():
      fixture_src = (repo / fixture_src).resolve()
    if not fixture_src.exists():
      raise SystemExit(f"fixture not found: {fixture_src}")
    fixture = out_dir / "open-close-fixture.md"
    fixture.write_text(fixture_src.read_text(encoding="utf-8"), encoding="utf-8")

    precheck = preconditions(repo, bench_bin, app_bin)

    cycles: List[Dict[str, Any]] = []
    failures: List[Dict[str, Any]] = []
    transient_failure_injected = False
    transient_failure_recovered = False

    try:
        for idx in range(1, args.cycles + 1):
            warmup = idx <= args.warmup
            cycle_success = False
            final_cycle: Dict[str, Any] = {}

            for attempt in range(1, args.retries + 2):
                if (
                    args.inject_transient_failure_cycle > 0
                    and idx == args.inject_transient_failure_cycle
                    and attempt == 1
                    and not transient_failure_injected
                ):
                    transient_failure_injected = True
                    failures.append({
                        "cycle": idx,
                        "attempt": attempt,
                        "recoverable": True,
                        "reason": "injected_transient_failure",
                        "error": "synthetic transient failure for retry-path validation",
                    })
                    time.sleep(0.05)
                    continue

                if args.clean_slate:
                    kill_turbodraft(socket_path, app_bin)

                res = run_api_cycle_attempt(
                    cycle_idx=idx,
                    attempt_idx=attempt,
                    fixture_path=fixture,
                    turbodraft_bin=bench_bin,
                    socket_path=socket_path,
                    telemetry_path=telemetry_path,
                    open_timeout_s=float(args.open_timeout_s),
                    close_timeout_s=float(args.close_timeout_s),
                )
                final_cycle = res.cycle
                final_cycle["warmup"] = warmup
                final_cycle["uiProbe"] = None

                if res.success:
                    cycle_success = True
                    if transient_failure_injected and idx == args.inject_transient_failure_cycle and attempt > 1:
                        transient_failure_recovered = True
                    final_cycle["ok"] = True
                    cycles.append(final_cycle)
                    break

                failures.append({
                    "cycle": idx,
                    "attempt": attempt,
                    "recoverable": res.recoverable,
                    "reason": res.reason,
                    "error": final_cycle.get("error"),
                })

                if attempt <= args.retries:
                    time.sleep(0.10)

            if not cycle_success:
                final_cycle["ok"] = False
                final_cycle["warmup"] = warmup
                cycles.append(final_cycle)

            time.sleep(max(0.0, float(args.inter_cycle_delay_s)))
    finally:
        pass

    # validation & summaries
    successful = [c for c in cycles if c.get("ok")]
    steady = [c for c in successful if not c.get("warmup")]

    primary_keys = [
        "apiOpenTotalMs",
        "apiCloseTriggerToExitMs",
        "apiCycleWallMs",
        "apiOpenConnectMs",
        "apiOpenRpcMs",
        "closeRpcRoundtripMs",
        "apiCloseTriggerToWaitEventMs",
        "apiCloseWaitMs",
        "apiCloseWaitObservationLagMs",
    ]
    ui_keys = ["ui_open_visible_ms", "ui_close_cmd_to_disappear_ms"]

    # Flatten UI fields for summary convenience.
    for c in cycles:
        p = c.get("uiProbe") or {}
        c["ui_open_visible_ms"] = numeric(p.get("openVisibleMs"))
        c["ui_close_cmd_to_disappear_ms"] = numeric(p.get("closeCommandToDisappearMs"))

    summary_steady: Dict[str, Any] = {}
    summary_all: Dict[str, Any] = {}
    outliers: Dict[str, Any] = {}

    for key in primary_keys + ui_keys:
        s_all = metric_samples(cycles, key)
        s_steady = metric_samples(steady, key)
        summary_all[key] = summarize(s_all)
        summary_steady[key] = summarize(s_steady)
        outliers[key] = detect_outliers_iqr(metric_samples_with_cycle(steady, key))

    ordering_errors = [c for c in successful if not ((c.get("validation") or {}).get("ordering_ok", True))]

    primary_counts_ok = True
    for key in ["apiOpenTotalMs", "apiCloseTriggerToExitMs"]:
        cnt = len(metric_samples(steady, key))
        if cnt != len(steady):
            primary_counts_ok = False

    ui_attempted = len([c for c in cycles if c.get("uiProbe") is not None and not c.get("warmup")])
    ui_ok = len([c for c in cycles if not c.get("warmup") and (c.get("uiProbe") or {}).get("ok") is True])
    ui_coverage = (ui_ok / ui_attempted) if ui_attempted else None

    unrecovered_failures = len([c for c in cycles if not c.get("ok")])

    validation = {
        "timestamp_ordering_ok": len(ordering_errors) == 0,
        "primary_sample_count_ok": primary_counts_ok,
        "steady_state_cycle_count": len(steady),
        "successful_cycle_count": len(successful),
        "total_cycle_count": len(cycles),
        "unrecovered_failures": unrecovered_failures,
        "ui_probe_attempted": ui_attempted,
        "ui_probe_ok": ui_ok,
        "ui_probe_coverage": ui_coverage,
        "transient_failure_injected": transient_failure_injected,
        "transient_failure_recovered": transient_failure_recovered,
    }
    run_valid = (
        validation["timestamp_ordering_ok"]
        and validation["primary_sample_count_ok"]
        and validation["steady_state_cycle_count"] > 0
        and validation["unrecovered_failures"] == 0
    )

    report: Dict[str, Any] = {
        "schemaVersion": "1.0.0",
        "suite": "turbodraft_open_close",
        "metadata": build_metadata(
            repo,
            args,
            binaries={"bench": bench_bin, "app": app_bin},
            precheck=precheck,
        ),
        "config": {
            "cycles": args.cycles,
            "warmup": args.warmup,
            "retries": args.retries,
            "openTimeoutS": args.open_timeout_s,
            "closeTimeoutS": args.close_timeout_s,
            "interCycleDelayS": args.inter_cycle_delay_s,
            "cleanSlate": args.clean_slate,
            "fixture": str(fixture),
            "socketPath": str(socket_path),
            "telemetryPath": str(telemetry_path),
        },
        "cycles": cycles,
        "failures": failures,
        "summary": {
            "allCycles": summary_all,
            "steadyState": summary_steady,
            "outliers": outliers,
        },
        "validation": validation,
        "runValid": run_valid,
        "optionalProbeCoverage": {
            "userVisible": {
                "enabled": False,
                "attempted": ui_attempted,
                "ok": ui_ok,
                "coverage": ui_coverage,
            }
        },
        "method": {
            "primary": "API-level from CLI open --wait process + RPC session.close close trigger",
            "secondary": "use scripts/bench_open_close_real_cli.py for user-visible probe",
            "headlineExcludesWarmup": True,
            "outlierMethod": "iqr_1.5",
            "notes": [
                "visual settle analysis is optional and not a primary KPI",
                "API metrics are suitable for CI/nightly",
            ],
        },
    }

    compare_path = pathlib.Path(args.compare).expanduser() if args.compare else None
    report["trend"] = compare_with_previous(
        current=report,
        previous_path=compare_path,
        keys=["apiOpenTotalMs", "apiCloseTriggerToExitMs", "apiCycleWallMs"],
    )

    out_json = out_dir / "report.json"
    out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")

    raw_jsonl = out_dir / "cycles.jsonl"
    with raw_jsonl.open("w", encoding="utf-8") as fh:
        for c in cycles:
            fh.write(json.dumps(c) + "\n")

    # console summary
    print("open_close_report\t" + str(out_json))
    print("raw_cycles_jsonl\t" + str(raw_jsonl))
    print(f"run_valid\t{run_valid}")
    print(f"unrecovered_failures\t{validation['unrecovered_failures']}")
    print(f"steady_state_cycles\t{validation['steady_state_cycle_count']}")
    print(f"optional_user_visible_coverage\t{ui_coverage}")

    print_table("Primary API: open total (ms)", summary_steady.get("apiOpenTotalMs") or {})
    print_table("Primary API: close trigger->cli exit (ms)", summary_steady.get("apiCloseTriggerToExitMs") or {})
    print_table("Primary API: cycle wall (ms)", summary_steady.get("apiCycleWallMs") or {})
    print_table("Internal component: connect (ms)", summary_steady.get("apiOpenConnectMs") or {})
    print_table("Internal component: rpc open (ms)", summary_steady.get("apiOpenRpcMs") or {})
    print_table("Internal component: close rpc (ms)", summary_steady.get("closeRpcRoundtripMs") or {})
    print_table("Auxiliary: close trigger->wait event observed (ms)", summary_steady.get("apiCloseTriggerToWaitEventMs") or {})
    print_table("Auxiliary: cli_wait payload waitMs (ms)", summary_steady.get("apiCloseWaitMs") or {})
    print_table("Auxiliary: wait-event observation lag (ms)", summary_steady.get("apiCloseWaitObservationLagMs") or {})

    return 0 if run_valid else 2


if __name__ == "__main__":
    raise SystemExit(main())
