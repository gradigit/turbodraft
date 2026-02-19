#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import select
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
from bench_stats import bootstrap_ci_median, percentile_nearest_rank


SYSTEM_PREAMBLE = """You are TurboDraft, a prompt engineering assistant.

You will be given a draft prompt in Markdown (sometimes messy, unstructured dictation). That draft prompt is intended to be used as input to another AI system.

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
- Do NOT include the draft prompt verbatim in your output.
- Do NOT include <BEGIN_PROMPT>/<END_PROMPT> markers, or prompt-rewriter boilerplate (e.g. "Output Requirements", "Draft Prompt to Rewrite", "DRAFT_PROMPT:").
- Output ONLY the rewritten prompt text (no commentary, no preface, no code fences).
- Preserve the original intent and all critical details.

Handling missing context (VERY IMPORTANT):
- If the draft references inputs you do not have (logs, screenshots, prior chat), do NOT pretend you have them.
- Do NOT write TODO placeholders or bracketed paste instructions (no "[TODO: ...]" and no "TODO: paste ...").
- Do NOT create a section titled "Inputs Needed" / "Inputs Required" / "Needed Inputs".
- Instead, add a section with this exact heading:

## User Inputs to Request

- Bullet items must be phrased as instructions to the downstream agent (the one executing the engineered prompt), e.g.:
  - Ask the user to paste a screenshot of X.
  - Request that the user attach logs for Y.
  - Confirm Z with the user.
- These bullets are NOT instructions for the user to proactively do anything; they are instructions for the agent to ask.

Agent-side reasoning requests:
- If the draft asks for suggestions/options ("what should we do?") OR contains uncertainty ("I don't know", "maybe", "should we..."), add a section with this exact heading:

## Agent Decisions / Recommendations

- List the decisions the agent must make.
- Provide 2-4 options with tradeoffs.
- State what information would change the decision.
- Keep decisions faithful to the draft; do not replace the draft's goals with new goals.

Scope discipline + concision (CRITICAL):
- Do NOT add “good hygiene” requirements unless the draft implies them (e.g., accessibility, visual regression tests, screenshots, documentation updates, refactors).
- If you believe an extra item could be valuable but it is NOT clearly required by the draft, label it explicitly as Optional (prefix the bullet with "Optional:") and keep Optional items to 1-2 bullets max.
- Never remove original requirements to make room for Optional additions.
- Keep the rewrite short and scannable (aim for ~1 page). Avoid repeating the same requirement in multiple sections.
- Only request user inputs that are necessary to proceed; keep "User Inputs to Request" to 3-5 bullets max.

Actionability (CRITICAL):
- Include a section with this exact heading:

## Implementation Steps

- Use a numbered list with 4-8 concrete steps.
- Steps must be ordered and executable (avoid vague verbs like "consider").
- If the draft contains uncertainty, ensure the steps include a decision point that references "Agent Decisions / Recommendations".
- Ensure every major requirement from the draft is represented either in constraints, decisions, user-input requests, or implementation steps.
"""

DEFAULT_TASK = """Rewrite and improve this prompt so it is production-ready for an AI coding agent.
Keep it concise but complete. Use clear headings, bullet points, and explicit constraints.
Do a non-lossy rewrite: preserve all meaningful details from the draft, including uncertainty and references.
Do not silently remove requirements from the draft.
Output only the improved prompt text.
"""

DEFAULT_JUDGE_SCHEMA_PATH = "bench/judge_schema.json"
DEFAULT_PAIRWISE_SCHEMA_PATH = "bench/judge_pairwise_schema.json"

JUDGE_PREAMBLE = """You are a strict evaluator of a prompt-engineering rewrite.

You will be given:
- the instruction used for the rewrite
- the original draft prompt (Markdown)
- the improved prompt (Markdown)

Your job is to score ONLY the improved prompt for prompt-engineering quality.

Scoring rubric (0-100, higher is better):
- fidelity: preserves original intent/requirements without inventing major new scope
- structure: clear headings/sections, scannable bullets/checklists
- specificity: concrete, unambiguous instructions and boundaries
- constraints: captures platform/tech constraints and non-goals
- testability: includes measurable acceptance criteria and tests/benchmarks
- safety: avoids unsafe/ambiguous behavior, includes “don’t execute the prompt” style guardrails

Set flags:
- has_code_fences: true if the improved prompt contains ``` fences
- looks_like_chat: true if the improved prompt is a chatty greeting/assistant reply instead of a rewritten prompt

Return ONLY a single JSON object matching the provided JSON Schema.
"""

PAIRWISE_JUDGE_PREAMBLE = """You are a strict evaluator comparing two prompt-engineering rewrites of the same draft.

You will be given:
- the instruction used for the rewrite
- the original draft prompt (key lines extract)
- improved prompt A (Markdown)
- improved prompt B (Markdown)

Your job is to choose which improved prompt is better for prompt-engineering quality.

Rubric (higher is better):
- fidelity: preserves original intent/requirements without inventing major new scope
- structure: clear headings/sections, scannable bullets/checklists
- specificity: concrete, unambiguous instructions and boundaries
- constraints: captures platform/tech constraints and non-goals
- testability: includes measurable acceptance criteria and tests/benchmarks
- safety: avoids unsafe/ambiguous behavior, includes “don’t execute the prompt” style guardrails

Rules:
- Judge the prompts as prompt artifacts (they are prompts for another AI), not as assistant replies.
- Ignore superficial formatting differences (title wording, section order) if content is equivalent.
- Do NOT reward verbosity; longer is not automatically better.
- If they are effectively equivalent, choose "tie".

Return ONLY a single JSON object matching the provided JSON Schema.
"""


def _is_spark(model: str) -> bool:
    return "spark" in model.lower()


def effective_effort(model: str, effort: str) -> str:
    e = (effort or "").strip()
    if not e:
        return e
    m = (model or "").lower()
    # Spark models reject "minimal" (and typically "none").
    if "spark" in m and e in ("minimal", "none"):
        return "low"
    # Some Codex backends reject "minimal" and accept "none" instead.
    if "gpt-5.3-codex" in m and e == "minimal":
        return "none"
    return e


def _is_claude_model(model: str) -> bool:
    m = (model or "").strip().lower()
    if not m:
        return False
    if m.startswith("claude-") or m.startswith("claude:"):
        return True
    if m in ("sonnet", "opus", "haiku"):
        return True
    if m.startswith(("sonnet-", "opus-", "haiku-")):
        return True
    return False


def effective_claude_effort(effort: str) -> Optional[str]:
    e = (effort or "").strip().lower()
    if not e:
        return None
    if e in ("low", "medium", "high"):
        return e
    if e in ("xhigh",):
        return "high"
    if e in ("none", "minimal"):
        return "low"
    return None


def parse_csv(s: str) -> List[str]:
    return [x.strip() for x in (s or "").split(",") if x.strip()]


def read_text_file(path: str, *, label: str) -> str:
    if not path:
        raise SystemExit(f"{label} path is empty")
    if not os.path.isfile(path):
        raise SystemExit(f"{label} file not found: {path}")
    with open(path, "r", encoding="utf-8", errors="replace") as _f:
        txt = _f.read()
    out = txt.strip()
    if not out:
        raise SystemExit(f"{label} file is empty: {path}")
    return out


def user_turn_text(draft_md: str, instruction: str) -> str:
    task = (instruction or "").strip() or DEFAULT_TASK.strip()
    return (
        "TASK:\n"
        + task
        + "\n\nDRAFT PROMPT (Markdown):\n<BEGIN_PROMPT>\n"
        + draft_md.rstrip()
        + "\n<END_PROMPT>\n"
    )


def exec_stdin_text(draft_md: str, instruction: str) -> str:
    # codex exec uses the entire stdin as the initial instructions (system + user)
    return SYSTEM_PREAMBLE + "\n\n" + user_turn_text(draft_md, instruction)


def parse_json_object(text: str) -> Dict[str, Any]:
    s = (text or "").strip()
    if not s:
        raise ValueError("empty judge output")
    try:
        obj = json.loads(s)
        if isinstance(obj, dict):
            return obj
    except Exception:
        pass

    # Best-effort extraction (in case the model wraps JSON in extra text).
    start = s.find("{")
    end = s.rfind("}")
    if start >= 0 and end > start:
        obj = json.loads(s[start : end + 1])
        if isinstance(obj, dict):
            return obj
    raise ValueError("failed to parse judge JSON")


