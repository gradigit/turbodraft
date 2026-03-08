#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import pathlib
import re
from typing import Any

CASE_META_RE = re.compile(r"<!-- TD_CASE_META (.+?) -->")
WINNER_OPTIONS = ("A", "B", "Tie", "BothBad")
CONFIDENCE_OPTIONS = ("High", "Medium", "Low")
CONFIDENCE_TO_NUMERIC = {
    "High": (68.0, 32.0, 5),
    "Medium": (61.0, 39.0, 3),
    "Low": (55.0, 45.0, 1),
}


def workbook_meta_integrity(meta: dict[str, Any]) -> str:
    payload = json.dumps(meta, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def iter_case_blocks(text: str) -> list[tuple[dict[str, Any], str]]:
    matches = list(CASE_META_RE.finditer(text))
    blocks: list[tuple[dict[str, Any], str]] = []
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
        blocks.append((meta, text[start:end]))
    return blocks


def blind_decision_section(block: str) -> str:
    marker = "### Blind decision"
    start = block.find(marker)
    if start == -1:
        raise RuntimeError("missing blind decision section")
    return block[start + len(marker):]


def parse_checked_option(block: str, label: str, options: tuple[str, ...]) -> str:
    marker = f"{label}:"
    start = block.find(marker)
    if start == -1:
        raise RuntimeError(f"missing section: {label}")
    tail = block[start + len(marker):]
    lines = tail.splitlines()
    checked: list[str] = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            if checked:
                break
            continue
        if stripped.endswith(":") and not stripped.startswith("-"):
            break
        m = re.match(r"- \[([ xX])\] (.+)$", stripped)
        if not m:
            continue
        state, value = m.groups()
        value = value.strip()
        if value in options and state.lower() == "x":
            checked.append(value)
    if len(checked) != 1:
        raise RuntimeError(f"{label} must have exactly one checked option")
    return checked[0]


def parse_note(block: str) -> str:
    marker = "Optional note:"
    start = block.find(marker)
    if start == -1:
        return ""
    tail = block[start + len(marker):]
    lines = tail.splitlines()
    notes: list[str] = []
    for line in lines:
        stripped = line.rstrip()
        if not stripped and notes:
            break
        if stripped.startswith("## Case ") or stripped.startswith("<!-- TD_CASE_META"):
            break
        if stripped.lstrip().startswith(">"):
            content = stripped.lstrip()[1:].strip()
            if content:
                notes.append(content)
        elif stripped:
            notes.append(stripped.strip())
        elif notes:
            break
    return "\n".join(notes).strip()


def derive_scores(decision: str, confidence: str, display_map: dict[str, Any]) -> tuple[str, float, float, int]:
    if decision == "Tie":
        return "Tie", 50.0, 50.0, 1
    if decision == "BothBad":
        return "BothBad", 30.0, 30.0, 1
    winner_score, loser_score, conf_num = CONFIDENCE_TO_NUMERIC[confidence]
    if decision not in {"A", "B"}:
        raise RuntimeError(f"unsupported winner decision: {decision}")
    canonical_winner = str(display_map.get(decision) or "").strip()
    if canonical_winner == "candidate_a":
        return "A", winner_score, loser_score, conf_num
    if canonical_winner == "candidate_b":
        return "B", loser_score, winner_score, conf_num
    raise RuntimeError("display_map must map checked winner to candidate_a or candidate_b")


def main() -> int:
    ap = argparse.ArgumentParser(description="Parse a filled markdown adjudication workbook into legacy-compatible answer CSV rows.")
    ap.add_argument("--workbook", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rater-id-hashed", required=True)
    args = ap.parse_args()

    workbook_path = pathlib.Path(args.workbook).resolve()
    text = workbook_path.read_text(encoding="utf-8")
    blocks = iter_case_blocks(text)
    if not blocks:
        raise RuntimeError("no TD_CASE_META blocks found")

    out_path = pathlib.Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "case_id",
        "preset_family",
        "language_tag",
        "split",
        "rater_id_hashed",
        "decision",
        "blind_decision_raw",
        "blind_confidence_label",
        "quality_a_0_100",
        "quality_b_0_100",
        "confidence_1_5",
        "defect_tags_a",
        "defect_tags_b",
        "notes",
    ]

    with out_path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for meta, block in blocks:
            case_id = str(meta.get("case_id") or "").strip()
            if not case_id:
                raise RuntimeError("case metadata missing case_id")
            decision_block = blind_decision_section(block)
            blind_winner = parse_checked_option(decision_block, "Winner", WINNER_OPTIONS)
            blind_confidence = parse_checked_option(decision_block, "Confidence", CONFIDENCE_OPTIONS)
            note = parse_note(decision_block)
            decision, quality_a, quality_b, confidence_num = derive_scores(
                blind_winner,
                blind_confidence,
                dict(meta.get("display_map") or {}),
            )
            writer.writerow(
                {
                    "case_id": case_id,
                    "preset_family": str(meta.get("preset_family") or "").strip(),
                    "language_tag": str(meta.get("language_tag") or "").strip(),
                    "split": str(meta.get("split") or "").strip(),
                    "rater_id_hashed": args.rater_id_hashed,
                    "decision": decision,
                    "blind_decision_raw": blind_winner,
                    "blind_confidence_label": blind_confidence,
                    "quality_a_0_100": f"{quality_a:.1f}",
                    "quality_b_0_100": f"{quality_b:.1f}",
                    "confidence_1_5": str(confidence_num),
                    "defect_tags_a": "",
                    "defect_tags_b": "",
                    "notes": note,
                }
            )

    print(
        json.dumps(
            {
                "ok": True,
                "workbook": str(workbook_path),
                "out": str(out_path),
                "case_count": len(blocks),
                "rater_id_hashed": args.rater_id_hashed,
                "score_mode": "derived_from_blind_winner_and_confidence",
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
