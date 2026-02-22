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


def summarize(samples: List[float]) -> Dict[str, Any]:
    if not samples:
        return {
            "n": 0,
            "min": None,
            "median": None,
            "p95": None,
            "max": None,
            "mean": None,
        }
    return {
        "n": len(samples),
        "min": float(min(samples)),
        "median": float(statistics.median(samples)),
        "p95": percentile_nearest_rank(samples, 0.95),
        "max": float(max(samples)),
        "mean": float(statistics.mean(samples)),
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


def linear_slope_per_cycle(samples: List[Tuple[int, float]]) -> Optional[float]:
    if len(samples) < 2:
        return None
    xs = [float(i) for i, _ in samples]
    ys = [float(v) for _, v in samples]
    mx = statistics.mean(xs)
    my = statistics.mean(ys)
    den = sum((x - mx) ** 2 for x in xs)
    if den <= 0:
        return None
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    return num / den


# ---------- helpers ----------

def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def to_mib(bytes_value: Optional[float]) -> Optional[float]:
    if bytes_value is None:
        return None
    return float(bytes_value) / (1024.0 * 1024.0)


def shell_ok(cmd: str, timeout_s: float = 8.0) -> Tuple[bool, str]:
    try:
        p = subprocess.run(["/bin/zsh", "-lc", cmd], text=True, capture_output=True, timeout=timeout_s)
        text = (p.stdout + "\n" + p.stderr).strip()
        return (p.returncode == 0, text)
    except Exception as ex:
        return (False, str(ex))


def ensure_dir(path: pathlib.Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def default_app_support_dir() -> pathlib.Path:
    return pathlib.Path.home() / "Library" / "Application Support" / "TurboDraft"


def resolve_socket_path() -> pathlib.Path:
    config_path = os.environ.get("TURBODRAFT_CONFIG")
    if config_path:
        p = pathlib.Path(config_path).expanduser()
    else:
        p = default_app_support_dir() / "config.json"

    try:
        if p.exists():
            obj = json.loads(p.read_text(encoding="utf-8"))
            sock = obj.get("socketPath")
            if isinstance(sock, str) and sock.strip():
                return pathlib.Path(sock).expanduser()
    except Exception:
        pass

    return default_app_support_dir() / "turbodraft.sock"


def wait_for_new_jsonl(path: pathlib.Path, offset: int, timeout_s: float, predicate) -> Tuple[Dict[str, Any], int]:
    deadline = time.time() + timeout_s
    cur = offset
    while time.time() < deadline:
        if path.exists():
            data = path.read_bytes()
            if len(data) < cur:
                cur = 0
            if len(data) > cur:
                tail = data[cur:]
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
        time.sleep(0.01)
    raise TimeoutError(f"timed out waiting for telemetry record at {path}")


def rss_bytes(pid: int) -> Optional[int]:
    if pid <= 0:
        return None
    try:
        cp = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], text=True, capture_output=True, timeout=1.5)
        if cp.returncode != 0:
            return None
        s = cp.stdout.strip()
        if not s:
            return None
        # ps rss is KiB
        kib = int(s.split()[0])
        return kib * 1024
    except Exception:
        return None


def collect_rss_samples(pid: int, duration_s: float, sample_ms: float) -> List[int]:
    out: List[int] = []
    deadline = time.time() + max(0.0, duration_s)
    interval = max(0.001, float(sample_ms) / 1000.0)
    while time.time() < deadline:
        v = rss_bytes(pid)
        if v is not None:
            out.append(v)
        time.sleep(interval)
    if not out:
        v = rss_bytes(pid)
        if v is not None:
            out.append(v)
    return out


def deterministic_payload(cycle_idx: int, step_idx: int, target_bytes: int) -> str:
    header = f"\n\n# ram-cycle-{cycle_idx}-step-{step_idx}\n"
    seed = f"payload-{cycle_idx:03d}-{step_idx:03d} "
    need = max(256, target_bytes - len(header.encode("utf-8")))
    repeats = math.ceil(need / len(seed.encode("utf-8")))
    body = (seed * repeats)[:need]
    return header + body


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


