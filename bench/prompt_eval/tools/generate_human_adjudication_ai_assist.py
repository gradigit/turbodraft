#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Any

from provider_contract import DEFAULT_PROVIDER_CONTRACT, load_provider_contract

TOOLS_DIR = pathlib.Path(__file__).resolve().parent
PARENT_DIR = TOOLS_DIR.parent
if str(PARENT_DIR) not in sys.path:
    sys.path.insert(0, str(PARENT_DIR))

from run_codex_prompt_eval import run_provider_exec

CASE_META_RE = re.compile(r"<!-- TD_CASE_META (.+?) -->")
CODE_BLOCK_RE = re.compile(r"```text\n(.*?)\n```", re.DOTALL)
JSON_OBJECT_RE = re.compile(r"\{.*\}", re.DOTALL)
VALID_WINNERS = {"A", "B", "Tie", "BothBad"}
VALID_CONFIDENCE = {"High", "Medium", "Low"}


def provider_display_label(provider: dict[str, str] | None) -> str:
    if not provider:
        return "Simulated AI"
    runner = str(provider.get("runner") or "").strip().lower()
    model = str(provider.get("model") or "").strip()
    if runner == "auggie" and model == "gpt5.4":
        return "Auggie GPT-5.4"
    if runner == "gemini":
        return f"Gemini {model}".strip()
    if runner == "claude":
        return f"Claude {model}".strip()
    if runner == "codex":
        return f"Codex {model}".strip()
    if runner and model:
        return f"{runner} {model}"
    if runner:
        return runner
    return "AI"


def iter_case_blocks(text: str) -> list[tuple[dict[str, Any], str]]:
    matches = list(CASE_META_RE.finditer(text))
    out: list[tuple[dict[str, Any], str]] = []
    for idx, match in enumerate(matches):
        start = match.end()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(text)
        meta = json.loads(match.group(1))
        if not isinstance(meta, dict):
            raise RuntimeError("case metadata comment must be a JSON object")
        out.append((meta, text[start:end]))
    return out


def extract_text_sections(block: str) -> tuple[str, str, str]:
    chunks = CODE_BLOCK_RE.findall(block)
    if len(chunks) < 3:
        raise RuntimeError("case block missing draft/candidate text sections")
    draft, cand_a, cand_b = chunks[:3]
    return draft.strip(), cand_a.strip(), cand_b.strip()


def extract_last_json_object(raw: str) -> Any:
    matches = list(JSON_OBJECT_RE.finditer(raw))
    if not matches:
        raise RuntimeError("no JSON object found in provider output")
    for match in reversed(matches):
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            continue
    raise RuntimeError("provider output did not contain valid JSON object")


def simulate_assist(candidate_a: str, candidate_b: str) -> dict[str, str]:
    wa = len(candidate_a.split())
    wb = len(candidate_b.split())
    diff = wa - wb
    if abs(diff) <= 5:
        return {"winner": "Tie", "confidence": "Low", "rationale": "The prompts look similarly strong at a superficial level; this needs closer human review."}
    winner = "A" if diff > 0 else "B"
    adiff = abs(diff)
    confidence = "High" if adiff >= 60 else "Medium" if adiff >= 20 else "Low"
    rationale = (
        f"Candidate {winner} appears more specific and operationally detailed than the other option in this quick AI pass."
    )
    return {"winner": winner, "confidence": confidence, "rationale": rationale}


def build_prompt(draft: str, candidate_a: str, candidate_b: str) -> str:
    return (
        "You are producing a second-opinion appendix for a human prompt-quality adjudicator. "
        "Compare Candidate A and Candidate B as prompt-engineering rewrites of the draft. "
        "Judge which is the better engineered prompt based on objective/constraint preservation, usable execution contract, structure, language correctness, and avoiding filler or scope fabrication. "
        "Return JSON only with keys winner, confidence, rationale. "
        "winner must be one of A, B, Tie, BothBad. confidence must be one of High, Medium, Low. "
        "Keep rationale to one short sentence.\n\n"
        f"Draft:\n{draft}\n\nCandidate A:\n{candidate_a}\n\nCandidate B:\n{candidate_b}\n"
    )


def normalize_response(data: Any) -> dict[str, str]:
    if not isinstance(data, dict):
        raise RuntimeError("AI assist response must be a JSON object")
    winner = str(data.get("winner") or "").strip()
    confidence = str(data.get("confidence") or "").strip()
    rationale = str(data.get("rationale") or "").strip()
    if winner not in VALID_WINNERS:
        raise RuntimeError(f"invalid AI assist winner: {winner!r}")
    if confidence not in VALID_CONFIDENCE:
        raise RuntimeError(f"invalid AI assist confidence: {confidence!r}")
    if not rationale:
        raise RuntimeError("AI assist rationale missing")
    return {"winner": winner, "confidence": confidence, "rationale": rationale}


