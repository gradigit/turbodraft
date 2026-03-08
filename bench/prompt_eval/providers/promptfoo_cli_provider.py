#!/usr/bin/env python3
"""
Promptfoo provider that routes model execution through local agent CLIs.

Supports:
  - codex exec (--json event stream parsing)
  - claude -p --output-format json
  - gemini --output-format json
  - auggie -p --output-format json
"""

from __future__ import annotations

import json
import pathlib
import subprocess
from typing import Any


def _to_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    return None


def _to_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _usage_to_promptfoo(usage: dict[str, Any] | None) -> dict[str, int] | None:
    if not isinstance(usage, dict):
        return None

    # Codex-style usage keys.
    prompt = _to_int(usage.get("input_tokens"))
    completion = _to_int(usage.get("output_tokens"))
    total = _to_int(usage.get("total_tokens"))

    # Promptfoo/OpenAI-style fallback keys.
    if prompt is None:
        prompt = _to_int(usage.get("prompt"))
    if completion is None:
        completion = _to_int(usage.get("completion"))
    if total is None:
        total = _to_int(usage.get("total"))

    if total is None and (prompt is not None or completion is not None):
        total = (prompt or 0) + (completion or 0)

    if total is None and prompt is None and completion is None:
        return None

    return {
        "total": int(total or 0),
        "prompt": int(prompt or 0),
        "completion": int(completion or 0),
    }


def _run_codex(prompt: str, model: str, reasoning_effort: str, timeout_sec: int) -> dict[str, Any]:
    cmd = [
        "codex",
        "exec",
        "-m",
        model,
        "--json",
        "--skip-git-repo-check",
    ]
    if reasoning_effort:
        cmd.extend(["-c", f'model_reasoning_effort="{reasoning_effort}"'])
    cmd.append("-")

    proc = subprocess.run(
        cmd,
        input=prompt,
        text=True,
        capture_output=True,
        timeout=timeout_sec,
    )

    last_message: str | None = None
    last_usage: dict[str, Any] | None = None
    error_message: str | None = None

    for raw_line in proc.stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue

        usage = ev.get("usage")
        if isinstance(usage, dict):
            last_usage = usage

        ev_type = ev.get("type")
        if ev_type == "item.completed":
            item = ev.get("item") or {}
            if item.get("type") == "agent_message":
                last_message = item.get("text", "")
        elif ev_type == "error":
            error_message = ev.get("message")
        elif ev_type == "turn.failed":
            error_message = (ev.get("error") or {}).get("message") or error_message

    if proc.returncode != 0 and not error_message:
        stderr = (proc.stderr or "").strip()
        error_message = f"codex exited {proc.returncode}: {stderr}"
    if error_message:
        return {"output": "", "error": error_message}
    if not last_message:
        return {"output": "", "error": "codex produced no agent message"}

    out: dict[str, Any] = {"output": last_message}
    token_usage = _usage_to_promptfoo(last_usage)
    if token_usage is not None:
        out["tokenUsage"] = token_usage
    cost = _to_float((last_usage or {}).get("cost_usd"))
    if cost is not None:
        out["cost"] = cost
    return out


def _extract_claude_text(events: list[dict[str, Any]]) -> str | None:
    for ev in reversed(events):
        if ev.get("type") == "result":
            result = ev.get("result")
            if isinstance(result, str):
                return result
    for ev in reversed(events):
        if ev.get("type") == "assistant":
            msg = ev.get("message") or {}
            parts = msg.get("content") or []
            texts = [part.get("text", "") for part in parts if isinstance(part, dict) and part.get("type") == "text"]
            joined = "\n".join(t for t in texts if t)
            if joined:
                return joined
    return None


def _extract_claude_usage(events: list[dict[str, Any]]) -> tuple[dict[str, int] | None, float | None]:
    usage_payload: dict[str, Any] | None = None
    total_cost_usd: float | None = None
    for ev in reversed(events):
        if ev.get("type") == "result":
            usage = ev.get("usage")
            if isinstance(usage, dict):
                usage_payload = usage
            total_cost_usd = _to_float(ev.get("total_cost_usd"))
            break

    usage = _usage_to_promptfoo(usage_payload)
    if total_cost_usd is not None:
        return usage, total_cost_usd

    cost_from_usage = _to_float((usage_payload or {}).get("cost_usd"))
    return usage, cost_from_usage


