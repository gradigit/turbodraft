#!/usr/bin/env python3
import argparse
import datetime as dt
import hashlib
import json
import math
import pathlib
import re
import statistics
import subprocess
from typing import Dict, List, Tuple, Any

from tools.provider_contract import (
    DEFAULT_PROVIDER_CONTRACT,
    ProviderContractError,
    load_provider_contract,
)


def load_text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def load_jsonl(path: pathlib.Path) -> List[dict]:
    rows: List[dict] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    return rows


def run_codex_exec(
    prompt: str,
    model: str,
    output_schema: pathlib.Path | None = None,
    timeout_s: int = 240,
    reasoning_effort: str | None = None,
) -> Tuple[str, List[dict]]:
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
    if output_schema is not None:
        cmd.extend(["--output-schema", str(output_schema)])
    cmd.append("-")

    proc = subprocess.run(
        cmd,
        input=prompt,
        text=True,
        capture_output=True,
        timeout=timeout_s,
    )

    events: List[dict] = []
    last_agent_message: str | None = None
    error_message: str | None = None

    for raw_line in proc.stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        events.append(ev)
        ev_type = ev.get("type")
        if ev_type == "item.completed":
            item = ev.get("item") or {}
            if item.get("type") == "agent_message":
                last_agent_message = item.get("text", "")
        elif ev_type == "error":
            error_message = ev.get("message")
        elif ev_type == "turn.failed":
            error_message = (ev.get("error") or {}).get("message") or error_message

    if proc.returncode != 0 and not error_message:
        error_message = f"codex exited {proc.returncode}: {proc.stderr.strip()}"
    if error_message:
        raise RuntimeError(error_message)
    if not last_agent_message:
        raise RuntimeError("No agent message in codex output")

    return last_agent_message, events


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


def _collect_text_strings(payload: Any) -> List[str]:
    out: List[str] = []
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


def _extract_claude_text(events: List[dict[str, Any]]) -> str | None:
    for ev in reversed(events):
        if ev.get("type") == "result":
            result = ev.get("result")
            if isinstance(result, str) and result.strip():
                return result
    for ev in reversed(events):
        if ev.get("type") == "assistant":
            msg = ev.get("message") or {}
            parts = msg.get("content") or []
            if isinstance(parts, list):
                texts = [
                    part.get("text", "")
                    for part in parts
                    if isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str)
                ]
                joined = "\n".join(t for t in texts if t.strip())
                if joined:
                    return joined
    return None


def _extract_claude_usage(events: List[dict[str, Any]]) -> dict[str, Any] | None:
    usage_payload: dict[str, Any] | None = None
    total_cost_usd: float | None = None
    for ev in reversed(events):
        if ev.get("type") == "result":
            usage = ev.get("usage")
            if isinstance(usage, dict):
                usage_payload = usage
            total_cost_usd = _to_float(ev.get("total_cost_usd"))
            break

    if usage_payload is None and total_cost_usd is None:
        return None

    out: dict[str, Any] = {}
    if isinstance(usage_payload, dict):
        out.update(usage_payload)
    if total_cost_usd is not None:
        out["cost_usd"] = total_cost_usd
    return out


def run_claude_exec(
    prompt: str,
    model: str,
    timeout_s: int = 240,
    reasoning_effort: str | None = None,
) -> Tuple[str, List[dict]]:
    effort = (reasoning_effort or "high").strip() or "high"
    cmd = [
        "claude",
        "-p",
        "--model",
        model,
        "--effort",
        effort,
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
        timeout=timeout_s,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"claude exited {proc.returncode}: {(proc.stderr or '').strip()}")

    raw = (proc.stdout or "").strip()
    if not raw:
        raise RuntimeError("claude produced empty output")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"claude output was not valid JSON: {exc}") from exc

    if isinstance(data, dict):
        events = [data]
    elif isinstance(data, list):
        events = [ev for ev in data if isinstance(ev, dict)]
    else:
        events = []
    text = _extract_claude_text(events)
    if not text:
        raise RuntimeError("claude JSON did not include assistant/result text")
    usage = _extract_claude_usage(events)
    if usage is not None:
        events.append({"type": "usage", "usage": usage})
    return text, events


def _extract_gemini_usage(payload: Any) -> dict[str, Any] | None:
    # Gemini CLI JSON may include usage in either:
    # 1) usageMetadata-like fields (promptTokenCount/candidatesTokenCount/totalTokenCount), or
    # 2) stats.models.<model>.tokens.{prompt,candidates,total,cached}
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
                    cached_tokens = _to_int(tok.get("cached"))
                    if total_tokens is None and (prompt_tokens is not None or completion_tokens is not None):
                        total_tokens = int((prompt_tokens or 0) + (completion_tokens or 0))
                    out_stats: dict[str, Any] = {}
                    if prompt_tokens is not None:
                        out_stats["input_tokens"] = prompt_tokens
                    if completion_tokens is not None:
                        out_stats["output_tokens"] = completion_tokens
                    if total_tokens is not None:
                        out_stats["total_tokens"] = total_tokens
                    if cached_tokens is not None:
                        out_stats["cached_input_tokens"] = cached_tokens
                    if out_stats:
                        return out_stats

    best: dict[str, Any] | None = None

    def visit(node: Any) -> None:
        nonlocal best
        if isinstance(node, dict):
            keys = set(node.keys())
            if {
                "promptTokenCount",
                "candidatesTokenCount",
                "totalTokenCount",
            }.intersection(keys):
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
        out["input_tokens"] = prompt_tokens
    if completion_tokens is not None:
        out["output_tokens"] = completion_tokens
    if total_tokens is not None:
        out["total_tokens"] = total_tokens
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


