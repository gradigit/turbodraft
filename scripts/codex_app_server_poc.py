#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import threading
import time
from typing import Any, Dict, Literal, Optional, Protocol


Transport = Literal["lsp", "jsonl"]


def _encode_lsp_frame(payload: Dict[str, Any]) -> bytes:
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    header = f"Content-Length: {len(data)}\r\n\r\n".encode("ascii")
    return header + data


def _encode_jsonl_frame(payload: Dict[str, Any]) -> bytes:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"


class MessageReader(Protocol):
    def read_message(self, *, timeout_s: float) -> Optional[Dict[str, Any]]: ...


class FrameReader:
    def __init__(self, stream) -> None:
        self._stream = stream
        self._fd = stream.fileno()
        self._buf = bytearray()

    def read_message(self, *, timeout_s: float) -> Optional[Dict[str, Any]]:
        deadline = time.time() + timeout_s
        while True:
            msg = self._try_parse_one()
            if msg is not None:
                return msg

            remaining = deadline - time.time()
            if remaining <= 0:
                return None

            r, _, _ = select.select([self._fd], [], [], remaining)
            if not r:
                continue
            chunk = os.read(self._fd, 65536)
            if not chunk:
                return {"_eof": True}
            self._buf += chunk

    def _try_parse_one(self) -> Optional[Dict[str, Any]]:
        # Find header/body separator.
        sep = self._buf.find(b"\r\n\r\n")
        sep_len = 4
        if sep < 0:
            sep = self._buf.find(b"\n\n")
            sep_len = 2
        if sep < 0:
            return None

        header = bytes(self._buf[:sep])
        content_length: Optional[int] = None
        for line in header.splitlines():
            if line.lower().startswith(b"content-length:"):
                try:
                    content_length = int(line.split(b":", 1)[1].strip())
                except Exception:
                    content_length = None
                break

        # If we can't parse a frame header, drop it as noise and keep going.
        if content_length is None:
            del self._buf[: sep + sep_len]
            return None

        total = sep + sep_len + content_length
        if len(self._buf) < total:
            return None

        body = bytes(self._buf[sep + sep_len : total])
        del self._buf[:total]
        try:
            return json.loads(body.decode("utf-8"))
        except Exception as e:
            return {"_parse_error": str(e), "_raw": body.decode("utf-8", "replace")}


class JsonLinesReader:
    def __init__(self, stream) -> None:
        self._stream = stream
        self._fd = stream.fileno()
        self._buf = bytearray()

    def read_message(self, *, timeout_s: float) -> Optional[Dict[str, Any]]:
        deadline = time.time() + timeout_s
        while True:
            # Parse one line, if available.
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line = bytes(self._buf[:nl]).strip()
                del self._buf[: nl + 1]
                if not line:
                    continue
                # tolerate \r\n
                if line.endswith(b"\r"):
                    line = line[:-1]
                try:
                    return json.loads(line.decode("utf-8"))
                except Exception:
                    # likely a log line; ignore
                    continue

            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            r, _, _ = select.select([self._fd], [], [], remaining)
            if not r:
                continue
            chunk = os.read(self._fd, 65536)
            if not chunk:
                return {"_eof": True}
            self._buf += chunk