def _run_claude(prompt: str, model: str, reasoning_effort: str, timeout_sec: int) -> dict[str, Any]:
    cmd = [
        "claude",
        "-p",
        "--model",
        model,
        "--effort",
        reasoning_effort,
        "--disable-slash-commands",
        "--tools",
        "",
        "--output-format",
        "json",
        prompt,
    ]

    proc = subprocess.run(
        cmd,
        text=True,
        capture_output=True,
        timeout=timeout_sec,
    )
    if proc.returncode != 0:
        return {
            "output": "",
            "error": f"claude exited {proc.returncode}: {(proc.stderr or '').strip()}",
        }

    raw = (proc.stdout or "").strip()
    if not raw:
        return {"output": "", "error": "claude produced empty output"}

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        return {"output": "", "error": f"claude output was not valid JSON: {exc}"}

    events: list[dict[str, Any]]
    if isinstance(data, dict):
        events = [data]
    elif isinstance(data, list):
        events = [ev for ev in data if isinstance(ev, dict)]
    else:
        events = []

    text = _extract_claude_text(events)
    if text is None:
        return {"output": "", "error": "claude JSON did not include assistant/result text"}

    usage, cost = _extract_claude_usage(events)
    out: dict[str, Any] = {"output": text}
    if usage is not None:
        out["tokenUsage"] = usage
    if cost is not None:
        out["cost"] = cost
    return out


def _collect_text_strings(payload: Any) -> list[str]:
    out: list[str] = []
    if isinstance(payload, str):
        if payload.strip():
            out.append(payload)
        return out
    if isinstance(payload, dict):
        for key, value in payload.items():
            if key in {"text", "response", "result", "output"} and isinstance(value, str) and value.strip():
                out.append(value)
            else:
                out.extend(_collect_text_strings(value))
        return out
    if isinstance(payload, list):
        for item in payload:
            out.extend(_collect_text_strings(item))
    return out


def _extract_gemini_usage(payload: Any) -> dict[str, Any] | None:
    if isinstance(payload, dict):
        stats = payload.get("stats")
        if isinstance(stats, dict):
            models = stats.get("models")
            if isinstance(models, dict):
                for model_stats in models.values():
                    if not isinstance(model_stats, dict):
                        continue
                    tok = model_stats.get("tokens")
                    if not isinstance(tok, dict):
                        continue
                    prompt_tokens = _to_int(tok.get("prompt"))
                    completion_tokens = _to_int(tok.get("candidates"))
                    total_tokens = _to_int(tok.get("total"))
                    if total_tokens is None and (prompt_tokens is not None or completion_tokens is not None):
                        total_tokens = int((prompt_tokens or 0) + (completion_tokens or 0))
                    out_stats: dict[str, Any] = {}
                    if prompt_tokens is not None:
                        out_stats["prompt"] = prompt_tokens
                    if completion_tokens is not None:
                        out_stats["completion"] = completion_tokens
                    if total_tokens is not None:
                        out_stats["total"] = total_tokens
                    if out_stats:
                        return out_stats

    best: dict[str, Any] | None = None

    def visit(node: Any) -> None:
        nonlocal best
        if isinstance(node, dict):
            keys = set(node.keys())
            if {"promptTokenCount", "candidatesTokenCount", "totalTokenCount"}.intersection(keys):
                best = node
            for child in node.values():
                visit(child)
        elif isinstance(node, list):
            for item in node:
                visit(item)

    visit(payload)
    if not isinstance(best, dict):
        return None
    prompt_tokens = _to_int(best.get("promptTokenCount"))
    completion_tokens = _to_int(best.get("candidatesTokenCount"))
    total_tokens = _to_int(best.get("totalTokenCount"))
    if total_tokens is None and (prompt_tokens is not None or completion_tokens is not None):
        total_tokens = int((prompt_tokens or 0) + (completion_tokens or 0))
    out: dict[str, Any] = {}
    if prompt_tokens is not None:
        out["prompt"] = prompt_tokens
    if completion_tokens is not None:
        out["completion"] = completion_tokens
    if total_tokens is not None:
        out["total"] = total_tokens
    return out or None


def _extract_last_json_object(raw: str) -> Any:
    raw = (raw or "").strip()
    if not raw:
        raise RuntimeError("empty output")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        pass

    decoder = json.JSONDecoder()
    best_obj: Any = None
    i = 0
    n = len(raw)
    while i < n:
        if raw[i] != "{":
            i += 1
            continue
        try:
            obj, end = decoder.raw_decode(raw[i:])
        except json.JSONDecodeError:
            i += 1
            continue
        if isinstance(obj, dict):
            best_obj = obj
        i += max(1, end)
    if best_obj is None:
        raise RuntimeError("no JSON object found in output")
    return best_obj