def run_gemini_exec(
    prompt: str,
    model: str,
    timeout_s: int = 240,
    reasoning_effort: str | None = None,
) -> Tuple[str, List[dict]]:
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
        timeout=timeout_s,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"gemini exited {proc.returncode}: {(proc.stderr or '').strip()}")
    raw = proc.stdout or ""
    if not raw.strip():
        raise RuntimeError("gemini produced empty output")
    try:
        data = _extract_last_json_object(raw)
    except Exception as exc:
        raise RuntimeError(f"gemini output did not contain parsable JSON: {exc}") from exc

    texts = _collect_text_strings(data)
    text = next((t for t in reversed(texts) if t.strip()), None)
    if not text:
        raise RuntimeError("gemini JSON did not include parsable text output")
    usage = _extract_gemini_usage(data)
    events: List[dict] = []
    if usage is not None:
        events.append({"type": "usage", "usage": usage})
    return text, events


def run_auggie_exec(
    prompt: str,
    model: str,
    timeout_s: int = 240,
    reasoning_effort: str | None = None,
) -> Tuple[str, List[dict]]:
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
        timeout=timeout_s,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"auggie exited {proc.returncode}: {(proc.stderr or '').strip()}")
    raw = proc.stdout or ""
    if not raw.strip():
        raise RuntimeError("auggie produced empty output")
    try:
        data = _extract_last_json_object(raw)
    except Exception as exc:
        raise RuntimeError(f"auggie output did not contain parsable JSON: {exc}") from exc

    if isinstance(data, dict):
        result = data.get("result")
        if isinstance(result, str) and result.strip():
            return result.strip(), []

    texts = _collect_text_strings(data)
    text = next((t for t in reversed(texts) if t.strip()), None)
    if not text:
        raise RuntimeError("auggie JSON did not include parsable text output")
    return text.strip(), []


def run_provider_exec(
    prompt: str,
    provider: dict[str, str],
    output_schema: pathlib.Path | None = None,
    timeout_s: int = 240,
) -> Tuple[str, List[dict]]:
    runner = str(provider.get("runner", "")).strip().lower()
    model = str(provider.get("model", "")).strip()
    reasoning_effort = str(provider.get("reasoning_effort", "")).strip() or None
    if runner == "codex":
        return run_codex_exec(
            prompt=prompt,
            model=model,
            output_schema=output_schema,
            timeout_s=timeout_s,
            reasoning_effort=reasoning_effort,
        )
    if runner == "claude":
        return run_claude_exec(
            prompt=prompt,
            model=model,
            timeout_s=timeout_s,
            reasoning_effort=reasoning_effort,
        )
    if runner == "gemini":
        return run_gemini_exec(
            prompt=prompt,
            model=model,
            timeout_s=timeout_s,
            reasoning_effort=reasoning_effort,
        )
    if runner == "auggie":
        return run_auggie_exec(
            prompt=prompt,
            model=model,
            timeout_s=timeout_s,
            reasoning_effort=reasoning_effort,
        )
    raise RuntimeError(f"unsupported provider runner: {runner}")


def optional_bullet_count(text: str) -> int:
    return len(re.findall(r"(?im)^\s*[-*]\s*Optional:\s*", text))


def evaluate_deterministic(case: dict, output: str) -> dict:
    required = case.get("required_substrings") or []
    forbidden = case.get("forbidden_substrings") or []
    must_mention_any = case.get("must_mention_any") or []
    max_optional = case.get("max_optional_bullets")

    missing_required = [s for s in required if s not in output]
    found_forbidden = [s for s in forbidden if re.search(re.escape(s), output, flags=re.IGNORECASE)]

    mention_any_ok = True
    if must_mention_any:
        low = output.lower()
        mention_any_ok = any(tok.lower() in low for tok in must_mention_any)
    mention_any_required = bool(must_mention_any)

    optional_count = optional_bullet_count(output)
    optional_ok = True
    if isinstance(max_optional, int):
        optional_ok = optional_count <= max_optional

    total_checks = len(required) + len(forbidden) + (1 if mention_any_required else 0) + (1 if isinstance(max_optional, int) else 0)
    passed_checks = (len(required) - len(missing_required)) + (len(forbidden) - len(found_forbidden))
    if mention_any_required:
        passed_checks += 1 if mention_any_ok else 0
    if isinstance(max_optional, int):
        passed_checks += 1 if optional_ok else 0

    score = 100.0 * passed_checks / max(1, total_checks)

    hard_pass = not missing_required and not found_forbidden and mention_any_ok and optional_ok

    return {
        "hard_pass": hard_pass,
        "score": round(score, 2),
        "missing_required": missing_required,
        "found_forbidden": found_forbidden,
        "mention_any_ok": mention_any_ok,
        "optional_count": optional_count,
        "optional_ok": optional_ok,
    }


def build_task_prompt(
    preamble: str,
    preset: str,
    draft_prompt: str,
    instruction: str,
    contract: str | None,
    overlay: str,
) -> str:
    overlay = overlay.strip()
    addl = ""
    if overlay and overlay.lower() != "no additional constraints.":
        addl = f"\n\nAdditional constraints:\n{overlay}"

    task = instruction.strip() + addl

    if preset == "legacy":
        return (
            f"{preamble.strip()}\n\n"
            f"TASK:\n{task}\n\n"
            f"DRAFT PROMPT (Markdown):\n<BEGIN_PROMPT>\n{draft_prompt}\n<END_PROMPT>\n"
        )

    return (
        f"{preamble.strip()}\n\n"
        f"TASK:\n{task}\n\n"
        f"PRESET:\n{preset}\n\n"
        f"PRESET CONTRACT:\n{(contract or '').strip()}\n\n"
        f"DRAFT PROMPT (Markdown):\n<BEGIN_PROMPT>\n{draft_prompt}\n<END_PROMPT>\n"
    )


def fill_template(template: str, values: Dict[str, str]) -> str:
    out = template
    for k, v in values.items():
        out = out.replace("{{" + k + "}}", v)
    return out


def parse_judge_json(text: str) -> dict:
    text = text.strip()
    # Best effort for fenced JSON.
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end > start:
            return json.loads(text[start : end + 1])
        raise


def mode_winner(votes: List[str]) -> str:
    norm = [v if v in {"A", "B", "Tie"} else "Tie" for v in votes]
    counts = {label: norm.count(label) for label in ("A", "B", "Tie")}
    max_count = max(counts.values()) if counts else 0
    winners = [label for label, count in counts.items() if count == max_count]
    if len(winners) != 1:
        return "Tie"
    return winners[0]