def rpc_hello(sock_path: pathlib.Path, timeout_s: float) -> Dict[str, Any]:
    with JSONRPCSocketClient(sock_path, timeout_s=timeout_s) as cli:
        return cli.request(1001, "turbodraft.hello", params={"client": "bench_ram_suite", "protocolVersion": 1}).get("result", {})


def rpc_save(sock_path: pathlib.Path, session_id: str, content: str, timeout_s: float) -> Dict[str, Any]:
    with JSONRPCSocketClient(sock_path, timeout_s=timeout_s) as cli:
        return cli.request(1101, "turbodraft.session.save", params={"sessionId": session_id, "content": content}).get("result", {})


def rpc_bench_metrics(sock_path: pathlib.Path, session_id: str, timeout_s: float) -> Dict[str, Any]:
    with JSONRPCSocketClient(sock_path, timeout_s=timeout_s) as cli:
        return cli.request(1201, "turbodraft.bench.metrics", params={"sessionId": session_id}).get("result", {})


def rpc_session_close(sock_path: pathlib.Path, session_id: str, timeout_s: float) -> float:
    t0 = time.perf_counter()
    with JSONRPCSocketClient(sock_path, timeout_s=timeout_s) as cli:
        _ = cli.request(1301, "turbodraft.session.close", params={"sessionId": session_id})
    return (time.perf_counter() - t0) * 1000.0


# ---------- cleanup/preconditions ----------

def kill_turbodraft(socket_path: pathlib.Path, app_bin: pathlib.Path) -> None:
    _ = shell_ok("pkill -9 -f turbodraft-app || true", timeout_s=3.0)
    _ = shell_ok(f"rm -f {shlex.quote(str(socket_path))}", timeout_s=3.0)
    if app_bin.exists() and app_bin.is_file():
        _ = shell_ok("sleep 0.05", timeout_s=1.0)


def ensure_bootstrap(
    open_cli_bin: pathlib.Path,
    fixture_path: pathlib.Path,
    socket_path: pathlib.Path,
    telemetry_path: pathlib.Path,
    timeout_s: float,
) -> None:
    telemetry_offset = telemetry_path.stat().st_size if telemetry_path.exists() else 0
    try:
        _ = subprocess.run(
            [str(open_cli_bin), "open", "--path", str(fixture_path), "--timeout-ms", str(int(max(1000, timeout_s * 1000)))],
            text=True,
            capture_output=True,
            timeout=max(2.0, timeout_s),
        )
    except Exception:
        pass
    try:
        evt, _ = wait_for_new_jsonl(
            telemetry_path,
            telemetry_offset,
            timeout_s=min(2.0, timeout_s),
            predicate=lambda o: o.get("event") == "cli_open",
        )
        sid = evt.get("sessionId")
        if isinstance(sid, str) and sid:
            _ = rpc_session_close(socket_path, sid, timeout_s=1.5)
    except Exception:
        pass


# ---------- cycles ----------

@dataclass
class CycleAttemptResult:
    success: bool
    recoverable: bool
    reason: str
    cycle: Dict[str, Any]


