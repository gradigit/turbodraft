#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import pathlib
import random
import statistics
import socket
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

try:
    import AppKit  # type: ignore
    import Quartz  # type: ignore
except Exception as ex:  # pragma: no cover
    raise SystemExit(f"Missing pyobjc dependency (AppKit/Quartz): {ex}")


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


def bootstrap_ci_median(samples: List[float], rounds: int = 1200, seed: int = 17) -> Tuple[Optional[float], Optional[float]]:
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
    return None


# ---------- input synthesis / probes ----------

K_G = 5
K_S = 1
K_W = 13
K_X = 7
K_DELETE = 51


def post_key(keycode: int, flags: int = 0) -> None:
    down = Quartz.CGEventCreateKeyboardEvent(None, keycode, True)
    up = Quartz.CGEventCreateKeyboardEvent(None, keycode, False)
    Quartz.CGEventSetFlags(down, flags)
    Quartz.CGEventSetFlags(up, flags)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)
    time.sleep(0.002)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)


def send_ctrl_g() -> None:
    post_key(K_G, Quartz.kCGEventFlagMaskControl)


def apple_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


def run_osascript(script: str, timeout_s: float = 8.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["osascript"], input=script, text=True, capture_output=True, timeout=timeout_s)


def send_ctrl_g_via_osascript(target_process_name: str) -> Tuple[bool, str, float]:
    if not target_process_name:
        return False, "missing_target_process_name", 0.0
    safe = apple_escape(target_process_name)
    script = f'''
tell application "System Events"
  if not (exists process "{safe}") then error "process not found: {safe}"
  tell process "{safe}"
    set frontmost to true
    keystroke "g" using control down
  end tell
end tell
'''
    t0 = time.perf_counter()
    cp = run_osascript(script, timeout_s=6.0)
    dispatch_ms = (time.perf_counter() - t0) * 1000.0
    if cp.returncode == 0:
        return True, "", dispatch_ms
    return False, (cp.stderr.strip() or cp.stdout.strip() or "osascript_failed"), dispatch_ms


def send_cmd_s() -> None:
    post_key(K_S, Quartz.kCGEventFlagMaskCommand)


def send_cmd_w() -> None:
    post_key(K_W, Quartz.kCGEventFlagMaskCommand)


def send_cmd_w_via_osascript(target_process_name: str = "turbodraft-app") -> Tuple[bool, str]:
    safe = apple_escape(target_process_name)
    script = f'''
tell application "System Events"
  if not (exists process "{safe}") then error "process not found: {safe}"
  tell process "{safe}"
    set frontmost to true
    keystroke "w" using command down
  end tell
end tell
'''
    cp = run_osascript(script, timeout_s=4.0)
    if cp.returncode == 0:
        return True, ""
    return False, (cp.stderr.strip() or cp.stdout.strip() or "osascript_close_failed")


def send_typing_probe() -> None:
    # Best-effort probe that the editor is accepting input.
    post_key(K_X, 0)
    post_key(K_DELETE, 0)


def frontmost_app_name() -> str:
    app = AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()
    if app is None:
        return ""
    name = app.localizedName()
    return str(name) if name is not None else ""


def is_turbodraft_window_open() -> bool:
    infos = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) or []
    for w in infos:
        owner = str(w.get("kCGWindowOwnerName", ""))
        if owner in ("TurboDraft", "turbodraft-app", "turbodraft-app.debug") and int(w.get("kCGWindowLayer", 0)) == 0:
            return True
    return False


def top_layer_owner_name() -> str:
    infos = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) or []
    for w in infos:
        if int(w.get("kCGWindowLayer", 0)) != 0:
            continue
        return str(w.get("kCGWindowOwnerName", ""))
    return ""


def is_turbodraft_frontmost() -> bool:
    top = top_layer_owner_name().lower()
    if "turbodraft" in top:
        return True
    # Fallback if window list ordering is ambiguous.
    return "turbodraft" in frontmost_app_name().lower()


def wait_for(condition, timeout_s: float, poll_s: float) -> bool:
    deadline = time.perf_counter() + timeout_s
    while time.perf_counter() < deadline:
        if condition():
            return True
        time.sleep(poll_s)
    return False


class JSONRPCSocketClient:
    def __init__(self, sock_path: pathlib.Path, timeout_s: float = 3.0):
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


def send_app_quit(sock_path: pathlib.Path, timeout_s: float = 2.0) -> bool:
    try:
        with JSONRPCSocketClient(sock_path, timeout_s=timeout_s) as cli:
            _ = cli.request(9101, "turbodraft.app.quit", params={})
        return True
    except Exception:
        return False