def canonical_winner(display_winner: str, display_map: dict[str, Any]) -> str:
    if display_winner in {"Tie", "BothBad"}:
        return display_winner
    mapped = str(display_map.get(display_winner) or "").strip()
    if mapped == "candidate_a":
        return "A"
    if mapped == "candidate_b":
        return "B"
    raise RuntimeError("display_map missing canonical mapping for AI assist winner")


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate a provider-backed AI assist appendix for human adjudication workbooks.")
    ap.add_argument("--workbook", required=True)
    ap.add_argument("--appendix-out", required=True)
    ap.add_argument("--jsonl-out", required=True)
    ap.add_argument("--provider-contract", default=DEFAULT_PROVIDER_CONTRACT)
    ap.add_argument("--simulate-no-provider", action="store_true")
    ap.add_argument("--timeout-s", type=int, default=240)
    args = ap.parse_args()

    repo = pathlib.Path(__file__).resolve().parents[3]
    workbook_path = pathlib.Path(args.workbook).resolve()
    workbook_text = workbook_path.read_text(encoding="utf-8")
    blocks = iter_case_blocks(workbook_text)
    if not blocks:
        raise RuntimeError("no TD_CASE_META blocks found")

    provider: dict[str, str] | None = None
    if not args.simulate_no_provider:
        contract = load_provider_contract(repo, args.provider_contract)
        provider = contract["providers"].get("judge_secondary")
        if not provider:
            raise RuntimeError("provider contract missing judge_secondary for AI assist")
    provider_label = provider_display_label(provider)

    appendix_lines: list[str] = [
        "# TurboDraft Human Adjudication — AI Assist Appendix\n\n",
        "> Open this only **after** recording the blind human decision.\n\n",
        f"> Current assist model: **{provider_label}**.\n\n",
    ]
    json_rows: list[dict[str, Any]] = []

    for meta, block in blocks:
        case_id = str(meta.get("case_id") or "").strip()
        if not case_id:
            raise RuntimeError("case metadata missing case_id")
        draft, candidate_a, candidate_b = extract_text_sections(block)
        if args.simulate_no_provider:
            verdict = simulate_assist(candidate_a, candidate_b)
        else:
            prompt = build_prompt(draft, candidate_a, candidate_b)
            raw_text, _events = run_provider_exec(prompt=prompt, provider=provider, timeout_s=args.timeout_s)
            verdict = normalize_response(extract_last_json_object(raw_text))
        json_rows.append({
            "case_id": case_id,
            "winner": verdict["winner"],
            "canonical_winner": canonical_winner(verdict["winner"], dict(meta.get("display_map") or {})),
            "confidence": verdict["confidence"],
            "rationale": verdict["rationale"],
            "provider_label": provider_label,
        })
        appendix_lines.append(f"## Case — `{case_id}`\n")
        appendix_lines.append(f"- AI pick: {verdict['winner']}\n")
        appendix_lines.append(f"- AI confidence: {verdict['confidence']}\n")
        appendix_lines.append(f"- AI rationale: {verdict['rationale']}\n")
        appendix_lines.append("- Blind winner (immutable for lock): ______\n")
        appendix_lines.append("- Post-assist winner (secondary): ______\n")
        appendix_lines.append("- Human final status after viewing AI:\n")
        appendix_lines.append("  - [ ] Kept original decision\n")
        appendix_lines.append("  - [ ] Changed decision after AI review\n")
        appendix_lines.append("  - [ ] Still unresolved; escalate to tie-break\n\n")

    appendix_path = pathlib.Path(args.appendix_out).resolve()
    appendix_path.parent.mkdir(parents=True, exist_ok=True)
    appendix_path.write_text("".join(appendix_lines), encoding="utf-8")

    jsonl_path = pathlib.Path(args.jsonl_out).resolve()
    jsonl_path.parent.mkdir(parents=True, exist_ok=True)
    with jsonl_path.open("w", encoding="utf-8") as fh:
        for row in json_rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    print(json.dumps({
        "ok": True,
        "workbook": str(workbook_path),
        "appendix_out": str(appendix_path),
        "jsonl_out": str(jsonl_path),
        "case_count": len(json_rows),
        "simulate_no_provider": bool(args.simulate_no_provider),
        "provider_role": "judge_secondary",
        "provider_label": provider_label,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