def reverse_winner(winner: str) -> str:
    if winner == "A":
        return "B"
    if winner == "B":
        return "A"
    return "Tie"


def add_usage(acc: dict[str, float], usage: Any) -> None:
    if not isinstance(usage, dict):
        return
    normalized: dict[str, Any] = dict(usage)
    if "input_tokens" not in normalized:
        prompt_tokens = _to_int(normalized.get("prompt"))
        if prompt_tokens is not None:
            normalized["input_tokens"] = prompt_tokens
    if "output_tokens" not in normalized:
        completion_tokens = _to_int(normalized.get("completion"))
        if completion_tokens is not None:
            normalized["output_tokens"] = completion_tokens
    if "total_tokens" not in normalized:
        total_tokens = _to_int(normalized.get("total"))
        if total_tokens is None:
            input_tokens = _to_int(normalized.get("input_tokens")) or 0
            output_tokens = _to_int(normalized.get("output_tokens")) or 0
            if input_tokens or output_tokens:
                total_tokens = input_tokens + output_tokens
        if total_tokens is not None:
            normalized["total_tokens"] = total_tokens
    if "cached_input_tokens" not in normalized:
        details = normalized.get("input_tokens_details")
        if isinstance(details, dict):
            cached = _to_int(details.get("cached_tokens"))
            if cached is not None:
                normalized["cached_input_tokens"] = cached

    for key in (
        "input_tokens",
        "output_tokens",
        "reasoning_tokens",
        "total_tokens",
        "cached_input_tokens",
        "cost_usd",
    ):
        val = normalized.get(key)
        if isinstance(val, (int, float)):
            acc[key] = acc.get(key, 0.0) + float(val)


def latest_usage(events: list[dict]) -> dict[str, Any] | None:
    for ev in reversed(events):
        usage = ev.get("usage")
        if isinstance(usage, dict):
            return usage
    return None


def add_usage_for_role(
    usage_by_role: dict[str, dict[str, float]],
    role: str,
    usage: Any,
) -> None:
    bucket = usage_by_role.setdefault(role, {})
    add_usage(bucket, usage)


def normalize_winner(value: Any) -> str:
    winner = str(value or "Tie")
    if winner in {"A", "B", "Tie"}:
        return winner
    return "Tie"


def score_margin_from_decision(decision: dict[str, Any]) -> float | None:
    score_a = _to_float(decision.get("score_a"))
    score_b = _to_float(decision.get("score_b"))
    if score_a is None or score_b is None:
        return None
    return abs(score_a - score_b)


def consensus_2_of_3(votes: list[str]) -> tuple[str, bool]:
    norm = [normalize_winner(v) for v in votes]
    counts = {label: norm.count(label) for label in ("A", "B", "Tie")}
    best = max(counts.values()) if counts else 0
    leaders = [label for label, c in counts.items() if c == best]
    if best >= 2 and len(leaders) == 1:
        return leaders[0], True
    return "Tie", False


def _is_timeout_exception(exc: Exception) -> bool:
    if isinstance(exc, subprocess.TimeoutExpired):
        return True
    cause = getattr(exc, "__cause__", None)
    if isinstance(cause, subprocess.TimeoutExpired):
        return True
    return False


def redact_string(value: str) -> dict[str, Any]:
    return {
        "sha256": hashlib.sha256(value.encode("utf-8")).hexdigest(),
        "char_count": len(value),
    }


def redact_error(value: str | None) -> dict[str, Any] | None:
    if not value:
        return None
    return redact_string(value)


def should_trigger_escalation(
    uncertain_reasons: list[str],
    *,
    escalation_on_critical: bool,
    case_is_critical: bool,
) -> bool:
    return bool(uncertain_reasons) or (bool(escalation_on_critical) and bool(case_is_critical))


def one_sided_binom_pvalue(wins: int, total: int) -> float:
    if total <= 0:
        return 1.0
    if wins < 0:
        wins = 0
    if wins > total:
        wins = total
    # Compute tail probability P[X >= wins], X~Binomial(total, 0.5), in log-space
    # to avoid overflow at large total.
    log2 = math.log(2.0)
    log_terms: list[float] = []
    for k in range(wins, total + 1):
        log_choose = math.lgamma(total + 1) - math.lgamma(k + 1) - math.lgamma(total - k + 1)
        log_terms.append(log_choose - (total * log2))
    if not log_terms:
        return 0.0
    m = max(log_terms)
    tail = math.exp(m) * sum(math.exp(v - m) for v in log_terms)
    return min(1.0, max(0.0, float(tail)))


def holm_adjust(pvalues_by_family: dict[str, float]) -> dict[str, float]:
    ordered = sorted(
        [(family, max(0.0, min(1.0, float(p)))) for family, p in pvalues_by_family.items()],
        key=lambda item: item[1],
    )
    m = len(ordered)
    adjusted: dict[str, float] = {}
    prev = 0.0
    for i, (family, p) in enumerate(ordered):
        factor = m - i
        value = min(1.0, factor * p)
        value = max(prev, value)
        adjusted[family] = value
        prev = value
    return adjusted


def summarize_generation(rows: List[dict], variants: List[str]) -> Dict[str, dict]:
    out: Dict[str, dict] = {}
    for v in variants:
        subset = [r for r in rows if r["variant"] == v]
        if not subset:
            continue
        hard_rate = sum(1 for r in subset if r["deterministic"]["hard_pass"]) / len(subset)
        avg_score = sum(r["deterministic"]["score"] for r in subset) / len(subset)
        out[v] = {
            "n": len(subset),
            "hard_pass_rate": round(hard_rate, 4),
            "avg_deterministic_score": round(avg_score, 2),
        }
    return out