def _run_gemini(prompt: str, model: str, reasoning_effort: str, timeout_sec: int) -> dict[str, Any]:
    _ = reasoning_effort  # currently unused by gemini CLI
    cmd = [
        "gemini",
        "--output-format",
        "json",
        "--model",
        model,
        "--prompt",
        prompt,
    ]

    proc = subprocess.run(
        cmd,
        text=True,
        capture_output=True,
        timeout=timeout_sec,
    )
    if proc.returncode != 0:
        return {
            "output": "",
            "error": f"gemini exited {proc.returncode}: {(proc.stderr or '').strip()}",
        }

    raw = proc.stdout or ""
    if not raw.strip():
        return {"output": "", "error": "gemini produced empty output"}
    try:
        data = _extract_last_json_object(raw)
    except Exception as exc:
        return {"output": "", "error": f"gemini output did not contain parsable JSON: {exc}"}

    texts = _collect_text_strings(data)
    text = next((t for t in reversed(texts) if t.strip()), None)
    if text is None:
        return {"output": "", "error": "gemini JSON did not include parsable text"}

    out: dict[str, Any] = {"output": text}
    usage = _usage_to_promptfoo(_extract_gemini_usage(data))
    if usage is not None:
        out["tokenUsage"] = usage
    return out


def _run_auggie(prompt: str, model: str, reasoning_effort: str, timeout_sec: int) -> dict[str, Any]:
    _ = reasoning_effort  # currently no explicit reasoning-effort flag in auggie CLI
    workspace_root = str(pathlib.Path.cwd())
    cmd = [
        "auggie",
        "-p",
        "-q",
        "--output-format",
        "json",
        "-m",
        model,
        "-w",
        workspace_root,
        "--allow-indexing",
        "--max-turns",
        "1",
        "-i",
        prompt,
    ]

    proc = subprocess.run(
        cmd,
        text=True,
        capture_output=True,
        timeout=timeout_sec,
    )
    if proc.returncode != 0:
        return {
            "output": "",
            "error": f"auggie exited {proc.returncode}: {(proc.stderr or '').strip()}",
        }

    raw = proc.stdout or ""
    if not raw.strip():
        return {"output": "", "error": "auggie produced empty output"}
    try:
        data = _extract_last_json_object(raw)
    except Exception as exc:
        return {"output": "", "error": f"auggie output did not contain parsable JSON: {exc}"}

    if isinstance(data, dict):
        result = data.get("result")
        if isinstance(result, str) and result.strip():
            return {"output": result.strip()}

    texts = _collect_text_strings(data)
    text = next((t for t in reversed(texts) if t.strip()), None)
    if text is None:
        return {"output": "", "error": "auggie JSON did not include parsable text"}
    return {"output": text.strip()}


def call_api(prompt: str, options: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    _ = context  # currently unused
    config = (options or {}).get("config") or {}
    runner = str(config.get("runner", "codex")).strip().lower()
    default_model = {
        "codex": "gpt-5.3-codex-spark",
        "claude": "claude-opus-4-6",
        "gemini": "gemini-3.1-pro-preview",
        "auggie": "gpt5.4",
    }.get(runner, "gpt-5.3-codex-spark")
    default_effort = {
        "codex": "xhigh",
        "claude": "high",
        "gemini": "high",
        "auggie": "high",
    }.get(runner, "xhigh")
    model = str(config.get("model", default_model)).strip()
    reasoning_effort = str(config.get("reasoning_effort", default_effort)).strip() or default_effort
    timeout_sec = int(config.get("timeout_sec", 600))

    if runner == "codex":
        return _run_codex(prompt=prompt, model=model, reasoning_effort=reasoning_effort, timeout_sec=timeout_sec)
    if runner == "claude":
        return _run_claude(prompt=prompt, model=model, reasoning_effort=reasoning_effort, timeout_sec=timeout_sec)
    if runner == "gemini":
        return _run_gemini(prompt=prompt, model=model, reasoning_effort=reasoning_effort, timeout_sec=timeout_sec)
    if runner == "auggie":
        return _run_auggie(prompt=prompt, model=model, reasoning_effort=reasoning_effort, timeout_sec=timeout_sec)
    return {"output": "", "error": f"unsupported runner: {runner}"}