def markdown_key_lines(md: str, *, max_chars: int = 12_000) -> str:
    lines = (md or "").splitlines()
    head = lines[:40]
    key: List[str] = []
    for ln in lines:
        s = ln.lstrip()
        if not s:
            continue
        if s.startswith("#") or s.startswith(("-", "*")):
            key.append(ln)
            continue
        # numbered lists
        if len(s) >= 2 and s[0].isdigit():
            # cheap check for `1.` / `12.` etc
            i = 0
            while i < len(s) and s[i].isdigit():
                i += 1
            if i < len(s) and s[i : i + 1] == ".":
                key.append(ln)
                continue
        if any(tok in s.lower() for tok in ("acceptance", "deliverable", "constraints", "non-goal", "benchmark", "test")):
            key.append(ln)

    seen = set()
    merged: List[str] = []
    for ln in head + ["", "## Extracted key lines", ""] + key:
        if ln in seen:
            continue
        seen.add(ln)
        merged.append(ln)

    out = "\n".join(merged).strip()
    if len(out) > max_chars:
        out = out[:max_chars].rstrip() + "\n…"
    return out


def percentile(xs: List[float], p: float) -> float:
    v = percentile_nearest_rank(xs, p)
    if v is None:
        return float("nan")
    return float(v)


def summarize_times(xs: List[float]) -> Dict[str, Any]:
    if not xs:
        return {
            "n": 0,
            "min": None,
            "max": None,
            "mean": None,
            "median": None,
            "p95": None,
            "median_ci95_low": None,
            "median_ci95_high": None,
        }
    median_ci95_low, median_ci95_high = bootstrap_ci_median(xs)
    return {
        "n": len(xs),
        "min": min(xs),
        "max": max(xs),
        "mean": (sum(xs) / len(xs)),
        "median": statistics.median(xs),
        "p95": percentile(xs, 0.95),
        "median_ci95_low": median_ci95_low,
        "median_ci95_high": median_ci95_high,
    }


def normalize_engineered_prompt(output: str) -> str:
    lines = (output or "").splitlines()
    out: List[str] = []
    for ln in lines:
        stripped = ln.strip()
        if stripped.startswith("#"):
            i = 0
            while i < len(stripped) and stripped[i] == "#":
                i += 1
            title = stripped[i:].strip().lower()
            if title in {
                "actionable task",
                "actionable tasks",
                "steps",
                "execution steps",
                "implementation plan",
                "implementation task",
                "implementation tasks",
                "task steps",
                "task plan",
            }:
                out.append("## Implementation Steps")
                continue
        out.append(ln)
    return "\n".join(out)


def has_numbered_item(line: str) -> bool:
    s = (line or "").strip()
    if not s:
        return False
    i = 0
    saw_digit = False
    while i < len(s) and s[i].isdigit():
        saw_digit = True
        i += 1
    if not saw_digit:
        return False
    if i >= len(s) or s[i] != ".":
        return False
    i += 1
    if i >= len(s) or not s[i].isspace():
        return False
    return True


def has_actionable_numbered_step_section(lines: List[str]) -> bool:
    in_steps = False
    count = 0
    for ln in lines:
        t = (ln or "").strip()
        if t.startswith("#"):
            i = 0
            while i < len(t) and t[i] == "#":
                i += 1
            title = t[i:].strip().lower()
            in_steps = (title == "implementation steps")
            continue
        if not in_steps:
            continue
        if has_numbered_item(t):
            count += 1
            if count >= 2:
                return True
    return False


def evaluate_output(draft_md: str, improved: str) -> Dict[str, Any]:
    raw_out = (improved or "")
    out = normalize_engineered_prompt(raw_out).strip()
    lines = out.splitlines()
    lc = out.lower()
    raw_lc = raw_out.lower()
    headings = sum(1 for ln in lines if ln.lstrip().startswith("#"))
    bullets = sum(1 for ln in lines if ln.lstrip().startswith(("-", "*")))
    checkboxes = sum(1 for ln in lines if ln.lstrip().startswith(("- [", "* [")))
    fences = out.count("```")

    heading_titles: List[str] = []
    for ln in lines:
        s = ln.lstrip()
        if not s.startswith("#"):
            continue
        title = s.lstrip("#").strip().lower()
        if title:
            heading_titles.append(title)

    raw_heading_titles: List[str] = []
    for ln in (raw_out or "").splitlines():
        s = ln.lstrip()
        if not s.startswith("#"):
            continue
        title = s.lstrip("#").strip().lower()
        if title:
            raw_heading_titles.append(title)

    def has_heading(*keywords: str) -> bool:
        for t in heading_titles:
            for kw in keywords:
                if kw in t:
                    return True
        return False

    def has_any_substring(*keywords: str) -> bool:
        return any(kw in lc for kw in keywords)

    has_acceptance = has_heading("acceptance") or has_any_substring("acceptance criteria", "success criteria")
    has_deliverables = has_heading("deliverable", "output") or has_any_substring("deliverables", "deliverable", "outputs")
    has_non_goals = has_heading("non-goal", "out of scope") or has_any_substring("non-goals", "out of scope")
    has_constraints = has_heading("constraint", "platform", "tech constraints") or has_any_substring("constraints", "platform + tech constraints")
    has_tests = has_heading("test", "testing", "ci") or has_any_substring("unit test", "integration test", "swift test", "ci")
    has_perf = has_heading("performance", "benchmark", "latency") or has_any_substring("benchmark", "latency", "p95")

    looks_like_chat = has_any_substring("how can i help", "how may i help", "what can i help") or lc.startswith(("hi", "hello", "hey"))

    def contains_emoji(s: str) -> bool:
        for ch in s:
            o = ord(ch)
            # common emoji blocks
            if 0x1F300 <= o <= 0x1FAFF:
                return True
            if 0x2600 <= o <= 0x27BF:
                return True
        return False

    has_emoji = contains_emoji(out)

    def collapse_ws(s: str) -> str:
        return " ".join((s or "").split())

    draft_c = collapse_ws(draft_md)
    out_c = collapse_ws(out)
    draft_prefix = draft_c[:220] if len(draft_c) >= 220 else ""

    leaked_system_preamble = "you are turbodraft, a prompt engineering assistant" in lc
    looks_like_prompt_rewriter = any(
        tok in lc
        for tok in (
            "draft prompt to rewrite",
            "rewriting rules",
            "output requirements",
            "draft_prompt:",
        )
    )
    contains_draft_prefix = bool(draft_prefix) and (draft_prefix in out_c)

    uses_inputs_needed_heading = any(
        ("inputs needed" in t) or ("inputs required" in t) or ("needed inputs" in t) for t in heading_titles
    )
    contains_todo_paste_placeholders = (
        ("[todo:" in lc) or ("todo: paste" in lc) or ("todo: attach" in lc) or ("todo: upload" in lc)
    )
    has_exact_implementation_steps_heading = any(t == "implementation steps" for t in raw_heading_titles)
    has_actionable_steps_section = has_actionable_numbered_step_section(lines)

    # Simple 0..100 quality score for comparing runs. This is intentionally heuristic and
    # designed to catch obvious regressions (chatty replies, missing structure, code fences).
    score = 0
    if out:
        score += 15
    if out != (draft_md or "").strip():
        score += 10
    if fences == 0:
        score += 20
    if "<BEGIN_PROMPT>" not in out and "<END_PROMPT>" not in out:
        score += 5

    if headings >= 8:
        score += 10
    elif headings >= 6:
        score += 8
    elif headings >= 4:
        score += 5
    elif headings >= 2:
        score += 2

    if bullets >= 40:
        score += 10
    elif bullets >= 25:
        score += 8
    elif bullets >= 15:
        score += 5
    elif bullets >= 5:
        score += 2

    if has_acceptance:
        score += 10
    if has_deliverables:
        score += 10
    if has_non_goals:
        score += 5
    if has_constraints:
        score += 5
    if has_perf:
        score += 5
    if has_tests:
        score += 5

    if looks_like_chat:
        score -= 10
    if has_emoji:
        score -= 5
    if leaked_system_preamble:
        score -= 35
    if looks_like_prompt_rewriter:
        score -= 45
    if contains_draft_prefix:
        score -= 45
    if uses_inputs_needed_heading:
        score -= 10
    if contains_todo_paste_placeholders:
        score -= 10
    # Soft penalty: exact heading mismatch can be normalized post-process.
    if not has_exact_implementation_steps_heading:
        score -= 4
    # Hard penalty: no actionable numbered steps section at all.
    if not has_actionable_steps_section:
        score -= 35

    score = max(0, min(100, score))

    return {
        "non_empty": bool(out),
        "changed": out != (draft_md or "").strip(),
        "no_code_fences": fences == 0,
        "no_begin_prompt_markers": "<BEGIN_PROMPT>" not in out and "<END_PROMPT>" not in out,
        "looks_like_chat": looks_like_chat,
        "looks_like_prompt_rewriter": looks_like_prompt_rewriter,
        "leaked_system_preamble": leaked_system_preamble,
        "contains_draft_prefix": contains_draft_prefix,
        "uses_inputs_needed_heading": uses_inputs_needed_heading,
        "contains_todo_paste_placeholders": contains_todo_paste_placeholders,
        "has_exact_implementation_steps_heading": has_exact_implementation_steps_heading,
        "has_actionable_numbered_step_section": has_actionable_steps_section,
        "has_emoji": has_emoji,
        "has_acceptance": has_acceptance,
        "has_deliverables": has_deliverables,
        "has_non_goals": has_non_goals,
        "has_constraints": has_constraints,
        "has_tests": has_tests,
        "has_perf": has_perf,
        "quality_score": score,
        "len_chars": len(out),
        "headings": headings,
        "bullets": bullets,
        "checkboxes": checkboxes,
        "code_fence_count": fences,
    }