class CodexAppServerClient:
    def __init__(self, model: str, *, mcp_disabled: bool, transport: Transport, quiet: bool) -> None:
        self._next_id = 1

        cmd = ["codex", "app-server", "--listen", "stdio://"]
        if mcp_disabled:
            cmd += [
                "-c",
                "mcp_servers.context7.enabled=false",
                "-c",
                "mcp_servers.playwright.enabled=false",
            ]

        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=False,
        )
        if self._proc.stdin is None or self._proc.stdout is None:
            raise RuntimeError("Failed to start codex app-server with stdio pipes")

        self._model = model
        self._transport: Transport = transport
        self._quiet = quiet
        self._encode = _encode_lsp_frame if transport == "lsp" else _encode_jsonl_frame
        self._reader: MessageReader = FrameReader(self._proc.stdout) if transport == "lsp" else JsonLinesReader(self._proc.stdout)
        self._stderr_tail: list[bytes] = []
        self._stderr_lock = threading.Lock()
        self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self._stderr_thread.start()

    def _drain_stderr(self) -> None:
        if self._proc.stderr is None:
            return
        try:
            for line in iter(self._proc.stderr.readline, b""):
                if not line:
                    break
                with self._stderr_lock:
                    self._stderr_tail.append(line)
                    if len(self._stderr_tail) > 200:
                        self._stderr_tail = self._stderr_tail[-200:]
        except Exception:
            return

    def stderr_tail(self, *, max_lines: int = 40) -> str:
        with self._stderr_lock:
            tail = self._stderr_tail[-max_lines:]
        try:
            return b"".join(tail).decode("utf-8", "replace")
        except Exception:
            return ""

    def close(self) -> None:
        try:
            if self._proc.stdin:
                self._proc.stdin.close()
        except Exception:
            pass
        try:
            self._proc.terminate()
        except Exception:
            pass

    def _send(self, method: str, params: Any) -> int:
        rid = self._next_id
        self._next_id += 1
        msg = {"id": rid, "method": method, "params": params}
        frame = self._encode(msg)
        assert self._proc.stdin is not None
        self._proc.stdin.write(frame)
        self._proc.stdin.flush()
        return rid

    def _wait_for_response(self, rid: int, *, timeout_s: float) -> Dict[str, Any]:
        deadline = time.time() + timeout_s
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                tail = self.stderr_tail()
                extra = f"\n\nstderr tail:\n{tail}" if tail.strip() else ""
                raise TimeoutError(f"Timed out waiting for response id={rid}{extra}")
            msg = self._reader.read_message(timeout_s=min(0.5, remaining))
            if msg is None:
                continue
            if msg.get("_eof"):
                tail = self.stderr_tail()
                extra = f"\n\nstderr tail:\n{tail}" if tail.strip() else ""
                raise RuntimeError(f"codex app-server stdout closed unexpectedly{extra}")
            if msg.get("id") == rid:
                return msg
            # ignore notifications / other responses

    def initialize(self) -> str:
        if not self._quiet:
            sys.stderr.write("[poc] -> initialize\n")
        rid = self._send(
            "initialize",
            {
                "clientInfo": {"name": "TurboDraftPoC", "version": "0.0.1"},
                "capabilities": {"experimentalApi": True},
            },
        )
        resp = self._wait_for_response(rid, timeout_s=10)
        if "error" in resp:
            raise RuntimeError(f"initialize failed: {resp['error']}")
        if not self._quiet:
            sys.stderr.write("[poc] <- initialize ok\n")
        return resp.get("result", {}).get("userAgent", "")

    def list_models(self) -> Dict[str, Any]:
        if not self._quiet:
            sys.stderr.write("[poc] -> model/list\n")
        rid = self._send("model/list", {"limit": 200})
        resp = self._wait_for_response(rid, timeout_s=20)
        if "error" in resp:
            raise RuntimeError(f"model/list failed: {resp['error']}")
        if not self._quiet:
            sys.stderr.write("[poc] <- model/list ok\n")
        return resp.get("result", {})

    def thread_start(self, *, system_prompt: str, cwd: str) -> str:
        if not self._quiet:
            sys.stderr.write("[poc] -> thread/start\n")
        rid = self._send(
            "thread/start",
            {
                "model": self._model,
                "modelProvider": "openai",
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "ephemeral": True,
                "cwd": cwd,
                "baseInstructions": system_prompt,
                "developerInstructions": system_prompt,
                "personality": "pragmatic",
            },
        )
        resp = self._wait_for_response(rid, timeout_s=30)
        if "error" in resp:
            raise RuntimeError(f"thread/start failed: {resp['error']}")
        if not self._quiet:
            sys.stderr.write("[poc] <- thread/start ok\n")
        thread = resp.get("result", {}).get("thread", {})
        tid = thread.get("id")
        if not isinstance(tid, str) or not tid:
            raise RuntimeError(f"thread/start response missing thread.id: {resp}")
        return tid

    def run_prompt_engineering_turn(
        self,
        *,
        thread_id: str,
        draft_prompt_md: str,
        timeout_s: float,
        stream_deltas: bool,
    ) -> str:
        user_text = (
            "DRAFT PROMPT (Markdown):\n<BEGIN_PROMPT>\n"
            + draft_prompt_md.rstrip()
            + "\n<END_PROMPT>\n"
        )
        if not self._quiet:
            sys.stderr.write("[poc] -> turn/start\n")
        rid = self._send(
            "turn/start",
            {
                "threadId": thread_id,
                "input": [{"type": "text", "text": user_text}],
            },
        )
        resp = self._wait_for_response(rid, timeout_s=timeout_s)
        if "error" in resp:
            raise RuntimeError(f"turn/start failed: {resp['error']}")
        turn = resp.get("result", {}).get("turn", {})
        turn_id = turn.get("id")
        if not isinstance(turn_id, str) or not turn_id:
            raise RuntimeError(f"turn/start response missing turn.id: {resp}")
        if not self._quiet:
            sys.stderr.write(f"[poc] <- turn/start ok (turnId={turn_id})\n")

        deadline = time.time() + timeout_s
        agent_text: str = ""
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError("Timed out waiting for turn completion")
            msg = self._reader.read_message(timeout_s=min(0.5, remaining))
            if msg is None:
                continue
            if msg.get("_eof"):
                raise RuntimeError("codex app-server stdout closed unexpectedly")

            method = msg.get("method")
            params = msg.get("params", {})
            if method == "item/agentMessage/delta":
                if stream_deltas and params.get("turnId") == turn_id:
                    delta = params.get("delta")
                    if isinstance(delta, str) and delta:
                        agent_text += delta
                        sys.stdout.write(delta)
                        sys.stdout.flush()
                continue

            if method == "item/completed":
                if params.get("turnId") != turn_id:
                    continue
                item = params.get("item", {})
                if item.get("type") == "agentMessage" and isinstance(item.get("text"), str):
                    agent_text = item["text"]
                continue

            if method == "turn/completed" and params.get("turn", {}).get("id") == turn_id:
                turn = params.get("turn", {})
                status = turn.get("status")
                if status == "completed":
                    # Prefer the final agent message captured from item/completed.
                    return agent_text
                err = turn.get("error")
                raise RuntimeError(f"turn completed with status={status} error={err}")

            if method == "error":
                if params.get("turnId") != turn_id:
                    continue
                will_retry = bool(params.get("willRetry"))
                msg = params.get("error", {}).get("message")
                if will_retry:
                    if not self._quiet:
                        sys.stderr.write(f"[poc] retrying: {msg}\n")
                    continue
                raise RuntimeError(f"server error notification (no retry): {params}")