def run_cycle_attempt(
    cycle_idx: int,
    attempt_idx: int,
    *,
    fixture_path: pathlib.Path,
    open_cli_bin: pathlib.Path,
    socket_path: pathlib.Path,
    telemetry_path: pathlib.Path,
    open_timeout_s: float,
    close_timeout_s: float,
    idle_settle_ms: float,
    post_close_settle_ms: float,
    sample_ms: float,
    save_iterations: int,
    payload_bytes: int,
    inject_fail: bool,
) -> CycleAttemptResult:
    cycle: Dict[str, Any] = {
        "cycle": cycle_idx,
        "attempt": attempt_idx,
        "startedAt": now_iso(),
        "probe": "ram_api",
        "timestamps": {},
        "validation": {"ordering_ok": True, "ordering_errors": []},
    }

    if inject_fail:
        cycle["ok"] = False
        cycle["error"] = "injected_transient_failure"
        return CycleAttemptResult(False, True, "injected_transient_failure", cycle)

    telemetry_offset = telemetry_path.stat().st_size if telemetry_path.exists() else 0

    try:
        try:
            hello = rpc_hello(socket_path, timeout_s=max(1.0, open_timeout_s))
        except Exception:
            ensure_bootstrap(
                open_cli_bin=open_cli_bin,
                fixture_path=fixture_path,
                socket_path=socket_path,
                telemetry_path=telemetry_path,
                timeout_s=max(2.0, open_timeout_s),
            )
            hello = rpc_hello(socket_path, timeout_s=max(1.0, open_timeout_s))
        server_pid = int(hello.get("serverPid") or 0)
        if server_pid <= 0:
            raise RuntimeError("invalid_server_pid")
        cycle["serverPid"] = server_pid

        cycle["timestamps"]["idle_start_ns"] = time.perf_counter_ns()
        idle_samples = collect_rss_samples(server_pid, duration_s=max(0.01, idle_settle_ms / 1000.0), sample_ms=sample_ms)
        cycle["timestamps"]["idle_end_ns"] = time.perf_counter_ns()
        if not idle_samples:
            raise RuntimeError("idle_sampling_empty")

        idle_bytes = int(statistics.median(idle_samples))
        peak_bytes = max(idle_samples)

        cmd = [
            str(open_cli_bin),
            "open",
            "--path",
            str(fixture_path),
            "--wait",
            "--timeout-ms",
            str(int(max(1000, (open_timeout_s + close_timeout_s + 2.0) * 1000))),
        ]
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        cycle["timestamps"]["trigger_ns"] = time.perf_counter_ns()

        open_evt, telemetry_offset = wait_for_new_jsonl(
            telemetry_path,
            telemetry_offset,
            timeout_s=open_timeout_s,
            predicate=lambda o: o.get("event") == "cli_open",
        )
        cycle["timestamps"]["open_event_ns"] = time.perf_counter_ns()
        session_id = str(open_evt.get("sessionId") or "")
        if not session_id:
            raise RuntimeError("missing_session_id")
        cycle["sessionId"] = session_id

        base_text = fixture_path.read_text(encoding="utf-8")
        diag_cov = {"history": 0, "styler": 0}
        hist_count_peak = None
        hist_bytes_peak = None
        styler_entry_peak = None
        styler_limit = None

        cycle["timestamps"]["workload_start_ns"] = time.perf_counter_ns()
        for i in range(max(1, save_iterations)):
            content = base_text + deterministic_payload(cycle_idx, i, payload_bytes)
            _ = rpc_save(socket_path, session_id, content, timeout_s=max(1.0, open_timeout_s))
            metrics = rpc_bench_metrics(socket_path, session_id, timeout_s=max(1.0, open_timeout_s))

            if isinstance(metrics.get("memoryResidentBytes"), (int, float)):
                peak_bytes = max(peak_bytes, int(metrics["memoryResidentBytes"]))

            h_count = metrics.get("historySnapshotCount")
            h_bytes = metrics.get("historySnapshotBytes")
            c_count = metrics.get("stylerCacheEntryCount")
            c_limit = metrics.get("stylerCacheLimit")
            if isinstance(h_count, int):
                diag_cov["history"] += 1
                hist_count_peak = max(hist_count_peak or h_count, h_count)
            if isinstance(h_bytes, (int, float)):
                hist_bytes = int(h_bytes)
                hist_bytes_peak = max(hist_bytes_peak or hist_bytes, hist_bytes)
            if isinstance(c_count, int):
                diag_cov["styler"] += 1
                styler_entry_peak = max(styler_entry_peak or c_count, c_count)
            if isinstance(c_limit, int):
                styler_limit = c_limit

            r = rss_bytes(server_pid)
            if r is not None:
                peak_bytes = max(peak_bytes, r)

            time.sleep(max(0.0, sample_ms / 1000.0))
        cycle["timestamps"]["workload_end_ns"] = time.perf_counter_ns()

        close_trigger_ns = time.perf_counter_ns()
        close_rpc_ms = rpc_session_close(socket_path, session_id, timeout_s=max(1.0, close_timeout_s))
        cycle["timestamps"]["close_trigger_ns"] = close_trigger_ns
        cycle["closeRpcRoundtripMs"] = close_rpc_ms

        proc.wait(timeout=max(1.0, close_timeout_s))
        cycle["timestamps"]["proc_exit_ns"] = time.perf_counter_ns()

        _wait_evt, telemetry_offset = wait_for_new_jsonl(
            telemetry_path,
            telemetry_offset,
            timeout_s=close_timeout_s,
            predicate=lambda o: o.get("event") == "cli_wait",
        )
        cycle["timestamps"]["wait_event_ns"] = time.perf_counter_ns()

        post_samples = collect_rss_samples(
            server_pid,
            duration_s=max(0.01, post_close_settle_ms / 1000.0),
            sample_ms=sample_ms,
        )
        if not post_samples:
            raise RuntimeError("post_close_sampling_empty")
        post_close_bytes = int(statistics.median(post_samples))

        cycle["idleResidentBytes"] = idle_bytes
        cycle["peakResidentBytes"] = int(peak_bytes)
        cycle["postCloseResidentBytes"] = post_close_bytes
        cycle["peakDeltaBytes"] = int(peak_bytes - idle_bytes)
        cycle["residualBytes"] = int(post_close_bytes - idle_bytes)
        cycle["historySnapshotCountPeak"] = hist_count_peak
        cycle["historySnapshotBytesPeak"] = hist_bytes_peak
        cycle["stylerCacheEntryPeak"] = styler_entry_peak
        cycle["stylerCacheLimit"] = styler_limit
        cycle["diagnosticCoverage"] = {
            "history": diag_cov["history"] / float(max(1, save_iterations)),
            "styler": diag_cov["styler"] / float(max(1, save_iterations)),
        }

        ord_errs: List[str] = []
        ts = cycle["timestamps"]
        ordered_keys = [
            "idle_start_ns",
            "idle_end_ns",
            "trigger_ns",
            "open_event_ns",
            "workload_start_ns",
            "workload_end_ns",
            "close_trigger_ns",
            "proc_exit_ns",
            "wait_event_ns",
        ]
        for i in range(len(ordered_keys) - 1):
            a = ordered_keys[i]
            b = ordered_keys[i + 1]
            if ts.get(a) is None or ts.get(b) is None:
                ord_errs.append(f"missing_timestamp:{a}->{b}")
                continue
            if int(ts[a]) > int(ts[b]):
                ord_errs.append(f"ordering:{a}>{b}")
        cycle["validation"]["ordering_errors"] = ord_errs
        cycle["validation"]["ordering_ok"] = len(ord_errs) == 0

        stderr = (proc.stderr.read() if proc.stderr else "").strip()
        cycle["returnCode"] = int(proc.returncode)
        if stderr:
            cycle["stderrTail"] = stderr[-300:]

        if proc.returncode != 0:
            cycle["ok"] = False
            return CycleAttemptResult(False, True, f"open_wait_exit_{proc.returncode}", cycle)
        if not cycle["validation"]["ordering_ok"]:
            cycle["ok"] = False
            return CycleAttemptResult(False, True, "timestamp_ordering_invalid", cycle)

        cycle["ok"] = True
        return CycleAttemptResult(True, True, "ok", cycle)

    except subprocess.TimeoutExpired as ex:
        try:
            proc = ex.__dict__.get("process")
            if proc:
                proc.kill()
        except Exception:
            pass
        cycle["ok"] = False
        cycle["error"] = f"timeout:{ex}"
        return CycleAttemptResult(False, True, "timeout", cycle)
    except Exception as ex:
        cycle["ok"] = False
        cycle["error"] = str(ex)
        return CycleAttemptResult(False, True, "exception", cycle)