def summarize_eval(evals: List[Dict[str, Any]]) -> Dict[str, Any]:
    if not evals:
        return {}

    keys = list(evals[0].keys())
    out: Dict[str, Any] = {}
    for k in keys:
        raw = [e.get(k) for e in evals]
        vals = [v for v in raw if v is not None]
        missing = len(raw) - len(vals)
        if not vals:
            out[k] = {"missing": missing, "total": len(raw)}
            continue

        if all(isinstance(v, bool) for v in vals):
            passed = sum(1 for v in vals if v)
            out[k] = {"pass": passed, "total": len(vals), "rate": (passed / len(vals)), "missing": missing}
        elif all(isinstance(v, int) for v in vals):
            v2 = [int(v) for v in vals]
            out[k] = {"median": statistics.median(v2), "p95": percentile([float(x) for x in v2], 0.95), "missing": missing}
        elif all(isinstance(v, (int, float)) for v in vals):
            v2 = [float(v) for v in vals]
            out[k] = {"median": statistics.median(v2), "p95": percentile(v2, 0.95), "missing": missing}
        else:
            out[k] = {"sample": vals[:3], "missing": missing}
    return out


def _to_int_token(x: Any) -> Optional[int]:
    if isinstance(x, bool) or x is None:
        return None
    if isinstance(x, int):
        return x
    if isinstance(x, float):
        return int(x)
    if isinstance(x, str):
        s = x.strip()
        if not s:
            return None
        try:
            if "." in s:
                return int(float(s))
            return int(s)
        except Exception:
            return None
    return None


def _normalize_usage_dict(raw: Any) -> Dict[str, int]:
    if not isinstance(raw, dict):
        return {}

    out: Dict[str, int] = {}

    direct_map = {
        "input_tokens": "input_tokens",
        "output_tokens": "output_tokens",
        "cached_input_tokens": "cached_input_tokens",
        "total_tokens": "total_tokens",
        "reasoning_tokens": "reasoning_tokens",
    }
    for src, dst in direct_map.items():
        v = _to_int_token(raw.get(src))
        if v is not None:
            out[dst] = v

    # API-style usage fields
    if "input_tokens" not in out:
        v = _to_int_token(raw.get("prompt_tokens"))
        if v is not None:
            out["input_tokens"] = v
    if "output_tokens" not in out:
        v = _to_int_token(raw.get("completion_tokens"))
        if v is not None:
            out["output_tokens"] = v

    prompt_details = raw.get("prompt_tokens_details")
    if isinstance(prompt_details, dict):
        if "cached_input_tokens" not in out:
            v = _to_int_token(prompt_details.get("cached_tokens"))
            if v is not None:
                out["cached_input_tokens"] = v

    # App-server tokenUsage shape (camelCase)
    camel_map = {
        "inputTokens": "input_tokens",
        "outputTokens": "output_tokens",
        "cachedInputTokens": "cached_input_tokens",
        "totalTokens": "total_tokens",
        "reasoningOutputTokens": "reasoning_tokens",
    }
    for src, dst in camel_map.items():
        if dst in out:
            continue
        v = _to_int_token(raw.get(src))
        if v is not None:
            out[dst] = v

    return out


def parse_codex_exec_usage(stdout_bytes: bytes) -> Dict[str, int]:
    usage: Dict[str, int] = {}
    for line in (stdout_bytes or b"").splitlines():
        row = line.strip()
        if not row:
            continue
        try:
            obj = json.loads(row.decode("utf-8", "replace"))
        except Exception:
            continue
        if not isinstance(obj, dict):
            continue

        # codex exec --json emits turn.completed with top-level usage
        if obj.get("type") == "turn.completed":
            cand = _normalize_usage_dict(obj.get("usage"))
            if cand:
                usage = cand
            continue

        # fallback if usage appears elsewhere in an event payload
        cand = _normalize_usage_dict(obj.get("usage"))
        if cand:
            usage = cand
    return usage


def parse_codex_exec_agent_message(stdout_bytes: bytes) -> str:
    text = ""
    for line in (stdout_bytes or b"").splitlines():
        row = line.strip()
        if not row:
            continue
        try:
            obj = json.loads(row.decode("utf-8", "replace"))
        except Exception:
            continue
        if not isinstance(obj, dict):
            continue

        if obj.get("type") == "item.completed":
            item = obj.get("item")
            if isinstance(item, dict) and item.get("type") == "agent_message":
                t = item.get("text")
                if isinstance(t, str) and t.strip():
                    text = t
    return text


def attach_usage_metrics(eval_row: Dict[str, Any], usage: Optional[Dict[str, int]]) -> None:
    eval_row["input_tokens"] = None
    eval_row["cached_input_tokens"] = None
    eval_row["output_tokens"] = None
    eval_row["total_tokens"] = None
    eval_row["reasoning_tokens"] = None
    eval_row["prompt_cache_hit"] = None
    eval_row["cached_input_ratio"] = None

    if not usage:
        return

    for k in ("input_tokens", "cached_input_tokens", "output_tokens", "total_tokens", "reasoning_tokens"):
        v = _to_int_token(usage.get(k))
        if v is not None:
            eval_row[k] = v

    it = _to_int_token(usage.get("input_tokens"))
    ct = _to_int_token(usage.get("cached_input_tokens"))
    if ct is not None:
        eval_row["prompt_cache_hit"] = (ct > 0)
    if it is not None and it > 0 and ct is not None:
        eval_row["cached_input_ratio"] = float(ct) / float(it)


def run_codex_exec(
    *,
    model: str,
    effort: str,
    summary: str,
    web_search: str,
    prompt_stdin: str,
    timeout_s: float,
    ephemeral: bool,
    verbose: bool,
) -> Tuple[float, str, Dict[str, int]]:
    with tempfile.NamedTemporaryFile(prefix="turbodraft-codex-exec-", suffix=".txt", delete=False) as f:
        out_path = f.name

    try:
        eff = effective_effort(model, effort)
        cmd = [
            "codex",
            "exec",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--json",
            "--output-last-message",
            out_path,
            "--model",
            model,
            "-c",
            "approval=never",
            "-c",
            f"web_search={web_search}",
            "-c",
            f"model_reasoning_effort={eff}",
            "-c",
            f"model_reasoning_summary={summary}",
        ]
        if ephemeral:
            cmd.insert(2, "--ephemeral")
        cmd.append("-")

        last_err: Optional[str] = None
        for attempt in range(6):
            try:
                t0 = time.perf_counter()
                p = subprocess.run(
                    cmd,
                    input=prompt_stdin.encode("utf-8"),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=timeout_s,
                )
                dt = time.perf_counter() - t0
            except subprocess.TimeoutExpired:
                last_err = f"timeout after {timeout_s}s"
                if attempt < 5:
                    time.sleep(min(3.0, 0.75 * (attempt + 1)))
                    continue
                raise RuntimeError(f"codex exec failed {last_err}")

            if verbose:
                if p.stdout:
                    try:
                        os.write(2, p.stdout)
                    except Exception:
                        pass
                if p.stderr:
                    try:
                        os.write(2, p.stderr)
                    except Exception:
                        pass

            usage = parse_codex_exec_usage(p.stdout or b"")
            with open(out_path, "r", encoding="utf-8", errors="replace") as _f:
                improved = _f.read()
            if not (improved or "").strip():
                improved = parse_codex_exec_agent_message(p.stdout or b"")

            if p.returncode == 0 and (improved or "").strip():
                usage = parse_codex_exec_usage(p.stdout or b"")
                return dt, improved, usage

            # Some Codex CLI runs may return non-zero while still producing a usable final message.
            if p.returncode != 0 and (improved or "").strip():
                return dt, improved, usage

            err_tail = (p.stderr or b"").decode("utf-8", "replace")[-600:].strip()
            last_err = f"rc={p.returncode} err={err_tail}" if err_tail else f"rc={p.returncode}"
            if attempt < 5:
                time.sleep(min(3.0, 0.75 * (attempt + 1)))
                continue

        raise RuntimeError(f"codex exec failed {last_err or 'unknown'}")
    finally:
        try:
            os.unlink(out_path)
        except Exception:
            pass