SYSTEM_PROMPT = """You are TurboDraft, a prompt-engineering assistant.

You will be given a draft prompt written in Markdown. That draft prompt is intended to be used as input to another AI system.

Your job is to rewrite the draft prompt to maximize:
- clarity and specificity
- correct constraints and boundaries
- structure (sections, steps, checklists)
- testability (acceptance criteria / examples)
- safety (no secrets, no destructive ambiguity)

Primary contract (NON-LOSSY REWRITE):
- Preserve all explicit user requirements, constraints, references, and asks from the draft.
- Preserve intent even when phrasing is uncertain ("maybe", "I don't know", "should we...").
- Do NOT silently drop details. If a detail is ambiguous, keep it and convert it into a decision or question.
- Add new requirements only when they are clearly implied by the draft and directly improve executability.
- If adding anything not clearly implied, mark it with "Optional:" and keep Optional additions to 1-2 bullets max.

Rules:
- Do NOT execute the draft prompt.
- Do NOT answer the draft prompt.
- Do NOT call tools, run commands, read files, or browse the web.
- Output ONLY the rewritten prompt text (no commentary, no preface, no code fences).
- Preserve the original intent and all critical details.
- If context is missing (logs/screenshots/history), do not invent it; ask for it as a request to the downstream agent.
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--transport", choices=["lsp", "jsonl"], default="jsonl")
    ap.add_argument("--model", default="gpt-5.3-codex-spark")
    ap.add_argument("--cwd", default=os.getcwd())
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--no-disable-mcp", action="store_true", help="Allow MCP servers from ~/.codex/config.toml to start")
    ap.add_argument("--no-stream", action="store_true", help="Do not stream deltas to stdout")
    ap.add_argument("--no-output", action="store_true", help="Do not print the final agent message to stdout")
    ap.add_argument("--skip-model-list", action="store_true", help="Skip the initial model/list call")
    ap.add_argument("--turns", type=int, default=1, help="Number of turns to run on a single thread")
    ap.add_argument("--quiet", action="store_true", help="Suppress debug output")
    ap.add_argument("--system-prompt", default=SYSTEM_PROMPT, help="System/developer prompt for the thread")
    ap.add_argument(
        "--prompt",
        default="Write a single-line git commit message for fixing a bug in paste handling.",
        help="Draft prompt Markdown to improve.",
    )
    args = ap.parse_args()

    if args.turns < 1:
        raise SystemExit("--turns must be >= 1")

    client = CodexAppServerClient(args.model, mcp_disabled=(not args.no_disable_mcp), transport=args.transport, quiet=args.quiet)
    try:
        ua = client.initialize()
        if not args.quiet:
            sys.stderr.write(f"[app-server] userAgent={ua}\n")

        if not args.skip_model_list:
            models = client.list_models()
            available = {m.get("model") for m in models.get("data", []) if isinstance(m, dict)}
            if args.model not in available and not args.quiet:
                sys.stderr.write(f"[app-server] model not in model/list: {args.model}\n")

        thread_id = client.thread_start(system_prompt=args.system_prompt, cwd=args.cwd)
        if not args.quiet:
            sys.stderr.write(f"[app-server] threadId={thread_id}\n")

        improved: str = ""
        for _ in range(args.turns):
            improved = client.run_prompt_engineering_turn(
                thread_id=thread_id,
                draft_prompt_md=args.prompt,
                timeout_s=args.timeout,
                stream_deltas=(not args.no_stream),
            )
        if not improved.strip() and not args.quiet:
            sys.stderr.write("[app-server] completed with empty agent text\n")
            return 3
        if args.no_output:
            return 0
        if args.no_stream:
            sys.stdout.write(improved)
        sys.stdout.write("\n")
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