def summarize_pairwise(rows: List[dict]) -> Dict[str, dict]:
    grouped: Dict[str, List[dict]] = {}
    for r in rows:
        grouped.setdefault(r["variant"], []).append(r)

    out: Dict[str, dict] = {}
    for v, subset in grouped.items():
        n = len(subset)
        wins = sum(1 for r in subset if r["judge_decision"]["winner"] == "A")
        losses = sum(1 for r in subset if r["judge_decision"]["winner"] == "B")
        ties = sum(1 for r in subset if r["judge_decision"]["winner"] == "Tie")
        non_tie_n = wins + losses
        non_tie_win_rate = (wins / non_tie_n) if non_tie_n > 0 else 0.0
        out[v] = {
            "n": n,
            "wins": wins,
            "losses": losses,
            "ties": ties,
            "non_tie_n": non_tie_n,
            "win_rate": round(wins / n, 4),
            "loss_rate": round(losses / n, 4),
            "tie_rate": round(ties / n, 4),
            "non_loss_rate": round((wins + ties) / n, 4),
            "non_tie_win_rate": round(non_tie_win_rate, 4),
        }
    return out


def summarize_pairwise_repeat_stats(rows: List[dict], repeats: int) -> Dict[str, dict]:
    grouped: Dict[str, List[dict]] = {}
    for r in rows:
        grouped.setdefault(r["variant"], []).append(r)

    out: Dict[str, dict] = {}
    for variant, subset in grouped.items():
        if repeats <= 1:
            out[variant] = {
                "repeat_count": repeats,
                "repeat_non_tie_winrates": [],
                "repeat_non_tie_winrate_stddev": None,
            }
            continue
        per_repeat_rates: List[float] = []
        for repeat_idx in range(repeats):
            wins = 0
            losses = 0
            for row in subset:
                votes = row.get("repeat_votes") or []
                if repeat_idx >= len(votes):
                    continue
                winner = votes[repeat_idx]
                if winner == "A":
                    wins += 1
                elif winner == "B":
                    losses += 1
            non_tie = wins + losses
            rate = (wins / non_tie) if non_tie > 0 else 0.0
            per_repeat_rates.append(round(rate, 6))
        stddev = statistics.pstdev(per_repeat_rates) if len(per_repeat_rates) >= 2 else None
        out[variant] = {
            "repeat_count": repeats,
            "repeat_non_tie_winrates": per_repeat_rates,
            "repeat_non_tie_winrate_stddev": round(stddev, 6) if stddev is not None else None,
        }
    return out


def summarize_pairwise_by_family(rows: List[dict], baseline_variant: str, repeats: int) -> Dict[str, Any]:
    grouped: Dict[str, Dict[str, List[dict]]] = {}
    for r in rows:
        grouped.setdefault(r["preset"], {}).setdefault(r["variant"], []).append(r)

    family_results: Dict[str, Any] = {}
    for family, by_variant in grouped.items():
        variant_stats: Dict[str, dict] = {}
        for variant, subset in by_variant.items():
            basic = summarize_pairwise(subset).get(variant) or {}
            repeat_stats = summarize_pairwise_repeat_stats(subset, repeats).get(variant) or {}
            variant_stats[variant] = {**basic, **repeat_stats}

        best_variant: str | None = None
        best_stats: dict[str, Any] = {}
        best_score = -1.0
        for variant, stats in variant_stats.items():
            if variant == baseline_variant:
                continue
            wins = int(stats.get("wins", 0) or 0)
            losses = int(stats.get("losses", 0) or 0)
            non_tie_n = int(stats.get("non_tie_n", 0) or 0)
            # Do not name a "best" variant unless it is meaningfully better than baseline.
            if non_tie_n <= 0 or wins <= losses:
                continue
            score = float(stats.get("win_rate", 0.0) or 0.0)
            if score > best_score:
                best_variant = variant
                best_stats = stats
                best_score = score

        family_results[family] = {
            "baseline_variant": baseline_variant,
            "variants": variant_stats,
            "best_variant": best_variant,
            "best_pairwise_vs_baseline": best_stats if best_variant else {},
        }
    return family_results