def run_claude_print(
    *,
    model: str,
    effort: str,
    system_prompt: str,
    user_prompt: str,
    timeout_s: float,
    verbose: bool,
) -> Tuple[float, str]:
    eff = effective_claude_effort(effort)
    if eff is None:
        raise RuntimeError(f"unsupported claude effort: {effort}")

    cmd = [
        "claude",
        "-p",
        "--model",
        model,
        "--effort",
        eff,
        "--tools",
        "",
        "--no-session-persistence",
        "--output-format",
        "text",
        "--system-prompt",
        system_prompt,
    ]

    t0 = time.perf_counter()
    p = subprocess.run(
        cmd,
        input=user_prompt.encode("utf-8"),
        stdout=None if verbose else subprocess.PIPE,
        stderr=None if verbose else subprocess.PIPE,
        timeout=timeout_s,
    )
    dt = time.perf_counter() - t0
    if p.returncode != 0:
        err = ""
        if isinstance(p.stderr, (bytes, bytearray)):
            err = p.stderr.decode("utf-8", "replace")
        raise RuntimeError(f"claude print failed rc={p.returncode} {err[-400:]}".strip())
    if verbose:
        # When verbose, stdout is inherited; we can't capture reliably. Use empty string to avoid crashing.
        return dt, ""
    assert p.stdout is not None
    improved = p.stdout.decode("utf-8", "replace")
    return dt, improved


def run_codex_judge_exec(
    *,
    judge_model: str,
    judge_effort: str,
    judge_summary: str,
    draft_md: str,
    improved_md: str,
    instruction: str,
    timeout_s: float,
    schema_path: str,
    verbose: bool,
) -> Tuple[float, Dict[str, Any]]:
    with tempfile.NamedTemporaryFile(prefix="turbodraft-codex-judge-", suffix=".json", delete=False) as f:
        out_path = f.name

    try:
        eff = effective_effort(judge_model, judge_effort)
        cmd = [
            "codex",
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--output-last-message",
            out_path,
            "--output-schema",
            schema_path,
            "--model",
            judge_model,
            "-c",
            "approval=never",
            "-c",
            "web_search=disabled",
            "-c",
            f"model_reasoning_effort={eff}",
            "-c",
            f"model_reasoning_summary={judge_summary}",
            "-",
        ]

        draft_excerpt = markdown_key_lines(draft_md)
        improved_excerpt = (improved_md or "").rstrip()
        if len(improved_excerpt) > 24_000:
            improved_excerpt = improved_excerpt[:24_000].rstrip() + "\n…"

        judge_prompt = (
            JUDGE_PREAMBLE
            + "\n\nINSTRUCTION:\n"
            + (instruction.strip() or DEFAULT_TASK.strip())
            + "\n\nDRAFT PROMPT (key lines extract):\n<BEGIN_DRAFT>\n"
            + draft_excerpt
            + "\n<END_DRAFT>\n\nIMPROVED PROMPT (Markdown):\n<BEGIN_IMPROVED>\n"
            + improved_excerpt
            + "\n<END_IMPROVED>\n"
        )

        t0 = time.perf_counter()
        p = subprocess.run(
            cmd,
            input=judge_prompt.encode("utf-8"),
            stdout=None if verbose else subprocess.DEVNULL,
            stderr=None if verbose else subprocess.DEVNULL,
            timeout=timeout_s,
        )
        dt = time.perf_counter() - t0
        if p.returncode != 0:
            raise RuntimeError(f"codex judge failed rc={p.returncode}")

        with open(out_path, "r", encoding="utf-8", errors="replace") as _f:
            raw = _f.read()
        obj = parse_json_object(raw)
        return dt, obj
    finally:
        try:
            os.unlink(out_path)
        except Exception:
            pass


def run_codex_pairwise_judge_exec(
    *,
    judge_model: str,
    judge_effort: str,
    judge_summary: str,
    draft_md: str,
    a_md: str,
    b_md: str,
    instruction: str,
    timeout_s: float,
    schema_path: str,
    verbose: bool,
) -> Tuple[float, Dict[str, Any]]:
    with tempfile.NamedTemporaryFile(prefix="turbodraft-codex-judge-pairwise-", suffix=".json", delete=False) as f:
        out_path = f.name

    try:
        eff = effective_effort(judge_model, judge_effort)
        cmd = [
            "codex",
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--output-last-message",
            out_path,
            "--output-schema",
            schema_path,
            "--model",
            judge_model,
            "-c",
            "approval=never",
            "-c",
            "web_search=disabled",
            "-c",
            f"model_reasoning_effort={eff}",
            "-c",
            f"model_reasoning_summary={judge_summary}",
            "-",
        ]

        draft_excerpt = markdown_key_lines(draft_md)

        a_excerpt = (a_md or "").rstrip()
        if len(a_excerpt) > 24_000:
            a_excerpt = a_excerpt[:24_000].rstrip() + "\n…"

        b_excerpt = (b_md or "").rstrip()
        if len(b_excerpt) > 24_000:
            b_excerpt = b_excerpt[:24_000].rstrip() + "\n…"

        judge_prompt = (
            PAIRWISE_JUDGE_PREAMBLE
            + "\n\nINSTRUCTION:\n"
            + (instruction.strip() or DEFAULT_TASK.strip())
            + "\n\nDRAFT PROMPT (key lines extract):\n<BEGIN_DRAFT>\n"
            + draft_excerpt
            + "\n<END_DRAFT>\n\nPROMPT A (Markdown):\n<BEGIN_A>\n"
            + a_excerpt
            + "\n<END_A>\n\nPROMPT B (Markdown):\n<BEGIN_B>\n"
            + b_excerpt
            + "\n<END_B>\n"
        )

        t0 = time.perf_counter()
        p = subprocess.run(
            cmd,
            input=judge_prompt.encode("utf-8"),
            stdout=None if verbose else subprocess.DEVNULL,
            stderr=None if verbose else subprocess.DEVNULL,
            timeout=timeout_s,
        )
        dt = time.perf_counter() - t0
        if p.returncode != 0:
            raise RuntimeError(f"codex pairwise judge failed rc={p.returncode}")

        with open(out_path, "r", encoding="utf-8", errors="replace") as _f:
            raw = _f.read()
        obj = parse_json_object(raw)
        return dt, obj
    finally:
        try:
            os.unlink(out_path)
        except Exception:
            pass


class JsonLinesReader:
    def __init__(self, stream) -> None:
        self._fd = stream.fileno()
        self._buf = bytearray()

    def read(self, timeout_s: float) -> Optional[Dict[str, Any]]:
        deadline = time.time() + timeout_s
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line = bytes(self._buf[:nl]).strip()
                del self._buf[: nl + 1]
                if not line:
                    continue
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


def _as_int_id(x: Any) -> Optional[int]:
    if x is None:
        return None
    if isinstance(x, bool):
        return int(x)
    if isinstance(x, int):
        return x
    if isinstance(x, float):
        return int(x)
    if isinstance(x, str):
        try:
            return int(x)
        except Exception:
            return None
    return None


