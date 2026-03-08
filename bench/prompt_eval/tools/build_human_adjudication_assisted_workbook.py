#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
from typing import Any

CASE_META_RE = re.compile(r"<!-- TD_CASE_META (.+?) -->")
CODE_BLOCK_RE = re.compile(r"```text\n(.*?)\n```", re.DOTALL)


def workbook_meta_integrity(meta: dict[str, Any]) -> str:
    payload = json.dumps(meta, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def iter_case_blocks(text: str) -> list[tuple[dict[str, Any], str]]:
    matches = list(CASE_META_RE.finditer(text))
    out: list[tuple[dict[str, Any], str]] = []
    for idx, match in enumerate(matches):
        start = match.end()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(text)
        meta = json.loads(match.group(1))
        if not isinstance(meta, dict):
            raise RuntimeError("case metadata comment must be a JSON object")
        integrity = str(meta.get("integrity_sha256") or "").strip()
        check_meta = dict(meta)
        check_meta.pop("integrity_sha256", None)
        if not integrity or integrity != workbook_meta_integrity(check_meta):
            raise RuntimeError("case metadata integrity check failed")
        out.append((meta, text[start:end]))
    return out


def extract_text_sections(block: str) -> tuple[str, str, str]:
    chunks = CODE_BLOCK_RE.findall(block)
    if len(chunks) < 3:
        raise RuntimeError("case block missing draft/candidate text sections")
    draft, cand_a, cand_b = chunks[:3]
    return draft.strip(), cand_a.strip(), cand_b.strip()


def load_jsonl(path: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            item = json.loads(line)
            if not isinstance(item, dict):
                raise RuntimeError("assist jsonl rows must be objects")
            rows.append(item)
    return rows


def display_winner_from_canonical(canonical: str, display_map: dict[str, Any]) -> str:
    if canonical in {"Tie", "BothBad"}:
        return canonical
    target = "candidate_a" if canonical == "A" else "candidate_b" if canonical == "B" else ""
    if not target:
        raise RuntimeError(f"unsupported canonical winner: {canonical!r}")
    for display_label, mapped in display_map.items():
        if display_label in {"A", "B"} and str(mapped).strip() == target:
            return display_label
    raise RuntimeError("display_map does not map canonical winner to a visible label")


def render_workbook(
    *,
    title: str,
    blind_blocks: list[tuple[dict[str, Any], str]],
    assist_by_case: dict[str, dict[str, Any]],
) -> str:
    parts: list[str] = []
    parts.append(f"# {title}\n\n")
    parts.append("> This is the **AI-assisted expansion lane**.\n")
    parts.append("> It is useful for throughput and disagreement analysis, but it is **not lock-grade blind evidence**.\n\n")
    parts.append("## Instructions\n")
    parts.append("- Review the AI assessment, then record your own final decision in this file.\n")
    parts.append("- Required per case: relation to AI + final winner + confidence.\n")
    parts.append("- Optional per case: short note.\n")
    parts.append("- Use this lane when the blind-only task is too difficult for a non-expert rater.\n\n")
    parts.append("## Confidence rubric\n")
    parts.append("- **High** — you clearly agree or clearly reject the AI assessment.\n")
    parts.append("- **Medium** — you have a likely decision, but there is real ambiguity.\n")
    parts.append("- **Low** — still difficult; good candidate for expert review or execution-based check.\n")

    for index, (meta, block) in enumerate(blind_blocks, start=1):
        case_id = str(meta.get("case_id") or "").strip()
        if not case_id:
            raise RuntimeError("case metadata missing case_id")
        assist = assist_by_case.get(case_id)
        if not assist:
            raise RuntimeError(f"missing assist row for case_id={case_id}")
        display_map = dict(meta.get("display_map") or {})
        assist_canonical_winner = str(assist.get("canonical_winner") or "").strip()
        assist_display_winner = display_winner_from_canonical(assist_canonical_winner, display_map)
        assist_confidence = str(assist.get("confidence") or "").strip()
        assist_rationale = str(assist.get("rationale") or "").strip()
        assist_model_label = str(assist.get("provider_label") or "AI").strip() or "AI"
        draft, candidate_a, candidate_b = extract_text_sections(block)

        out_meta = {
            "case_id": case_id,
            "preset_family": str(meta.get("preset_family") or "").strip(),
            "language_tag": str(meta.get("language_tag") or "").strip(),
            "split": str(meta.get("split") or "").strip(),
            "display_map": display_map,
            "assist_model_label": assist_model_label,
            "assist_display_winner": assist_display_winner,
            "assist_canonical_winner": assist_canonical_winner,
            "assist_confidence": assist_confidence,
        }
        out_meta["integrity_sha256"] = workbook_meta_integrity(out_meta)

        parts.append("\n")
        parts.append(f"<!-- TD_CASE_META {json.dumps(out_meta, ensure_ascii=False)} -->\n")
        parts.append(f"## Case {index:02d}\n\n")
        parts.append("### Draft\n")
        parts.append(f"```text\n{draft}\n```\n")
        parts.append("### Candidate A\n")
        parts.append(f"```text\n{candidate_a}\n```\n")
        parts.append("### Candidate B\n")
        parts.append(f"```text\n{candidate_b}\n```\n")
        parts.append("### AI assessment\n")
        parts.append(f"- Model: {assist_model_label}\n")
        parts.append(f"- AI pick: {assist_display_winner}\n")
        parts.append(f"- AI confidence: {assist_confidence}\n")
        parts.append(f"- AI rationale: {assist_rationale}\n\n")
        parts.append("### Human final decision\n")
        parts.append("Relation to AI:\n")
        parts.append("- [ ] Agree\n")
        parts.append("- [ ] Disagree / override\n\n")
        parts.append("Final winner:\n")
        parts.append("- [ ] A\n")
        parts.append("- [ ] B\n")
        parts.append("- [ ] Tie\n")
        parts.append("- [ ] BothBad\n\n")
        parts.append("Confidence:\n")
        parts.append("- [ ] High\n")
        parts.append("- [ ] Medium\n")
        parts.append("- [ ] Low\n\n")
        parts.append("Optional note:\n")
        parts.append("> \n")
    return "".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser(description="Build an AI-assisted markdown workbook for the non-lock expansion adjudication lane.")
    ap.add_argument("--blind-workbook", required=True)
    ap.add_argument("--assist-jsonl", required=True)
    ap.add_argument("--workbook-out", required=True)
    ap.add_argument("--title", default="TurboDraft Human Adjudication Workbook — AI-Assisted Expansion Lane")
    args = ap.parse_args()

    blind_workbook = pathlib.Path(args.blind_workbook).resolve()
    assist_jsonl = pathlib.Path(args.assist_jsonl).resolve()
    blind_blocks = iter_case_blocks(blind_workbook.read_text(encoding="utf-8"))
    if not blind_blocks:
        raise RuntimeError("no TD_CASE_META blocks found in blind workbook")
    assist_rows = load_jsonl(assist_jsonl)
    assist_by_case = {str(row.get("case_id") or "").strip(): row for row in assist_rows}

    out_path = pathlib.Path(args.workbook_out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        render_workbook(title=args.title, blind_blocks=blind_blocks, assist_by_case=assist_by_case),
        encoding="utf-8",
    )

    print(
        json.dumps(
            {
                "ok": True,
                "blind_workbook": str(blind_workbook),
                "assist_jsonl": str(assist_jsonl),
                "workbook_out": str(out_path),
                "case_count": len(blind_blocks),
                "lane": "assisted_expansion",
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