def cleanup_stale_windows(socket_path: pathlib.Path, poll_s: float, timeout_s: float = 2.5) -> bool:
    if not is_turbodraft_window_open():
        return True
    _ = send_app_quit(socket_path, timeout_s=min(2.0, timeout_s))
    if wait_for(lambda: not is_turbodraft_window_open(), timeout_s=timeout_s, poll_s=poll_s):
        return True
    send_cmd_w()
    if wait_for(lambda: not is_turbodraft_window_open(), timeout_s=timeout_s, poll_s=poll_s):
        return True
    _ok, _err = send_cmd_w_via_osascript("turbodraft-app")
    return wait_for(lambda: not is_turbodraft_window_open(), timeout_s=timeout_s, poll_s=poll_s)


# ---------- telemetry ----------

def wait_for_new_jsonl(path: pathlib.Path, offset: int, timeout_s: float, predicate) -> Tuple[Optional[Dict[str, Any]], int]:
    deadline = time.perf_counter() + timeout_s
    cur = offset
    while time.perf_counter() < deadline:
        if path.exists():
            data = path.read_bytes()
            # File may be replaced/truncated by telemetry fallback writes; reset cursor.
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
    return None, cur


# ---------- main ----------

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


def main() -> int:
    ap = argparse.ArgumentParser(description="Real agent-CLI TurboDraft open/close probe (no harness).")
    ap.add_argument("--cycles", type=int, default=20)
    ap.add_argument("--warmup", type=int, default=1)
    ap.add_argument("--open-timeout-s", type=float, default=10.0)
    ap.add_argument("--focus-timeout-s", type=float, default=2.0, help="After window appears, max wait for TurboDraft to become frontmost")
    ap.add_argument("--close-timeout-s", type=float, default=8.0)
    ap.add_argument("--inter-cycle-delay-s", type=float, default=0.20)
    ap.add_argument("--poll-ms", type=float, default=2.0, help="Probe poll cadence in ms")
    ap.add_argument("--autosave-settle-s", type=float, default=0.06)
    ap.add_argument("--typing-probe", action="store_true", help="Type+erase one character after open to sanity-check typing path")
    ap.add_argument("--save-before-close", action="store_true", help="Send Cmd+S before Cmd+W (slower but more conservative)")
    ap.add_argument("--collect-telemetry", action="store_true", help="Also try to correlate cli_open/cli_wait telemetry (can slow cycles)")
    ap.add_argument("--telemetry-timeout-s", type=float, default=0.35, help="Per-event wait budget when --collect-telemetry is enabled")
    ap.add_argument(
        "--gate-metric",
        choices=["uiOpenReadyPostDispatchMs", "uiOpenReadyMs"],
        default="uiOpenReadyPostDispatchMs",
        help="Metric used for p95 latency gate",
    )
    ap.add_argument(
        "--max-ready-p95-ms",
        type=float,
        default=80.0,
        help="Fail run when selected gate metric p95 exceeds this threshold",
    )
    ap.add_argument("--countdown-s", type=float, default=6.0, help="Startup delay so you can switch to your real CLI window")
    ap.add_argument("--trigger-mode", choices=["auto", "cgevent", "osascript"], default="auto")
    ap.add_argument("--out-dir", default="")
    args = ap.parse_args()

    if args.cycles <= 0:
        raise SystemExit("--cycles must be > 0")
    if args.warmup < 0 or args.warmup >= args.cycles:
        raise SystemExit("--warmup must be >=0 and < cycles")

    poll_s = max(0.001, float(args.poll_ms) / 1000.0)
    if hasattr(Quartz, "AXIsProcessTrusted") and not Quartz.AXIsProcessTrusted():
        raise SystemExit(
            "Accessibility permission is required for synthetic Ctrl+G. "
            "Enable it for your terminal/python host in System Settings -> Privacy & Security -> Accessibility."
        )
    repo = pathlib.Path(__file__).resolve().parents[1]
    out_dir = pathlib.Path(args.out_dir) if args.out_dir else (repo / "tmp" / f"bench_open_close_real_cli_{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}")
    out_dir.mkdir(parents=True, exist_ok=True)
    socket_path = pathlib.Path.home() / "Library" / "Application Support" / "TurboDraft" / "turbodraft.sock"
    telemetry_path = pathlib.Path.home() / "Library" / "Application Support" / "TurboDraft" / "telemetry" / "editor-open.jsonl"
    telemetry_offset = telemetry_path.stat().st_size if telemetry_path.exists() else 0

    print("Focus your real agent CLI window now (Codex/Claude/Terminal/iTerm).")
    print(f"Starting in {max(0.0, float(args.countdown_s)):.1f} seconds...")
    time.sleep(max(0.0, float(args.countdown_s)))

    cycles: List[Dict[str, Any]] = []
    failures: List[Dict[str, Any]] = []

    for idx in range(1, args.cycles + 1):
        warmup = idx <= args.warmup
        c: Dict[str, Any] = {"cycle": idx, "warmup": warmup, "startedAt": now_iso()}
        try:
            if is_turbodraft_window_open():
                recovered = cleanup_stale_windows(socket_path, poll_s=poll_s, timeout_s=2.5)
                c["staleWindowRecovered"] = recovered
                if not recovered:
                    raise RuntimeError("stale_window_recovery_failed")

            front_before = frontmost_app_name()
            c["frontmostBefore"] = front_before

            t0 = time.perf_counter()
            trigger_used = "cgevent"
            trigger_err = ""
            dispatch_ms = 0.0
            if args.trigger_mode in ("auto", "osascript"):
                ok, err, dms = send_ctrl_g_via_osascript(front_before)
                if ok:
                    trigger_used = "osascript"
                    dispatch_ms = dms
                elif args.trigger_mode == "osascript":
                    raise RuntimeError(f"trigger_failed:{err}")
                else:
                    trigger_err = err
                    t_dispatch = time.perf_counter()
                    send_ctrl_g()
                    dispatch_ms = (time.perf_counter() - t_dispatch) * 1000.0
            else:
                t_dispatch = time.perf_counter()
                send_ctrl_g()
                dispatch_ms = (time.perf_counter() - t_dispatch) * 1000.0
            c["triggeredAt"] = now_iso()
            c["triggerModeUsed"] = trigger_used
            c["triggerDispatchMs"] = dispatch_ms
            if trigger_err:
                c["triggerFallbackError"] = trigger_err
            time.sleep(0.02)
            c["frontmostAfterTrigger"] = frontmost_app_name()
            c["topLayerOwnerAfterTrigger"] = top_layer_owner_name()

            opened = wait_for(
                lambda: is_turbodraft_window_open(),
                timeout_s=float(args.open_timeout_s),
                poll_s=poll_s,
            )
            if not opened:
                c["turbodraftWindowObserved"] = is_turbodraft_window_open()
                c["turbodraftFrontmostObserved"] = is_turbodraft_frontmost()
                raise TimeoutError("open_window_timeout")
            open_visible_ms = (time.perf_counter() - t0) * 1000.0
            c["uiOpenVisibleMs"] = open_visible_ms
            c["uiOpenVisiblePostDispatchMs"] = max(0.0, open_visible_ms - dispatch_ms)

            focused = wait_for(
                lambda: is_turbodraft_frontmost(),
                timeout_s=float(args.focus_timeout_s),
                poll_s=poll_s,
            )
            if not focused:
                c["turbodraftFrontmostObserved"] = is_turbodraft_frontmost()
                c["topLayerOwnerOnFocusTimeout"] = top_layer_owner_name()
                raise TimeoutError("focus_timeout")
            open_ms = (time.perf_counter() - t0) * 1000.0
            c["uiOpenReadyMs"] = open_ms
            c["uiOpenReadyPostDispatchMs"] = max(0.0, open_ms - dispatch_ms)

            # Optional typing readiness probe (best-effort): inject+erase one char.
            if args.typing_probe:
                send_typing_probe()

            # Optional explicit save before close (slower).
            if args.save_before_close:
                time.sleep(max(0.0, float(args.autosave_settle_s)))
                send_cmd_s()
                time.sleep(0.01)

            t_close = time.perf_counter()
            send_cmd_w()
            closed = wait_for(lambda: not is_turbodraft_window_open(), timeout_s=float(args.close_timeout_s), poll_s=poll_s)
            if not closed:
                raise TimeoutError("close_timeout")
            c["uiCloseDisappearMs"] = (time.perf_counter() - t_close) * 1000.0

            # Optional telemetry correlation for this real-CLI cycle.
            if args.collect_telemetry:
                tmo = max(0.01, float(args.telemetry_timeout_s))
                open_evt, telemetry_offset = wait_for_new_jsonl(
                    telemetry_path, telemetry_offset, timeout_s=tmo, predicate=lambda o: o.get("event") == "cli_open"
                )
                wait_evt, telemetry_offset = wait_for_new_jsonl(
                    telemetry_path, telemetry_offset, timeout_s=tmo, predicate=lambda o: o.get("event") == "cli_wait"
                )
                if open_evt:
                    c["apiOpenTotalMs"] = numeric(open_evt.get("totalMs"))
                    c["apiOpenConnectMs"] = numeric(open_evt.get("connectMs"))
                    c["apiOpenRpcMs"] = numeric(open_evt.get("rpcOpenMs"))
                if wait_evt:
                    c["apiCloseWaitMs"] = numeric(wait_evt.get("waitMs"))

            c["ok"] = True
        except Exception as ex:
            c["ok"] = False
            c["error"] = str(ex)
            c["cleanupAfterError"] = cleanup_stale_windows(socket_path, poll_s=poll_s, timeout_s=2.5)
            failures.append({"cycle": idx, "error": str(ex)})
        cycles.append(c)
        time.sleep(max(0.0, float(args.inter_cycle_delay_s)))

    post_run_cleanup_ok = cleanup_stale_windows(socket_path, poll_s=poll_s, timeout_s=2.5)

    successful = [c for c in cycles if c.get("ok")]
    steady = [c for c in successful if not c.get("warmup")]

    def samples(key: str) -> List[float]:
        return [numeric(c.get(key)) for c in steady if numeric(c.get(key)) is not None]  # type: ignore

    summary = {
        "triggerDispatchMs": summarize(samples("triggerDispatchMs")),
        "uiOpenVisibleMs": summarize(samples("uiOpenVisibleMs")),
        "uiOpenVisiblePostDispatchMs": summarize(samples("uiOpenVisiblePostDispatchMs")),
        "uiOpenReadyMs": summarize(samples("uiOpenReadyMs")),
        "uiOpenReadyPostDispatchMs": summarize(samples("uiOpenReadyPostDispatchMs")),
        "uiCloseDisappearMs": summarize(samples("uiCloseDisappearMs")),
        "apiOpenTotalMs": summarize(samples("apiOpenTotalMs")),
        "apiCloseWaitMs": summarize(samples("apiCloseWaitMs")),
    }

    gate_metric = args.gate_metric
    gate_p95 = numeric((summary.get(gate_metric) or {}).get("p95_ms"))
    gate_threshold = float(args.max_ready_p95_ms)
    gate_ok = gate_p95 is not None and gate_p95 <= gate_threshold

    run_valid = (
        len(steady) > 0
        and len([c for c in cycles if not c.get("ok")]) == 0
        and gate_ok
    )
    report = {
        "schemaVersion": "1.0.0",
        "suite": "turbodraft_open_close_real_cli",
        "timestamp": now_iso(),
        "config": vars(args),
        "method": {
            "primary": "Real frontmost agent CLI Ctrl+G trigger -> TurboDraft ready/open and close disappear",
            "notes": [
                "No harness process involved",
                "Requires user to keep real agent CLI frontmost",
                "Open metric is readiness proxy: TurboDraft window visible + frontmost",
                "Poll cadence is configurable via --poll-ms",
            ],
        },
        "cycles": cycles,
        "failures": failures,
        "summary": {"steadyState": summary},
        "validation": {
            "steady_state_cycle_count": len(steady),
            "successful_cycle_count": len(successful),
            "total_cycle_count": len(cycles),
            "unrecovered_failures": len([c for c in cycles if not c.get("ok")]),
            "post_run_cleanup_ok": post_run_cleanup_ok,
            "gate_metric": gate_metric,
            "gate_metric_p95_ms": gate_p95,
            "gate_max_ready_p95_ms": gate_threshold,
            "gate_ok": gate_ok,
        },
        "runValid": run_valid,
    }

    out_json = out_dir / "report.json"
    out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")
    raw_jsonl = out_dir / "cycles.jsonl"
    with raw_jsonl.open("w", encoding="utf-8") as fh:
        for c in cycles:
            fh.write(json.dumps(c) + "\n")

    print("open_close_real_cli_report\t" + str(out_json))
    print("raw_cycles_jsonl\t" + str(raw_jsonl))
    print(f"run_valid\t{run_valid}")
    print(f"steady_state_cycles\t{len(steady)}")
    print(f"gate_metric\t{gate_metric}")
    print(f"gate_p95_ms\t{gate_p95}")
    print(f"gate_max_ready_p95_ms\t{gate_threshold}")
    print(f"gate_ok\t{gate_ok}")

    print_table("Trigger dispatch overhead (ms)", summary["triggerDispatchMs"])
    print_table("UI primary: keypress->window visible (ms)", summary["uiOpenVisibleMs"])
    print_table("UI adjusted: post-dispatch->window visible (ms)", summary["uiOpenVisiblePostDispatchMs"])
    print_table("UI primary: keypress->ready (ms)", summary["uiOpenReadyMs"])
    print_table("UI adjusted: post-dispatch->ready (ms)", summary["uiOpenReadyPostDispatchMs"])
    print_table("UI primary: close cmd->disappear (ms)", summary["uiCloseDisappearMs"])
    print_table("Auxiliary telemetry: cli_open total (ms)", summary["apiOpenTotalMs"])
    print_table("Auxiliary telemetry: cli_wait waitMs (ms)", summary["apiCloseWaitMs"])
    return 0 if run_valid else 2


if __name__ == "__main__":
    raise SystemExit(main())