class AppServerConn:
    def __init__(self, p: subprocess.Popen, reader: JsonLinesReader) -> None:
        self.p = p
        self.reader = reader
        self._next_id = 1
        self._backlog: List[Dict[str, Any]] = []
        self._initialized = False

    def send(self, method: str, params: Any) -> int:
        rid = self._next_id
        self._next_id += 1
        msg = {"id": rid, "method": method, "params": params}
        data = json.dumps(msg, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        assert self.p.stdin is not None
        self.p.stdin.write(data)
        self.p.stdin.flush()
        return rid

    def notify(self, method: str, params: Any = None) -> None:
        msg: Dict[str, Any] = {"method": method}
        if params is not None:
            msg["params"] = params
        data = json.dumps(msg, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        assert self.p.stdin is not None
        self.p.stdin.write(data)
        self.p.stdin.flush()

    def read_message(self, timeout_s: float) -> Optional[Dict[str, Any]]:
        if self._backlog:
            return self._backlog.pop(0)
        return self.reader.read(timeout_s)

    def wait_response(self, rid: int, timeout_s: float) -> Dict[str, Any]:
        # While waiting for a response, we must not re-queue backlog notifications back into the
        # backlog (it can create an infinite pop+append loop). Instead, temporarily defer any
        # notifications we see and restore them afterwards.
        deferred = list(self._backlog)
        self._backlog.clear()

        deadline = time.time() + timeout_s
        try:
            while True:
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise TimeoutError(f"timeout waiting for response id={rid}")
                msg = self.reader.read(timeout_s=min(0.5, remaining))
                if msg is None:
                    continue
                if msg.get("_eof"):
                    raise RuntimeError("codex app-server stdout closed")

                mid = _as_int_id(msg.get("id"))
                if mid is not None:
                    if mid == rid:
                        return msg
                    continue

                if isinstance(msg.get("method"), str):
                    deferred.append(msg)
        finally:
            # Put deferred notifications back at the front of the backlog so streaming can see them.
            if deferred:
                self._backlog[:0] = deferred

    def initialize(self, timeout_s: float = 30.0) -> None:
        if self._initialized:
            return
        rid = self.send(
            "initialize",
            {
                "protocolVersion": "2025-02-14",
                "clientInfo": {"name": "turbodraft-bench", "version": "0.1.0"},
            },
        )
        resp = self.wait_response(rid, timeout_s=timeout_s)
        if isinstance(resp.get("error"), dict):
            err = resp["error"]
            msg = str(err.get("message") or "")
            if "Already initialized" in msg:
                self._initialized = True
                return
            raise RuntimeError(f"app-server initialize failed: {err}")
        self.notify("notifications/initialized", {})
        self._initialized = True


def start_app_server(web_search: str, verbose: bool) -> subprocess.Popen:
    cmd = [
        "codex",
        "app-server",
        "--listen",
        "stdio://",
        "-c",
        "approval=never",
        "-c",
        f"web_search={web_search}",
    ]

    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=False)
    if p.stdin is None or p.stdout is None:
        raise RuntimeError("failed to spawn codex app-server")

    def drain():
        if p.stderr is None:
            return
        for line in iter(lambda: p.stderr.readline(), b""):
            if not verbose:
                continue
            try:
                os.write(2, line)
            except Exception:
                pass

    threading.Thread(target=drain, daemon=True).start()
    return p


def run_app_server_turn(
    *,
    conn: AppServerConn,
    model: str,
    effort: str,
    summary: str,
    draft_md: str,
    instruction: str,
    timeout_s: float,
) -> Tuple[float, str, Dict[str, int]]:
    conn.initialize(timeout_s=min(30.0, timeout_s))
    cwd = os.getcwd()
    thread_params: Dict[str, Any] = {
        "model": model,
        "modelProvider": "openai",
        "approvalPolicy": "never",
        "sandbox": "read-only",
        "ephemeral": True,
        "cwd": cwd,
        "baseInstructions": SYSTEM_PREAMBLE,
        "developerInstructions": SYSTEM_PREAMBLE,
        "personality": "pragmatic",
    }

    t0 = time.perf_counter()

    thread_rid = conn.send("thread/start", thread_params)
    thread_resp = conn.wait_response(thread_rid, timeout_s=30.0)
    thread_id = (((thread_resp.get("result") or {}).get("thread") or {}).get("id") or "")
    if not isinstance(thread_id, str) or not thread_id:
        raise RuntimeError("thread/start missing thread.id")

    turn_params: Dict[str, Any] = {
        "threadId": thread_id,
        "input": [{"type": "text", "text": user_turn_text(draft_md, instruction)}],
    }
    if effort:
        turn_params["effort"] = effective_effort(model, effort)
    if summary:
        turn_params["summary"] = summary

    turn_rid = conn.send("turn/start", turn_params)
    turn_resp = conn.wait_response(turn_rid, timeout_s=30.0)
    turn_id = (((turn_resp.get("result") or {}).get("turn") or {}).get("id") or "")
    if not isinstance(turn_id, str) or not turn_id:
        raise RuntimeError("turn/start missing turn.id")

    deadline = time.time() + timeout_s
    agent_text = ""
    saw_final = False
    turn_usage: Dict[str, int] = {}

    while time.time() < deadline:
        msg = conn.read_message(timeout_s=0.5)
        if msg is None:
            continue
        if msg.get("_eof"):
            raise RuntimeError("codex app-server stdout closed")

        method = msg.get("method")
        params = msg.get("params")
        if not isinstance(method, str) or not isinstance(params, dict):
            continue

        if method == "item/agentMessage/delta":
            if params.get("turnId") == turn_id and not saw_final:
                delta = params.get("delta")
                if isinstance(delta, str) and delta:
                    agent_text += delta
            continue

        if method == "item/completed":
            if params.get("turnId") == turn_id:
                item = params.get("item")
                if isinstance(item, dict) and item.get("type") == "agentMessage":
                    text = item.get("text")
                    if isinstance(text, str):
                        agent_text = text
                        saw_final = True
            continue

        if method == "thread/tokenUsage/updated":
            if params.get("turnId") != turn_id:
                continue
            usage_block = params.get("tokenUsage")
            if isinstance(usage_block, dict):
                for cand in (
                    usage_block.get("total"),
                    usage_block.get("last"),
                    usage_block,
                ):
                    norm = _normalize_usage_dict(cand)
                    if norm:
                        turn_usage = norm
                        break
            continue

        if method == "error":
            if params.get("turnId") == turn_id:
                if params.get("willRetry") is True:
                    continue
                raise RuntimeError(f"app-server error: {params.get('error')}")
            continue

        if method == "turn/completed":
            if params.get("threadId") != thread_id:
                continue
            turn = params.get("turn")
            if not isinstance(turn, dict) or turn.get("id") != turn_id:
                continue
            status = turn.get("status")
            if status != "completed":
                raise RuntimeError(f"turn status={status} error={turn.get('error')}")

            for cand in (
                params.get("usage"),
                turn.get("usage"),
                turn.get("tokenUsage"),
                turn.get("token_usage"),
            ):
                norm = _normalize_usage_dict(cand)
                if norm:
                    turn_usage = norm
                    break

            improved = agent_text.strip()
            if not improved:
                raise RuntimeError("missing agent message")
            dt = time.perf_counter() - t0
            return dt, improved, turn_usage

    raise TimeoutError("timed out waiting for app-server turn")


@dataclass
class CaseResult:
    draft_path: str
    draft_len_chars: int
    model: str
    effort: str
    exec_times_s: List[float]
    app_warm_times_s: List[float]
    exec_eval: List[Dict[str, Any]]
    app_eval: List[Dict[str, Any]]

    def to_json(self) -> Dict[str, Any]:
        return {
            "draft_path": self.draft_path,
            "draft_len_chars": self.draft_len_chars,
            "model": self.model,
            "effort": self.effort,
            "exec": {"times_s": self.exec_times_s, "stats": summarize_times(self.exec_times_s), "eval": summarize_eval(self.exec_eval)},
            "app_server_warm": {"times_s": self.app_warm_times_s, "stats": summarize_times(self.app_warm_times_s), "eval": summarize_eval(self.app_eval)},
        }


def main() -> int:
    ap = argparse.ArgumentParser(description="Benchmark codex exec vs codex app-server for TurboDraft prompt-engineering.")
    ap.add_argument("--draft", default="bench/fixtures/dictation_flush_mode.md", help="Path to markdown draft prompt fixture")
    ap.add_argument("--drafts", default="", help="Comma-separated list of draft fixture paths (overrides --draft)")
    ap.add_argument("--instruction", default=DEFAULT_TASK.strip(), help="Instruction given to the prompt engineer")
    ap.add_argument("--system-preamble-file", default="", help="Optional path to override the built-in system preamble text")
    ap.add_argument("--models", default="gpt-5.3-codex-spark,gpt-5.3-codex", help="Comma-separated model ids")
    ap.add_argument("--efforts", default="minimal,low,medium,high,xhigh", help="Comma-separated reasoning efforts")
    ap.add_argument("--summary", default="auto", choices=["auto", "concise", "detailed", "none"], help="Reasoning summary setting")
    ap.add_argument("--web-search", default="disabled", choices=["disabled", "cached", "live"], help="Web search mode")
    ap.add_argument("-n", type=int, default=9, help="Iterations per (model,effort) per backend")
    ap.add_argument("--timeout", type=float, default=120.0, help="Timeout per run in seconds")
    ap.add_argument("--backend", default="both", choices=["both", "exec", "app-server"], help="Which backend(s) to run")
    ap.add_argument("--no-ephemeral", action="store_true", help="Disable --ephemeral for codex exec")
    ap.add_argument("--quality-min", type=int, default=70, help="Minimum heuristic quality score (0-100) to count as passing")
    ap.add_argument("--save-outputs", default="", help="If set, write each improved output to this directory for manual inspection")
    ap.add_argument("--judge-model", default="", help="If set, run a model-as-judge pass using codex exec (e.g. gpt-5.3-codex)")
    ap.add_argument("--judge-effort", default="xhigh", help="Judge reasoning effort (default: xhigh)")
    ap.add_argument("--judge-summary", default="auto", choices=["auto", "concise", "detailed", "none"], help="Judge reasoning summary setting")
    ap.add_argument("--judge-n", type=int, default=1, help="Number of outputs per (model,effort,backend) to judge (default: 1)")
    ap.add_argument("--judge-min", type=int, default=80, help="Judge overall score threshold to count as passing (default: 80)")
    ap.add_argument("--judge-timeout", type=float, default=240.0, help="Judge timeout per run in seconds")
    ap.add_argument("--judge-schema", default=DEFAULT_JUDGE_SCHEMA_PATH, help="Path to JSON schema file for judge structured output")
    ap.add_argument("--pairwise", action="store_true", help="Enable pairwise A/B judging against a baseline (per draft/backend)")
    ap.add_argument("--pairwise-model", default="", help="Pairwise judge model (defaults to --judge-model if set)")
    ap.add_argument("--pairwise-effort", default="xhigh", help="Pairwise judge reasoning effort (default: xhigh)")
    ap.add_argument("--pairwise-summary", default="auto", choices=["auto", "concise", "detailed", "none"], help="Pairwise judge reasoning summary setting")
    ap.add_argument("--pairwise-n", type=int, default=1, help="Number of outputs per (model,effort,backend) to pairwise judge (default: 1)")
    ap.add_argument("--pairwise-timeout", type=float, default=240.0, help="Pairwise judge timeout per comparison in seconds")
    ap.add_argument("--pairwise-schema", default=DEFAULT_PAIRWISE_SCHEMA_PATH, help="Path to JSON schema file for pairwise judge structured output")
    ap.add_argument("--pairwise-baseline-model", default="", help="Baseline model id for pairwise comparisons (optional)")
    ap.add_argument("--pairwise-baseline-effort", default="", help="Baseline effort for pairwise comparisons (optional)")
    ap.add_argument("--pairwise-baseline-file", default="", help="Baseline markdown file to compare against (single draft; overrides baseline selection)")
    ap.add_argument("--pairwise-baseline-dir", default="", help="Directory of baseline markdown files keyed by draft filename (overrides baseline selection)")
    ap.add_argument("--pairwise-seed", default="turbodraft", help="Seed for deterministic A/B order randomization")
    ap.add_argument("--json-out", default="", help="Write JSON results to this path")
    ap.add_argument("--verbose", action="store_true", help="Show codex stdout/stderr")

    args = ap.parse_args()
    if args.n < 5:
        print("warning: -n < 5 is noisy for p95; use >= 5 for objective comparisons", file=sys.stderr)

    system_preamble_source = "builtin"
    if args.system_preamble_file:
        global SYSTEM_PREAMBLE
        SYSTEM_PREAMBLE = read_text_file(args.system_preamble_file, label="system preamble")
        system_preamble_source = os.path.abspath(args.system_preamble_file)
    system_preamble_sha256 = hashlib.sha256(SYSTEM_PREAMBLE.encode("utf-8")).hexdigest()

    pairwise_enabled = bool(args.pairwise)
    pairwise_model = (args.pairwise_model or args.judge_model or "").strip()
    if pairwise_enabled and not pairwise_model:
        raise SystemExit("--pairwise requires --pairwise-model or --judge-model")
    pairwise_n = max(0, int(args.pairwise_n))
    if pairwise_enabled and pairwise_n <= 0:
        raise SystemExit("--pairwise-n must be >= 1 when --pairwise is enabled")

    pairwise_baseline_file = (args.pairwise_baseline_file or "").strip()
    pairwise_baseline_dir = (args.pairwise_baseline_dir or "").strip()
    if pairwise_enabled and pairwise_baseline_file and pairwise_baseline_dir:
        raise SystemExit("use only one of --pairwise-baseline-file or --pairwise-baseline-dir")

    draft_paths = parse_csv(args.drafts) if args.drafts else []
    if not draft_paths:
        draft_paths = [args.draft]
    draft_paths = [p for p in draft_paths if p]
    if not draft_paths:
        raise SystemExit("no draft fixtures provided")

    if pairwise_enabled and pairwise_baseline_file and len(draft_paths) != 1:
        raise SystemExit("--pairwise-baseline-file requires exactly one draft (use --draft, not --drafts)")
    if pairwise_enabled and pairwise_baseline_dir and not os.path.isdir(pairwise_baseline_dir):
        raise SystemExit(f"--pairwise-baseline-dir not found: {pairwise_baseline_dir}")

    if args.save_outputs:
        os.makedirs(args.save_outputs, exist_ok=True)

    def safe_name(s: str) -> str:
        return "".join(ch if (ch.isalnum() or ch in "-._") else "_" for ch in s)

    models = parse_csv(args.models)
    efforts = parse_csv(args.efforts)
    matrix: List[Tuple[str, str]] = []
    for m in models:
        for e in efforts:
            if _is_claude_model(m):
                ce = effective_claude_effort(e)
                if ce is None:
                    continue
                matrix.append((m, ce))
            else:
                if _is_spark(m) and e == "minimal":
                    continue
                matrix.append((m, e))

    if not matrix:
        raise SystemExit("empty matrix")

    run_exec = args.backend in ("both", "exec")
    run_app = args.backend in ("both", "app-server")

    app_proc: Optional[subprocess.Popen] = None
    conn: Optional[AppServerConn] = None
    app_startup_s: Optional[float] = None

    try:
        need_app_server = run_app and any(not _is_claude_model(m) for (m, _) in matrix)
        if need_app_server:
            t0 = time.perf_counter()
            app_proc = start_app_server(args.web_search, verbose=args.verbose)
            assert app_proc.stdout is not None
            reader = JsonLinesReader(app_proc.stdout)
            conn = AppServerConn(app_proc, reader)

            init_rid = conn.send(
                "initialize",
                {"clientInfo": {"name": "TurboDraftBench", "version": "0.0.0"}, "capabilities": {"experimentalApi": True}},
            )
            init_resp = conn.wait_response(init_rid, timeout_s=10.0)
            if "error" in init_resp:
                raise RuntimeError(f"initialize failed: {init_resp['error']}")
            app_startup_s = time.perf_counter() - t0

        results: List[CaseResult] = []
        for draft_path in draft_paths:
            with open(draft_path, "r", encoding="utf-8", errors="replace") as _f:
                draft_md = _f.read()
            draft_len = len((draft_md or "").strip())
            draft_key = safe_name(os.path.basename(draft_path))

            baseline_source = "run"
            baseline_path = ""
            baseline_text: Optional[str] = None
            if pairwise_enabled and pairwise_baseline_file:
                baseline_source = "file"
                baseline_path = pairwise_baseline_file
            elif pairwise_enabled and pairwise_baseline_dir:
                baseline_source = "dir"
                baseline_path = os.path.join(pairwise_baseline_dir, os.path.basename(draft_path))

            if pairwise_enabled and baseline_path:
                if not os.path.isfile(baseline_path):
                    raise SystemExit(f"pairwise baseline missing for draft {draft_path}: {baseline_path}")
                with open(baseline_path, "r", encoding="utf-8", errors="replace") as _f:
                    baseline_text = _f.read().strip()
                if not baseline_text:
                    raise SystemExit(f"pairwise baseline is empty: {baseline_path}")

            pw_exec_outputs: Dict[Tuple[str, str], List[str]] = {}
            pw_app_outputs: Dict[Tuple[str, str], List[str]] = {}
            pw_exec_evals: Dict[Tuple[str, str], List[Dict[str, Any]]] = {}
            pw_app_evals: Dict[Tuple[str, str], List[Dict[str, Any]]] = {}

            for model, effort in matrix:
                exec_times: List[float] = []
                app_times: List[float] = []
                exec_eval: List[Dict[str, Any]] = []
                app_eval: List[Dict[str, Any]] = []

                if run_exec:
                    for i in range(max(0, args.n)):
                        usage: Dict[str, int] = {}
                        if _is_claude_model(model):
                            dt, improved = run_claude_print(
                                model=model,
                                effort=effort,
                                system_prompt=SYSTEM_PREAMBLE,
                                user_prompt=user_turn_text(draft_md, args.instruction),
                                timeout_s=args.timeout,
                                verbose=args.verbose,
                            )
                        else:
                            dt, improved, usage = run_codex_exec(
                                model=model,
                                effort=effort,
                                summary=args.summary,
                                web_search=args.web_search,
                                prompt_stdin=exec_stdin_text(draft_md, args.instruction),
                                timeout_s=args.timeout,
                                ephemeral=not args.no_ephemeral,
                                verbose=args.verbose,
                            )
                        improved_final = normalize_engineered_prompt(improved)
                        exec_times.append(dt)
                        e = evaluate_output(draft_md, improved)
                        e["draft_path"] = draft_path
                        e["quality_pass"] = (
                            int(e.get("quality_score") or 0) >= int(args.quality_min)
                            and bool(e.get("has_actionable_numbered_step_section"))
                        )
                        attach_usage_metrics(e, usage)
                        if pairwise_enabled and i < pairwise_n:
                            pw_exec_outputs.setdefault((model, effort), []).append(improved_final)
                        if args.judge_model and i < max(0, args.judge_n):
                            try:
                                jdt, jobj = run_codex_judge_exec(
                                    judge_model=args.judge_model,
                                    judge_effort=args.judge_effort,
                                    judge_summary=args.judge_summary,
                                    draft_md=draft_md,
                                    improved_md=improved_final,
                                    instruction=args.instruction,
                                    timeout_s=args.judge_timeout,
                                    schema_path=args.judge_schema,
                                    verbose=args.verbose,
                                )
                                e["judge_latency_s"] = jdt
                                for k in ("overall", "fidelity", "structure", "specificity", "constraints", "testability", "safety"):
                                    if k in jobj:
                                        try:
                                            e[f"judge_{k}"] = int(jobj[k])
                                        except Exception:
                                            e[f"judge_{k}"] = None
                                for k in ("has_code_fences", "looks_like_chat"):
                                    if k in jobj:
                                        e[f"judge_{k}"] = bool(jobj[k])
                                j_overall = e.get("judge_overall")
                                if isinstance(j_overall, int):
                                    e["judge_pass"] = (j_overall >= int(args.judge_min))
                            except Exception as ex:
                                e["judge_error"] = str(ex)
                        exec_eval.append(e)
                        if args.save_outputs:
                            path = os.path.join(
                                args.save_outputs,
                                f"exec__{draft_key}__{safe_name(model)}__{safe_name(effort)}__{i+1}.md",
                            )
                            with open(path, "w", encoding="utf-8") as f:
                                f.write(improved_final)

                if need_app_server and not _is_claude_model(model):
                    assert conn is not None
                    for i in range(max(0, args.n)):
                        dt, improved, usage = run_app_server_turn(
                            conn=conn,
                            model=model,
                            effort=effort,
                            summary=args.summary,
                            draft_md=draft_md,
                            instruction=args.instruction,
                            timeout_s=args.timeout,
                        )
                        improved_final = normalize_engineered_prompt(improved)
                        app_times.append(dt)
                        e = evaluate_output(draft_md, improved)
                        e["draft_path"] = draft_path
                        e["quality_pass"] = (
                            int(e.get("quality_score") or 0) >= int(args.quality_min)
                            and bool(e.get("has_actionable_numbered_step_section"))
                        )
                        attach_usage_metrics(e, usage)
                        if pairwise_enabled and i < pairwise_n:
                            pw_app_outputs.setdefault((model, effort), []).append(improved_final)
                        if args.judge_model and i < max(0, args.judge_n):
                            try:
                                jdt, jobj = run_codex_judge_exec(
                                    judge_model=args.judge_model,
                                    judge_effort=args.judge_effort,
                                    judge_summary=args.judge_summary,
                                    draft_md=draft_md,
                                    improved_md=improved_final,
                                    instruction=args.instruction,
                                    timeout_s=args.judge_timeout,
                                    schema_path=args.judge_schema,
                                    verbose=args.verbose,
                                )
                                e["judge_latency_s"] = jdt
                                for k in ("overall", "fidelity", "structure", "specificity", "constraints", "testability", "safety"):
                                    if k in jobj:
                                        try:
                                            e[f"judge_{k}"] = int(jobj[k])
                                        except Exception:
                                            e[f"judge_{k}"] = None
                                for k in ("has_code_fences", "looks_like_chat"):
                                    if k in jobj:
                                        e[f"judge_{k}"] = bool(jobj[k])
                                j_overall = e.get("judge_overall")
                                if isinstance(j_overall, int):
                                    e["judge_pass"] = (j_overall >= int(args.judge_min))
                            except Exception as ex:
                                e["judge_error"] = str(ex)
                        app_eval.append(e)
                        if args.save_outputs:
                            path = os.path.join(
                                args.save_outputs,
                                f"app_server_warm__{draft_key}__{safe_name(model)}__{safe_name(effort)}__{i+1}.md",
                            )
                            with open(path, "w", encoding="utf-8") as f:
                                f.write(improved_final)

                pw_exec_evals[(model, effort)] = exec_eval
                pw_app_evals[(model, effort)] = app_eval

                results.append(
                    CaseResult(
                        draft_path=draft_path,
                        draft_len_chars=draft_len,
                        model=model,
                        effort=effort,
                        exec_times_s=exec_times,
                        app_warm_times_s=app_times,
                        exec_eval=exec_eval,
                        app_eval=app_eval,
                    )
                )

            def effort_rank(e: str) -> int:
                order = {"none": 0, "minimal": 1, "low": 2, "medium": 3, "high": 4, "xhigh": 5}
                return int(order.get((e or "").strip().lower(), -1))

            def model_pref(m: str) -> int:
                ml = (m or "").lower()
                if "gpt-5.3-codex" in ml and "spark" not in ml:
                    return 3
                if "spark" in ml:
                    return 2
                if ("claude" in ml) or ("sonnet" in ml) or ("opus" in ml) or ("haiku" in ml):
                    return 1
                return 0

            def pick_baseline(keys: List[Tuple[str, str]]) -> Optional[Tuple[str, str]]:
                if not keys:
                    return None
                bm = (args.pairwise_baseline_model or "").strip()
                be = (args.pairwise_baseline_effort or "").strip()
                if bm:
                    cands = [k for k in keys if k[0] == bm and (not be or k[1] == be)]
                    if cands:
                        return max(cands, key=lambda k: (effort_rank(k[1]), model_pref(k[0]), k[0], k[1]))
                return max(keys, key=lambda k: (effort_rank(k[1]), model_pref(k[0]), k[0], k[1]))

            def stable_swap(seed: str, *parts: str) -> bool:
                s = (seed or "") + "|" + "|".join(parts)
                h = hashlib.sha256(s.encode("utf-8", "replace")).digest()
                return bool(h[0] & 1)

            def apply_pairwise(backend: str, outputs: Dict[Tuple[str, str], List[str]], evals: Dict[Tuple[str, str], List[Dict[str, Any]]]) -> None:
                if not pairwise_enabled:
                    return
                if not outputs:
                    return
                baseline_key: Optional[Tuple[str, str]] = None
                base_outs: List[str] = []
                if baseline_text is not None:
                    base_outs = [baseline_text] * max(1, pairwise_n)
                else:
                    baseline_key = pick_baseline(list(outputs.keys()))
                    if baseline_key is None:
                        return
                    base_outs = outputs.get(baseline_key) or []
                for key, outs in outputs.items():
                    ev_list = evals.get(key) or []
                    for i in range(min(pairwise_n, len(ev_list), len(outs))):
                        d = ev_list[i]
                        d["pairwise_backend"] = backend
                        d["pairwise_baseline_source"] = baseline_source
                        if baseline_path:
                            d["pairwise_baseline_path"] = baseline_path
                        if baseline_key is not None:
                            d["pairwise_baseline_model"] = baseline_key[0]
                            d["pairwise_baseline_effort"] = baseline_key[1]
                            if key == baseline_key:
                                d["pairwise_role"] = "baseline"
                                continue

                        if i >= len(base_outs):
                            d["pairwise_error"] = "baseline_output_missing"
                            continue

                        cand = outs[i]
                        base = base_outs[i]
                        baseline_id = baseline_path or ((baseline_key[0] + ":" + baseline_key[1]) if baseline_key is not None else "baseline")
                        swap = stable_swap(args.pairwise_seed, draft_path, backend, baseline_id, key[0], key[1], str(i))
                        a_md = cand if swap else base
                        b_md = base if swap else cand
                        a_role = "candidate" if swap else "baseline"
                        b_role = "baseline" if swap else "candidate"
                        try:
                            jdt, jobj = run_codex_pairwise_judge_exec(
                                judge_model=pairwise_model,
                                judge_effort=args.pairwise_effort,
                                judge_summary=args.pairwise_summary,
                                draft_md=draft_md,
                                a_md=a_md,
                                b_md=b_md,
                                instruction=args.instruction,
                                timeout_s=args.pairwise_timeout,
                                schema_path=args.pairwise_schema,
                                verbose=args.verbose,
                            )
                            d["pairwise_latency_s"] = jdt
                            if isinstance(jobj.get("confidence"), int):
                                d["pairwise_confidence"] = int(jobj["confidence"])
                            if isinstance(jobj.get("notes"), list):
                                d["pairwise_notes"] = jobj["notes"][:6]

                            w = str(jobj.get("winner") or "").strip()
                            if w == "tie":
                                d["pairwise_result"] = "tie"
                                d["pairwise_score"] = 0.5
                                continue
                            if w not in ("A", "B"):
                                d["pairwise_error"] = f"invalid_winner:{w}"
                                continue

                            winner_role = a_role if w == "A" else b_role
                            if winner_role == "candidate":
                                d["pairwise_result"] = "win"
                                d["pairwise_score"] = 1.0
                            elif winner_role == "baseline":
                                d["pairwise_result"] = "loss"
                                d["pairwise_score"] = 0.0
                            else:
                                d["pairwise_error"] = f"invalid_role:{winner_role}"
                        except Exception as ex:
                            d["pairwise_error"] = str(ex)

            if pairwise_enabled:
                if run_exec:
                    apply_pairwise("exec", pw_exec_outputs, pw_exec_evals)
                if need_app_server:
                    apply_pairwise("app_server_warm", pw_app_outputs, pw_app_evals)

        rows = [r.to_json() for r in results]

        if app_startup_s is not None:
            print(f"app_server_startup_s\t{app_startup_s:.3f}")

        print(
            "draft\tmodel\teffort\texec_median_s\tapp_warm_median_s\texec_p95_s\tapp_warm_p95_s\t"
            "exec_q50\tapp_q50\texec_qpass\tapp_qpass\t"
            "exec_j50\tapp_j50\texec_jpass\tapp_jpass\t"
            "exec_pw50\tapp_pw50\t"
            "exec_cached50\tapp_cached50\texec_cache_hit\tapp_cache_hit"
        )
        for r in rows:
            draft_name = safe_name(os.path.basename(str(r.get("draft_path") or "")))
            exec_stats = (r.get("exec") or {}).get("stats") or {}
            app_stats = (r.get("app_server_warm") or {}).get("stats") or {}
            exec_eval = (r.get("exec") or {}).get("eval") or {}
            app_eval = (r.get("app_server_warm") or {}).get("eval") or {}
            exec_med = exec_stats.get("median")
            app_med = app_stats.get("median")
            exec_p95 = exec_stats.get("p95")
            app_p95 = app_stats.get("p95")
            exec_q = (exec_eval.get("quality_score") or {}).get("median")
            app_q = (app_eval.get("quality_score") or {}).get("median")
            exec_qpass = (exec_eval.get("quality_pass") or {}).get("rate")
            app_qpass = (app_eval.get("quality_pass") or {}).get("rate")
            exec_j = (exec_eval.get("judge_overall") or {}).get("median")
            app_j = (app_eval.get("judge_overall") or {}).get("median")
            exec_jpass = (exec_eval.get("judge_pass") or {}).get("rate")
            app_jpass = (app_eval.get("judge_pass") or {}).get("rate")
            exec_pw = (exec_eval.get("pairwise_score") or {}).get("median")
            app_pw = (app_eval.get("pairwise_score") or {}).get("median")
            exec_cached = (exec_eval.get("cached_input_tokens") or {}).get("median")
            app_cached = (app_eval.get("cached_input_tokens") or {}).get("median")
            exec_cache_hit = (exec_eval.get("prompt_cache_hit") or {}).get("rate")
            app_cache_hit = (app_eval.get("prompt_cache_hit") or {}).get("rate")
            print(
                f"{draft_name}\t{r['model']}\t{r['effort']}\t"
                + (f"{exec_med:.3f}" if isinstance(exec_med, (int, float)) else "-")
                + "\t"
                + (f"{app_med:.3f}" if isinstance(app_med, (int, float)) else "-")
                + "\t"
                + (f"{exec_p95:.3f}" if isinstance(exec_p95, (int, float)) else "-")
                + "\t"
                + (f"{app_p95:.3f}" if isinstance(app_p95, (int, float)) else "-")
                + "\t"
                + (f"{exec_q:.0f}" if isinstance(exec_q, (int, float)) else "-")
                + "\t"
                + (f"{app_q:.0f}" if isinstance(app_q, (int, float)) else "-")
                + "\t"
                + (f"{exec_qpass:.2f}" if isinstance(exec_qpass, (int, float)) else "-")
                + "\t"
                + (f"{app_qpass:.2f}" if isinstance(app_qpass, (int, float)) else "-")
                + "\t"
                + (f"{exec_j:.0f}" if isinstance(exec_j, (int, float)) else "-")
                + "\t"
                + (f"{app_j:.0f}" if isinstance(app_j, (int, float)) else "-")
                + "\t"
                + (f"{exec_jpass:.2f}" if isinstance(exec_jpass, (int, float)) else "-")
                + "\t"
                + (f"{app_jpass:.2f}" if isinstance(app_jpass, (int, float)) else "-")
                + "\t"
                + (f"{exec_pw:.2f}" if isinstance(exec_pw, (int, float)) else "-")
                + "\t"
                + (f"{app_pw:.2f}" if isinstance(app_pw, (int, float)) else "-")
                + "\t"
                + (f"{exec_cached:.0f}" if isinstance(exec_cached, (int, float)) else "-")
                + "\t"
                + (f"{app_cached:.0f}" if isinstance(app_cached, (int, float)) else "-")
                + "\t"
                + (f"{exec_cache_hit:.2f}" if isinstance(exec_cache_hit, (int, float)) else "-")
                + "\t"
                + (f"{app_cache_hit:.2f}" if isinstance(app_cache_hit, (int, float)) else "-")
            )

        print("\nJSON:")
        print(json.dumps(rows, indent=2))

        if args.json_out:
            with open(args.json_out, "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "app_server_startup_s": app_startup_s,
                        "system_preamble_source": system_preamble_source,
                        "system_preamble_sha256": system_preamble_sha256,
                        "quality_min": args.quality_min,
                        "statistics": {
                            "percentile_method": "nearest_rank",
                            "median_ci": "bootstrap_95",
                            "bootstrap_rounds": 2000,
                        },
                        "judge": {
                            "enabled": bool(args.judge_model),
                            "model": args.judge_model,
                            "effort": args.judge_effort,
                            "summary": args.judge_summary,
                            "n": args.judge_n,
                            "min": args.judge_min,
                            "timeout_s": args.judge_timeout,
                            "schema": args.judge_schema,
                        },
                        "pairwise": {
                            "enabled": bool(pairwise_enabled),
                            "model": pairwise_model,
                            "effort": args.pairwise_effort,
                            "summary": args.pairwise_summary,
                            "n": pairwise_n,
                            "timeout_s": args.pairwise_timeout,
                            "schema": args.pairwise_schema,
                            "baseline_model": args.pairwise_baseline_model,
                            "baseline_effort": args.pairwise_baseline_effort,
                            "baseline_file": pairwise_baseline_file,
                            "baseline_dir": pairwise_baseline_dir,
                            "seed": args.pairwise_seed,
                        },
                        "results": rows,
                    },
                    f,
                    indent=2,
                )

        return 0

    finally:
        try:
            if app_proc is not None and app_proc.stdin is not None:
                app_proc.stdin.close()
        except Exception:
            pass
        try:
            if app_proc is not None:
                app_proc.terminate()
                try:
                    app_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    app_proc.kill()
                    app_proc.wait(timeout=5)
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