def main() -> int:
    ap = argparse.ArgumentParser(description="Run pilot prompt eval using Codex as drafter and judge")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--provider-contract", default=DEFAULT_PROVIDER_CONTRACT)
    ap.add_argument("--draft-model", default="")
    ap.add_argument("--judge-model", default="")
    ap.add_argument("--draft-reasoning-effort", default="")
    ap.add_argument("--judge-reasoning-effort", default="")
    ap.add_argument("--cases", default="bench/prompt_eval/datasets/pilot_cases.jsonl")
    ap.add_argument("--preamble", default="bench/preambles/large-optimized-v1.md")
    ap.add_argument(
        "--variants",
        nargs="+",
        default=[
            "bench/prompt_eval/variants/overlay_baseline.md",
            "bench/prompt_eval/variants/overlay_contract_selfcheck.md",
            "bench/prompt_eval/variants/overlay_precision_guard.md",
        ],
    )
    ap.add_argument("--judge-prompt", default="bench/prompt_eval/prompts/judge_pairwise_v2.md")
    ap.add_argument("--judge-schema", default="bench/prompt_eval/schemas/judge_decision.schema.json")
    ap.add_argument("--pairwise-top-k", type=int, default=0, help="If >0, run pairwise only for top-K non-baseline variants by deterministic metrics")
    ap.add_argument("--baseline-variant", default="overlay_baseline", help="Variant name used as baseline in pairwise comparisons.")
    ap.add_argument("--pairwise-repeats", type=int, default=1, help="Repeat count per pairwise comparison; majority vote used for canonical winner")
    ap.add_argument(
        "--pairwise-mirror-mode",
        choices=["always", "critical", "never"],
        default="critical",
        help="Reverse-orientation mirror policy for pairwise calls.",
    )
    ap.add_argument(
        "--pairwise-critical-repeats",
        type=int,
        default=0,
        help="If >0, override repeat count for critical cases.",
    )
    ap.add_argument(
        "--pairwise-noncritical-repeats",
        type=int,
        default=0,
        help="If >0, override repeat count for non-critical cases.",
    )
    ap.add_argument(
        "--enable-judge-escalation",
        action="store_true",
        help="Escalate uncertain primary judge outcomes to secondary judges and apply 2-of-3 consensus.",
    )
    ap.add_argument(
        "--escalation-confidence-threshold",
        type=float,
        default=0.65,
        help="Escalate when primary confidence is below this threshold.",
    )
    ap.add_argument(
        "--escalation-score-margin-max",
        type=float,
        default=0.05,
        help="Escalate when relative margin |score_a-score_b|/max(score_a,score_b) <= this value.",
    )
    ap.add_argument(
        "--escalation-score-margin-points",
        type=float,
        default=1.0,
        help="Escalate when absolute score margin |score_a-score_b| <= this many points.",
    )
    ap.add_argument(
        "--escalation-on-critical",
        action="store_true",
        help="Escalate all critical cases (critical_case=true) regardless of confidence/margin.",
    )
    ap.add_argument("--redact-sensitive", action="store_true", help="Redact prompt/output text in persisted artifacts (store hashes only)")
    ap.add_argument("--max-cases", type=int, default=0)
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--timeout", type=int, default=240)
    args = ap.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    try:
        provider_contract = load_provider_contract(repo, args.provider_contract)
    except ProviderContractError as exc:
        raise RuntimeError(f"provider contract load failed: {exc}") from exc

    provider_roles = provider_contract["providers"]
    drafting_cfg = provider_roles["drafting"]
    primary_cfg = provider_roles["judge_primary"]
    shadow_cfg = provider_roles.get("judge_shadow")
    secondary_cfg = provider_roles.get("judge_secondary")
    if drafting_cfg["runner"] != "codex":
        raise RuntimeError(
            "provider contract unsupported for drafting role: "
            f"runner={drafting_cfg['runner']!r} (expected 'codex')"
        )
    if primary_cfg["runner"] != "codex":
        raise RuntimeError(
            "provider contract unsupported for judge_primary role: "
            f"runner={primary_cfg['runner']!r} (expected 'codex')"
        )
    if args.enable_judge_escalation:
        if not isinstance(secondary_cfg, dict) or not isinstance(shadow_cfg, dict):
            raise RuntimeError(
                "judge escalation requires provider roles 'judge_secondary' and 'judge_shadow'"
            )

    draft_model = args.draft_model or drafting_cfg["model"]
    draft_reasoning_effort = args.draft_reasoning_effort or drafting_cfg["reasoning_effort"]
    judge_model = args.judge_model or primary_cfg["model"]
    judge_reasoning_effort = args.judge_reasoning_effort or primary_cfg["reasoning_effort"]

    cases_path = (repo / args.cases).resolve()
    preamble_path = (repo / args.preamble).resolve()
    variant_paths = [(repo / p).resolve() for p in args.variants]
    judge_prompt_path = (repo / args.judge_prompt).resolve()
    judge_schema_path = (repo / args.judge_schema).resolve()

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = pathlib.Path(args.out_dir).resolve() if args.out_dir else (repo / "bench" / "prompt_eval" / "reports" / f"pilot_{stamp}")
    out_dir.mkdir(parents=True, exist_ok=True)

    preamble = load_text(preamble_path)
    cases = load_jsonl(cases_path)
    if args.max_cases > 0:
        cases = cases[: args.max_cases]

    judge_template = load_text(judge_prompt_path)

    variants: List[Tuple[str, str]] = []
    for vp in variant_paths:
        variants.append((vp.stem, load_text(vp)))
    variant_names = [name for name, _ in variants]
    baseline_variant = str(args.baseline_variant or "overlay_baseline").strip() or "overlay_baseline"
    if baseline_variant not in variant_names:
        raise RuntimeError(
            f"baseline variant {baseline_variant!r} not found in loaded variants: {variant_names}"
        )

    generation_rows: List[dict] = []
    case_variant_outputs: Dict[Tuple[str, str], str] = {}
    usage_totals: dict[str, float] = {}
    usage_by_role: dict[str, dict[str, float]] = {}
    model_call_count = 0
    model_error_count = 0
    model_timeout_count = 0
    escalation_stats = {
        "uncertain_primary_votes": 0,
        "escalations_triggered": 0,
        "consensus_resolved": 0,
        "consensus_unresolved": 0,
    }

    for case in cases:
        preset = case["preset"]
        instr_path = repo / "bench" / "presets" / "instructions" / f"{preset}.md"
        if not instr_path.exists():
            raise FileNotFoundError(f"Missing instruction file: {instr_path}")
        instruction = load_text(instr_path)

        contract_path = repo / "bench" / "presets" / "contracts" / f"{preset}.md"
        contract = load_text(contract_path) if contract_path.exists() else ""

        for variant_name, overlay in variants:
            run_prompt = build_task_prompt(
                preamble=preamble,
                preset=preset,
                draft_prompt=case["draft_prompt"],
                instruction=instruction,
                contract=contract,
                overlay=overlay,
            )

            gen_error: str | None = None
            try:
                model_call_count += 1
                output, events = run_provider_exec(
                    prompt=run_prompt,
                    provider={
                        **drafting_cfg,
                        "model": draft_model,
                        "reasoning_effort": draft_reasoning_effort,
                    },
                    output_schema=None,
                    timeout_s=args.timeout,
                )
            except Exception as exc:
                output, events = "", []
                gen_error = str(exc)
                model_error_count += 1
                if _is_timeout_exception(exc):
                    model_timeout_count += 1
            det = evaluate_deterministic(case, output)
            usage = latest_usage(events)
            add_usage(usage_totals, usage)
            add_usage_for_role(usage_by_role, "drafting", usage)

            row = {
                "case_id": case["id"],
                "preset": preset,
                "variant": variant_name,
                "deterministic": det,
                "usage": usage,
            }
            if args.redact_sensitive:
                row["draft_prompt_sha256"] = hashlib.sha256(str(case["draft_prompt"]).encode("utf-8")).hexdigest()
                row["output_sha256"] = hashlib.sha256(output.encode("utf-8")).hexdigest()
                row["output_char_count"] = len(output)
            else:
                row["draft_prompt"] = case["draft_prompt"]
                row["output"] = output
            if gen_error:
                if args.redact_sensitive:
                    row["error_redacted"] = redact_error(gen_error)
                else:
                    row["error"] = gen_error
            generation_rows.append(row)
            case_variant_outputs[(case["id"], variant_name)] = output

    non_baseline = [v for v, _ in variants if v != baseline_variant]

    # Optional pre-pruning before pairwise judging to reduce expensive judge calls.
    gen_summary = summarize_generation(generation_rows, [v for v, _ in variants])
    selected_non_baseline = list(non_baseline)
    pruned_non_baseline: List[str] = []
    if args.pairwise_top_k > 0 and len(non_baseline) > args.pairwise_top_k:
        ranked = sorted(
            non_baseline,
            key=lambda v: (
                float((gen_summary.get(v) or {}).get("hard_pass_rate", 0.0)),
                float((gen_summary.get(v) or {}).get("avg_deterministic_score", 0.0)),
            ),
            reverse=True,
        )
        selected_non_baseline = ranked[: args.pairwise_top_k]
        pruned_non_baseline = ranked[args.pairwise_top_k :]

    escalation_providers: list[tuple[str, dict[str, str]]] = []
    if args.enable_judge_escalation and isinstance(secondary_cfg, dict) and isinstance(shadow_cfg, dict):
        escalation_providers = [
            ("judge_secondary", secondary_cfg),
            ("judge_shadow", shadow_cfg),
        ]

    pairwise_rows: List[dict] = []
    orientation_disagreement_count = 0
    orientation_pair_count = 0
    max_pairwise_repeats_used = 0
    for case in cases:
        case_is_critical = bool(case.get("critical_case", True))
        case_pairwise_repeats = max(1, args.pairwise_repeats)
        if case_is_critical and args.pairwise_critical_repeats > 0:
            case_pairwise_repeats = max(1, args.pairwise_critical_repeats)
        elif (not case_is_critical) and args.pairwise_noncritical_repeats > 0:
            case_pairwise_repeats = max(1, args.pairwise_noncritical_repeats)
        max_pairwise_repeats_used = max(max_pairwise_repeats_used, case_pairwise_repeats)
        mirror_enabled = (
            args.pairwise_mirror_mode == "always"
            or (args.pairwise_mirror_mode == "critical" and case_is_critical)
        )
        for variant in selected_non_baseline:
            cand = case_variant_outputs[(case["id"], variant)]
            base = case_variant_outputs[(case["id"], baseline_variant)]
            repeat_votes: List[str] = []
            repeat_decisions: List[dict[str, Any]] = []
            orientation_votes: List[dict[str, Any]] = []
            for _ in range(case_pairwise_repeats):
                judge_prompt_forward = fill_template(
                    judge_template,
                    {
                        "preset": case["preset"],
                        "draft_prompt": case["draft_prompt"],
                        "candidate_a": cand,
                        "candidate_b": base,
                    },
                )
                judge_prompt_reverse = ""
                if mirror_enabled:
                    judge_prompt_reverse = fill_template(
                        judge_template,
                        {
                            "preset": case["preset"],
                            "draft_prompt": case["draft_prompt"],
                            "candidate_a": base,
                            "candidate_b": cand,
                        },
                    )
                forward_decision: dict[str, Any] = {}
                reverse_decision: dict[str, Any] = {}
                forward_winner = "Tie"
                reverse_winner_raw = "Tie"
                repeat_error: str | None = None
                try:
                    model_call_count += 1
                    judge_raw, forward_events = run_provider_exec(
                        prompt=judge_prompt_forward,
                        provider={
                            **primary_cfg,
                            "model": judge_model,
                            "reasoning_effort": judge_reasoning_effort,
                        },
                        output_schema=judge_schema_path,
                        timeout_s=args.timeout,
                    )
                    forward_decision = parse_judge_json(judge_raw)
                    forward_usage = latest_usage(forward_events)
                    add_usage(usage_totals, forward_usage)
                    add_usage_for_role(usage_by_role, "judge_primary", forward_usage)
                    forward_winner = normalize_winner(forward_decision.get("winner"))
                except Exception as exc:
                    repeat_error = f"forward:{exc}"
                    model_error_count += 1
                    if _is_timeout_exception(exc):
                        model_timeout_count += 1

                if mirror_enabled:
                    try:
                        model_call_count += 1
                        judge_raw_rev, reverse_events = run_provider_exec(
                            prompt=judge_prompt_reverse,
                            provider={
                                **primary_cfg,
                                "model": judge_model,
                                "reasoning_effort": judge_reasoning_effort,
                            },
                            output_schema=judge_schema_path,
                            timeout_s=args.timeout,
                        )
                        reverse_decision = parse_judge_json(judge_raw_rev)
                        reverse_usage = latest_usage(reverse_events)
                        add_usage(usage_totals, reverse_usage)
                        add_usage_for_role(usage_by_role, "judge_primary", reverse_usage)
                        reverse_winner_raw = normalize_winner(reverse_decision.get("winner"))
                    except Exception as exc:
                        err = f"reverse:{exc}"
                        repeat_error = f"{repeat_error}; {err}" if repeat_error else err
                        model_error_count += 1
                        if _is_timeout_exception(exc):
                            model_timeout_count += 1
                else:
                    reverse_winner_raw = reverse_winner(forward_winner)

                reverse_mapped = reverse_winner(reverse_winner_raw)
                orientation_agree = forward_winner == reverse_mapped
                if mirror_enabled:
                    orientation_pair_count += 1
                    if not orientation_agree:
                        orientation_disagreement_count += 1
                if mirror_enabled and not orientation_agree:
                    primary_vote = "Tie"
                else:
                    primary_vote = forward_winner

                confidence = _to_float(forward_decision.get("confidence"))
                score_margin = score_margin_from_decision(forward_decision)
                score_a_val = _to_float(forward_decision.get("score_a"))
                score_b_val = _to_float(forward_decision.get("score_b"))
                relative_margin: float | None = None
                if score_margin is not None and score_a_val is not None and score_b_val is not None:
                    denom = max(abs(score_a_val), abs(score_b_val), 1.0)
                    relative_margin = float(score_margin) / float(denom)
                uncertain_reasons: List[str] = []
                if primary_vote == "Tie":
                    uncertain_reasons.append("primary_tie")
                if mirror_enabled and not orientation_agree:
                    uncertain_reasons.append("orientation_disagreement")
                if repeat_error:
                    uncertain_reasons.append("primary_error")
                if confidence is not None and confidence < float(args.escalation_confidence_threshold):
                    uncertain_reasons.append("low_confidence")
                if score_margin is not None and score_margin <= float(args.escalation_score_margin_points):
                    uncertain_reasons.append("near_tie_margin")
                elif relative_margin is not None and relative_margin <= float(args.escalation_score_margin_max):
                    uncertain_reasons.append("near_tie_margin")
                should_escalate = should_trigger_escalation(
                    uncertain_reasons,
                    escalation_on_critical=bool(args.escalation_on_critical),
                    case_is_critical=case_is_critical,
                )
                if args.escalation_on_critical and case_is_critical and "critical_case" not in uncertain_reasons:
                    uncertain_reasons.append("critical_case")

                escalation_details: List[dict[str, Any]] = []
                consensus_vote = primary_vote
                consensus_resolved = False
                if args.enable_judge_escalation and should_escalate:
                    escalation_stats["uncertain_primary_votes"] += 1
                    if escalation_providers:
                        escalation_stats["escalations_triggered"] += 1
                        votes = [primary_vote]
                        for role, provider in escalation_providers:
                            esc_winner: str | None = None
                            esc_decision: dict[str, Any] = {}
                            esc_error: str | None = None
                            try:
                                model_call_count += 1
                                esc_raw, esc_events = run_provider_exec(
                                    prompt=judge_prompt_forward,
                                    provider=provider,
                                    output_schema=None,
                                    timeout_s=args.timeout,
                                )
                                esc_decision = parse_judge_json(esc_raw)
                                esc_winner = normalize_winner(esc_decision.get("winner"))
                                esc_usage = latest_usage(esc_events)
                                add_usage(usage_totals, esc_usage)
                                add_usage_for_role(usage_by_role, role, esc_usage)
                            except Exception as exc:
                                esc_error = str(exc)
                                model_error_count += 1
                                if _is_timeout_exception(exc):
                                    model_timeout_count += 1
                            if esc_winner is not None:
                                votes.append(esc_winner)
                            if args.redact_sensitive:
                                escalation_details.append(
                                    {
                                        "role": role,
                                        "runner": provider.get("runner"),
                                        "model": provider.get("model"),
                                        "winner": esc_winner or "ABSTAIN",
                                        **({"error_redacted": redact_error(esc_error)} if esc_error else {}),
                                    }
                                )
                            else:
                                escalation_details.append(
                                    {
                                        "role": role,
                                        "runner": provider.get("runner"),
                                        "model": provider.get("model"),
                                        "winner": esc_winner or "ABSTAIN",
                                        "decision": esc_decision,
                                        **({"error": esc_error} if esc_error else {}),
                                    }
                                )
                        consensus_vote, consensus_resolved = consensus_2_of_3(votes)
                        if consensus_resolved:
                            escalation_stats["consensus_resolved"] += 1
                        else:
                            escalation_stats["consensus_unresolved"] += 1

                repeat_votes.append(consensus_vote)
                if args.redact_sensitive:
                    repeat_decisions.append(
                        {
                            "winner": consensus_vote,
                            "primary_vote": primary_vote,
                            "forward_winner": forward_winner,
                            "reverse_winner_mapped": reverse_mapped,
                            "mirror_enabled": mirror_enabled,
                            "uncertain_reasons": uncertain_reasons,
                            "consensus_resolved": consensus_resolved,
                            **({"escalation": escalation_details} if escalation_details else {}),
                            **(
                                {"error_redacted": redact_error(repeat_error)}
                                if repeat_error
                                else {}
                            ),
                        }
                    )
                    orientation_votes.append(
                        {
                            "forward_winner": forward_winner,
                            "reverse_winner_raw": reverse_winner_raw,
                            "reverse_winner_mapped": reverse_mapped,
                            "agree": orientation_agree,
                            "mirrored": mirror_enabled,
                            **(
                                {"error_redacted": redact_error(repeat_error)}
                                if repeat_error
                                else {}
                            ),
                        }
                    )
                else:
                    repeat_decisions.append(
                        {
                            "winner": consensus_vote,
                            "primary_vote": primary_vote,
                            "forward": forward_decision,
                            "reverse": reverse_decision,
                            "mirror_enabled": mirror_enabled,
                            "uncertain_reasons": uncertain_reasons,
                            "consensus_resolved": consensus_resolved,
                            **({"escalation": escalation_details} if escalation_details else {}),
                            **({"error": repeat_error} if repeat_error else {}),
                        }
                    )
                    orientation_votes.append(
                        {
                            "forward_winner": forward_winner,
                            "reverse_winner_raw": reverse_winner_raw,
                            "reverse_winner_mapped": reverse_mapped,
                            "agree": orientation_agree,
                            "mirrored": mirror_enabled,
                            **({"error": repeat_error} if repeat_error else {}),
                        }
                    )

            canonical_winner = mode_winner(repeat_votes)
            decision = dict(repeat_decisions[-1]) if repeat_decisions else {"winner": canonical_winner}
            decision["winner"] = canonical_winner
            pairwise_rows.append(
                {
                    "case_id": case["id"],
                    "preset": case["preset"],
                    "variant": variant,
                    "baseline_variant": baseline_variant,
                    "judge_decision": decision,
                    "repeat_votes": repeat_votes,
                    "repeat_decisions": repeat_decisions,
                    "orientation_votes": orientation_votes,
                    "mirror_enabled": mirror_enabled,
                    "pairwise_repeats_used": case_pairwise_repeats,
                    "critical_case": case_is_critical,
                }
            )

    pair_summary = summarize_pairwise(pairwise_rows)
    pair_repeat_summary = summarize_pairwise_repeat_stats(pairwise_rows, max(1, max_pairwise_repeats_used))
    family_results = summarize_pairwise_by_family(pairwise_rows, baseline_variant, max(1, max_pairwise_repeats_used))

    combined = {}
    for v in [v for v, _ in variants]:
        g = gen_summary.get(v, {})
        p = pair_summary.get(v, {})
        r = pair_repeat_summary.get(v, {})
        combined[v] = {
            **g,
            **({"pairwise_vs_baseline": p} if p else {}),
            **({"pairwise_repeat_stats": r} if r else {}),
        }

    family_pvalues: dict[str, float] = {}
    family_repeat_stddev: dict[str, float] = {}
    family_winners: dict[str, str] = {}
    critical_failures = 0
    critical_checked = 0
    generation_lookup: dict[tuple[str, str], dict[str, Any]] = {
        (row["case_id"], row["variant"]): row for row in generation_rows
    }

    for family, details in family_results.items():
        winner_variant = details.get("best_variant")
        winner_stats = details.get("best_pairwise_vs_baseline") or {}
        if not winner_variant:
            continue
        family_winners[family] = winner_variant
        wins = int(winner_stats.get("wins", 0) or 0)
        losses = int(winner_stats.get("losses", 0) or 0)
        non_tie_n = int(winner_stats.get("non_tie_n", 0) or 0)
        if non_tie_n <= 0:
            non_tie_n = max(0, wins + losses)
        family_pvalues[family] = one_sided_binom_pvalue(wins, non_tie_n)

        repeat_stddev = winner_stats.get("repeat_non_tie_winrate_stddev")
        if isinstance(repeat_stddev, (int, float)):
            family_repeat_stddev[family] = float(repeat_stddev)

        for case in cases:
            if str(case.get("preset")) != family:
                continue
            if case.get("critical_case", True) is False:
                continue
            critical_checked += 1
            gen = generation_lookup.get((case["id"], winner_variant))
            hard_pass = bool((gen or {}).get("deterministic", {}).get("hard_pass", False))
            if not hard_pass:
                critical_failures += 1

    holm_by_family = holm_adjust(family_pvalues)
    holm_max = max(holm_by_family.values()) if holm_by_family else None
    repeat_stddev_max = max(family_repeat_stddev.values()) if family_repeat_stddev else None

    summary = {
        "timestamp": dt.datetime.now().isoformat(),
        "simulated_artifacts": False,
        "provider_contract_path": provider_contract["path"],
        "draft_model": draft_model,
        "judge_model": judge_model,
        "draft_reasoning_effort": draft_reasoning_effort,
        "judge_reasoning_effort": judge_reasoning_effort,
        "cases": [c["id"] for c in cases],
        "baseline_variant": baseline_variant,
        "pairwise_selected_non_baseline_variants": selected_non_baseline,
        "pairwise_pruned_non_baseline_variants": pruned_non_baseline,
        "pairwise_top_k": args.pairwise_top_k,
        "pairwise_repeats": max(1, max_pairwise_repeats_used),
        "pairwise_mirror_mode": args.pairwise_mirror_mode,
        "pairwise_critical_repeats": int(args.pairwise_critical_repeats),
        "pairwise_noncritical_repeats": int(args.pairwise_noncritical_repeats),
        "pairwise_orientation_pairs_evaluated": orientation_pair_count,
        "pairwise_orientation_disagreement_rate": (
            round(orientation_disagreement_count / max(1, orientation_pair_count), 6)
            if orientation_pair_count > 0
            else None
        ),
        "judge_escalation": {
            "enabled": bool(args.enable_judge_escalation),
            "confidence_threshold": float(args.escalation_confidence_threshold),
            "score_margin_max": float(args.escalation_score_margin_max),
            "score_margin_points": float(args.escalation_score_margin_points),
            "on_critical": bool(args.escalation_on_critical),
            **escalation_stats,
        },
        "redact_sensitive": bool(args.redact_sensitive),
        "judge_prompt": str(judge_prompt_path),
        "judge_schema": str(judge_schema_path),
        "results": combined,
        "family_results": family_results,
        "usage_totals": {k: round(v, 4) for k, v in usage_totals.items()},
        "usage_by_role": {
            role: {k: round(v, 4) for k, v in totals.items()}
            for role, totals in usage_by_role.items()
        },
        "cache_telemetry": {
            "cached_input_tokens_total": round(float(usage_totals.get("cached_input_tokens", 0.0)), 4),
            "cached_input_share_of_input": (
                round(
                    float(usage_totals.get("cached_input_tokens", 0.0))
                    / max(1.0, float(usage_totals.get("input_tokens", 0.0))),
                    6,
                )
                if float(usage_totals.get("input_tokens", 0.0)) > 0
                else 0.0
            ),
        },
        "error_stats": {
            "model_call_count": model_call_count,
            "model_error_count": model_error_count,
            "model_timeout_count": model_timeout_count,
            "model_error_rate": round(model_error_count / max(1, model_call_count), 6),
            "model_timeout_rate": round(model_timeout_count / max(1, model_call_count), 6),
        },
        "promotion_statistics": {
            "families_evaluated": sorted(family_winners.keys()),
            "family_winners": family_winners,
            "family_binom_one_sided_pvalues": {k: round(v, 8) for k, v in family_pvalues.items()},
            "family_holm_adjusted_pvalues": {k: round(v, 8) for k, v in holm_by_family.items()},
            "family_holm_adjusted_pvalue_max": round(holm_max, 8) if holm_max is not None else None,
            "family_repeat_winrate_stddev": {k: round(v, 8) for k, v in family_repeat_stddev.items()},
            "repeat_winrate_stddev_max": round(repeat_stddev_max, 8) if repeat_stddev_max is not None else None,
            "critical_failures": critical_failures,
            "critical_failure_checked_cases": critical_checked,
        },
    }

    (out_dir / "generation_results.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in generation_rows) + "\n", encoding="utf-8")
    (out_dir / "pairwise_results.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in pairwise_rows) + "\n", encoding="utf-8")
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    all_model_calls_failed = (model_call_count > 0 and model_error_count >= model_call_count)
    if all_model_calls_failed:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": "all_model_calls_failed",
                    "out_dir": str(out_dir),
                    "summary": summary,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 2

    print(json.dumps({"ok": True, "out_dir": str(out_dir), "summary": summary}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