# ---------- main ----------

def print_table(title: str, summary: Dict[str, Any], unit: str = "MiB") -> None:
    n = summary.get("n")
    def fmt(x: Any) -> str:
        if x is None:
            return "-"
        return f"{float(x):.2f}"

    print(f"\n{title} ({unit})")
    print("  n    min    median    p95    max")
    print(f"  {n:<4} {fmt(summary.get('min')):<6} {fmt(summary.get('median')):<8} {fmt(summary.get('p95')):<6} {fmt(summary.get('max')):<6}")


def compare_metric(cur: Dict[str, Any], prev: Dict[str, Any]) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    for k in ("median", "p95"):
        c = cur.get(k)
        p = prev.get(k)
        if c is None or p is None:
            out[k] = {"delta": None, "pct": None}
        else:
            delta = float(c) - float(p)
            pct = None if abs(float(p)) < 1e-9 else (delta / float(p)) * 100.0
            out[k] = {"delta": delta, "pct": pct}
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="TurboDraft RAM benchmark suite")
    ap.add_argument("--cycles", type=int, default=20)
    ap.add_argument("--warmup", type=int, default=1)
    ap.add_argument("--retries", type=int, default=1)
    ap.add_argument("--open-timeout-s", type=float, default=6.0)
    ap.add_argument("--close-timeout-s", type=float, default=4.0)
    ap.add_argument("--inter-cycle-delay-s", type=float, default=0.1)
    ap.add_argument("--idle-settle-ms", type=float, default=180.0)
    ap.add_argument("--post-close-settle-ms", type=float, default=220.0)
    ap.add_argument("--sample-ms", type=float, default=20.0)
    ap.add_argument("--save-iterations", type=int, default=8)
    ap.add_argument("--payload-bytes", type=int, default=32_000)
    ap.add_argument("--clean-slate", action="store_true", default=False)
    ap.add_argument("--no-clean-slate", action="store_false", dest="clean_slate")
    ap.add_argument("--fixture", default="bench/preambles/core.md")
    ap.add_argument("--out-dir", default=None)
    ap.add_argument("--compare", default=None)
    ap.add_argument("--inject-transient-failure-cycle", type=int, default=0)

    # Gate thresholds (MiB)
    ap.add_argument("--enforce-gates", action="store_true", default=False)
    ap.add_argument("--max-peak-delta-p95-mib", type=float, default=32.0)
    ap.add_argument("--max-post-close-residual-p95-mib", type=float, default=30.0)
    ap.add_argument("--max-memory-slope-mib-per-cycle", type=float, default=0.8)

    args = ap.parse_args()

    repo = pathlib.Path(__file__).resolve().parents[1]
    out_dir = pathlib.Path(args.out_dir).resolve() if args.out_dir else (repo / "tmp" / f"bench_ram_{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}")
    ensure_dir(out_dir)

    fixture_src = pathlib.Path(args.fixture)
    if not fixture_src.is_absolute():
        fixture_src = (repo / fixture_src).resolve()
    if not fixture_src.exists():
        raise SystemExit(f"fixture not found: {fixture_src}")

    fixture = out_dir / "ram-fixture.md"
    fixture.write_text(fixture_src.read_text(encoding="utf-8"), encoding="utf-8")

    open_cli_bin = repo / ".build" / "release" / "turbodraft-bench"
    app_bin = repo / ".build" / "release" / "turbodraft-app"
    if not open_cli_bin.exists():
        ok, text = shell_ok("command -v turbodraft-bench", timeout_s=2.0)
        if ok:
            open_cli_bin = pathlib.Path(text.splitlines()[-1].strip())
    if not open_cli_bin.exists():
        raise SystemExit("turbodraft-bench binary not found (build release first)")

    app_support = default_app_support_dir()
    socket_path = resolve_socket_path()
    telemetry_path = app_support / "telemetry" / "editor-open.jsonl"

    ensure_dir(socket_path.parent)
    ensure_dir(telemetry_path.parent)

    # preconditions
    if args.clean_slate:
        kill_turbodraft(socket_path=socket_path, app_bin=app_bin)

    cycles: List[Dict[str, Any]] = []
    unrecovered_failures = 0
    transient_failure_injected = False
    transient_failure_recovered = False

    for cycle_idx in range(1, max(1, args.cycles) + 1):
        cycle_ok = False
        last_reason = "unknown"
        last_cycle: Dict[str, Any] = {}

        for attempt_idx in range(1, max(1, args.retries) + 2):
            inject_fail = bool(args.inject_transient_failure_cycle == cycle_idx and attempt_idx == 1)
            if inject_fail:
                transient_failure_injected = True

            if args.clean_slate:
                kill_turbodraft(socket_path=socket_path, app_bin=app_bin)
                ensure_bootstrap(
                    open_cli_bin=open_cli_bin,
                    fixture_path=fixture,
                    socket_path=socket_path,
                    telemetry_path=telemetry_path,
                    timeout_s=max(2.0, args.open_timeout_s),
                )

            result = run_cycle_attempt(
                cycle_idx,
                attempt_idx,
                fixture_path=fixture,
                open_cli_bin=open_cli_bin,
                socket_path=socket_path,
                telemetry_path=telemetry_path,
                open_timeout_s=args.open_timeout_s,
                close_timeout_s=args.close_timeout_s,
                idle_settle_ms=args.idle_settle_ms,
                post_close_settle_ms=args.post_close_settle_ms,
                sample_ms=args.sample_ms,
                save_iterations=args.save_iterations,
                payload_bytes=args.payload_bytes,
                inject_fail=inject_fail,
            )

            last_reason = result.reason
            last_cycle = result.cycle
            if result.success:
                cycle_ok = True
                if args.inject_transient_failure_cycle == cycle_idx and attempt_idx > 1:
                    transient_failure_recovered = True
                break

        if not cycle_ok:
            unrecovered_failures += 1
            last_cycle["ok"] = False
            last_cycle["error"] = last_cycle.get("error") or last_reason

        last_cycle["warmup"] = bool(cycle_idx <= max(0, args.warmup))
        cycles.append(last_cycle)

        if cycle_idx < args.cycles:
            time.sleep(max(0.0, args.inter_cycle_delay_s))

    cycles_path = out_dir / "cycles.jsonl"
    with cycles_path.open("w", encoding="utf-8") as fh:
        for c in cycles:
            fh.write(json.dumps(c, separators=(",", ":")) + "\n")

    steady = [c for c in cycles if c.get("ok") and not c.get("warmup")]

    def collect(metric: str, convert_mib: bool = True) -> List[float]:
        out: List[float] = []
        for c in steady:
            v = c.get(metric)
            if isinstance(v, (int, float)):
                out.append(float(v) / (1024.0 * 1024.0) if convert_mib else float(v))
        return out

    idle_mib = collect("idleResidentBytes")
    peak_mib = collect("peakResidentBytes")
    post_close_mib = collect("postCloseResidentBytes")
    peak_delta_mib = collect("peakDeltaBytes")
    residual_mib = collect("residualBytes")

    slope = linear_slope_per_cycle([
        (int(c["cycle"]), float(c["peakDeltaBytes"]) / (1024.0 * 1024.0))
        for c in steady
        if isinstance(c.get("peakDeltaBytes"), (int, float))
    ])

    summary = {
        "idleResidentMiB": summarize(idle_mib),
        "peakResidentMiB": summarize(peak_mib),
        "postCloseResidentMiB": summarize(post_close_mib),
        "peakDeltaResidentMiB": summarize(peak_delta_mib),
        "postCloseResidualMiB": summarize(residual_mib),
        "memorySlopeMiBPerCycle": slope,
    }

    outliers = {
        "peakDeltaResidentMiB": detect_outliers_iqr([
            (int(c["cycle"]), float(c["peakDeltaBytes"]) / (1024.0 * 1024.0))
            for c in steady
            if isinstance(c.get("peakDeltaBytes"), (int, float))
        ]),
        "postCloseResidualMiB": detect_outliers_iqr([
            (int(c["cycle"]), float(c["residualBytes"]) / (1024.0 * 1024.0))
            for c in steady
            if isinstance(c.get("residualBytes"), (int, float))
        ]),
    }

    peak_outlier_cycles = set(int(x) for x in outliers["peakDeltaResidentMiB"].get("cycles", []))
    residual_outlier_cycles = set(int(x) for x in outliers["postCloseResidualMiB"].get("cycles", []))

    peak_delta_no_outlier: List[float] = [
        float(c["peakDeltaBytes"]) / (1024.0 * 1024.0)
        for c in steady
        if isinstance(c.get("peakDeltaBytes"), (int, float)) and int(c["cycle"]) not in peak_outlier_cycles
    ]
    residual_no_outlier: List[float] = [
        float(c["residualBytes"]) / (1024.0 * 1024.0)
        for c in steady
        if isinstance(c.get("residualBytes"), (int, float)) and int(c["cycle"]) not in residual_outlier_cycles
    ]
    summary["peakDeltaResidentMiBNoOutliers"] = summarize(peak_delta_no_outlier)
    summary["postCloseResidualMiBNoOutliers"] = summarize(residual_no_outlier)

    # coverage for optional probes
    def coverage_of(field: str) -> float:
        if not steady:
            return 0.0
        have = sum(1 for c in steady if c.get(field) is not None)
        return have / float(len(steady))

    optional_coverage = {
        "historySnapshotCountPeak": coverage_of("historySnapshotCountPeak"),
        "historySnapshotBytesPeak": coverage_of("historySnapshotBytesPeak"),
        "stylerCacheEntryPeak": coverage_of("stylerCacheEntryPeak"),
        "stylerCacheLimit": coverage_of("stylerCacheLimit"),
    }

    # core validity
    ordering_ok = all(bool(c.get("validation", {}).get("ordering_ok", False)) for c in steady)
    sample_ok = (
        summary["peakDeltaResidentMiB"]["n"] == len(steady)
        and summary["postCloseResidualMiB"]["n"] == len(steady)
    )

    # gates
    peak_p95_raw = summary["peakDeltaResidentMiB"].get("p95")
    residual_p95_raw = summary["postCloseResidualMiB"].get("p95")
    peak_p95 = summary["peakDeltaResidentMiBNoOutliers"].get("p95") or peak_p95_raw
    residual_p95 = summary["postCloseResidualMiBNoOutliers"].get("p95") or residual_p95_raw
    gate_checks = {
        "peak_delta_p95": {
            "limit_mib": float(args.max_peak_delta_p95_mib),
            "value_mib": peak_p95,
            "raw_value_mib": peak_p95_raw,
            "source": "no_outlier_p95",
            "pass": (peak_p95 is not None and peak_p95 <= float(args.max_peak_delta_p95_mib)),
        },
        "post_close_residual_p95": {
            "limit_mib": float(args.max_post_close_residual_p95_mib),
            "value_mib": residual_p95,
            "raw_value_mib": residual_p95_raw,
            "source": "no_outlier_p95",
            "pass": (residual_p95 is not None and residual_p95 <= float(args.max_post_close_residual_p95_mib)),
        },
        "slope_per_cycle": {
            "limit_mib": float(args.max_memory_slope_mib_per_cycle),
            "value_mib": slope,
            "pass": (slope is not None and slope <= float(args.max_memory_slope_mib_per_cycle)),
        },
    }
    gate_pass = all(v.get("pass", False) for v in gate_checks.values())

    validity_reasons: List[str] = []
    if unrecovered_failures != 0:
        validity_reasons.append("unrecovered_failures_nonzero")
    if len(steady) <= 0:
        validity_reasons.append("no_steady_state_cycles")
    if not ordering_ok:
        validity_reasons.append("timestamp_ordering_invalid")
    if not sample_ok:
        validity_reasons.append("sample_count_mismatch")
    if args.enforce_gates and not gate_pass:
        validity_reasons.append("gate_failed")

    run_valid = len(validity_reasons) == 0

    report: Dict[str, Any] = {
        "suite": "turbodraft_ram",
        "generatedAt": now_iso(),
        "runDir": str(out_dir),
        "config": {
            "cycles": args.cycles,
            "warmup": args.warmup,
            "retries": args.retries,
            "openTimeoutS": args.open_timeout_s,
            "closeTimeoutS": args.close_timeout_s,
            "interCycleDelayS": args.inter_cycle_delay_s,
            "idleSettleMs": args.idle_settle_ms,
            "postCloseSettleMs": args.post_close_settle_ms,
            "sampleMs": args.sample_ms,
            "saveIterations": args.save_iterations,
            "payloadBytes": args.payload_bytes,
            "cleanSlate": args.clean_slate,
            "fixture": str(fixture),
            "injectTransientFailureCycle": args.inject_transient_failure_cycle,
            "enforceGates": args.enforce_gates,
            "thresholdsMiB": {
                "peakDeltaP95": args.max_peak_delta_p95_mib,
                "postCloseResidualP95": args.max_post_close_residual_p95_mib,
                "slopePerCycle": args.max_memory_slope_mib_per_cycle,
            },
        },
        "environment": {
            "platform": platform.platform(),
            "python": sys.version.split()[0],
            "machine": platform.machine(),
            "processor": platform.processor(),
        },
        "method": {
            "primary": "resident-memory sampling aligned to cycle phases (idle/workload/close)",
            "workload": "deterministic session.save mutations with fixed payload size",
            "headlineExcludesWarmup": True,
            "outlierMethod": "iqr_1.5",
        },
        "summarySteadyState": summary,
        "outliers": outliers,
        "gates": {"pass": gate_pass, "checks": gate_checks},
        "validity": {
            "runValid": run_valid,
            "reasons": validity_reasons,
            "unrecoveredFailures": unrecovered_failures,
            "steadyStateCycleCount": len(steady),
            "timestampOrderingOk": ordering_ok,
            "primarySampleCountOk": sample_ok,
            "optionalProbeCoverage": optional_coverage,
            "transientFailureInjected": transient_failure_injected,
            "transientFailureRecovered": transient_failure_recovered,
        },
        "files": {
            "cycles": str(cycles_path),
        },
    }

    if args.compare:
        comp_path = pathlib.Path(args.compare)
        if comp_path.exists():
            try:
                prev = json.loads(comp_path.read_text(encoding="utf-8"))
                prev_summary = prev.get("summarySteadyState", {})
                report["compare"] = {
                    "path": str(comp_path),
                    "peakDeltaResidentMiB": compare_metric(summary["peakDeltaResidentMiB"], prev_summary.get("peakDeltaResidentMiB", {})),
                    "postCloseResidualMiB": compare_metric(summary["postCloseResidualMiB"], prev_summary.get("postCloseResidualMiB", {})),
                    "idleResidentMiB": compare_metric(summary["idleResidentMiB"], prev_summary.get("idleResidentMiB", {})),
                    "slopeDeltaMiBPerCycle": (
                        None
                        if prev_summary.get("memorySlopeMiBPerCycle") is None or slope is None
                        else (slope - float(prev_summary.get("memorySlopeMiBPerCycle")))
                    ),
                }
            except Exception as ex:
                report["compare"] = {"path": str(comp_path), "error": str(ex)}

    report_path = out_dir / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"ram_report\t{report_path}")
    print(f"raw_cycles_jsonl\t{cycles_path}")
    print(f"run_valid\t{run_valid}")
    print(f"unrecovered_failures\t{unrecovered_failures}")
    print(f"steady_state_cycles\t{len(steady)}")

    print_table("Idle resident", summary["idleResidentMiB"])
    print_table("Peak resident", summary["peakResidentMiB"])
    print_table("Peak delta (peak-idle)", summary["peakDeltaResidentMiB"])
    print_table("Post-close residual", summary["postCloseResidualMiB"])

    slope_text = "-" if slope is None else f"{slope:.3f}"
    print(f"\nMemory slope (MiB/cycle)\t{slope_text}")
    print(f"gate_pass\t{gate_pass}")

    return 0 if run_valid else 2


if __name__ == "__main__":
    raise SystemExit(main())
