#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
from typing import Any

from build_human_adjudication_packet import load_jsonl


def short_lang(tag: str) -> str:
    lowered = tag.strip().lower()
    if lowered.startswith("ko"):
        return "ko"
    if lowered.startswith("en"):
        return "en"
    return "xx"


def build_blind_case_id(batch_label: str, language_tag: str, index: int) -> str:
    return f"{batch_label}_{short_lang(language_tag)}_{index:03d}"


def blind_row(raw: dict[str, Any], *, blind_case_id: str) -> dict[str, Any]:
    return {
        "case_id": blind_case_id,
        "preset_family": str(raw.get("preset_family") or "").strip(),
        "language_tag": str(raw.get("language_tag") or "").strip(),
        "split": str(raw.get("split") or "").strip(),
        "draft_prompt": str(raw.get("draft_prompt") or "").strip(),
        "candidate_a": str(raw.get("candidate_a") or "").strip(),
        "candidate_b": str(raw.get("candidate_b") or "").strip(),
    }


def mapping_row(raw: dict[str, Any], *, blind_case_id: str) -> dict[str, Any]:
    return {
        "blind_case_id": blind_case_id,
        "source_case_id": str(raw.get("case_id") or raw.get("id") or "").strip(),
        "preset_family": str(raw.get("preset_family") or "").strip(),
        "language_tag": str(raw.get("language_tag") or "").strip(),
        "split": str(raw.get("split") or "").strip(),
        "internal_expected_winner_seed": str(raw.get("internal_expected_winner_seed") or "").strip() or None,
        "candidate_a_source": str(raw.get("candidate_a_source") or "").strip() or None,
        "candidate_b_source": str(raw.get("candidate_b_source") or "").strip() or None,
        "source_ids": list(raw.get("source_ids") or []),
        "notes": str(raw.get("notes") or "").strip() or None,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Create a blind-safe adjudication candidate set from an internal curated candidate JSONL.")
    ap.add_argument("--source", required=True)
    ap.add_argument("--blind-out", required=True)
    ap.add_argument("--mapping-out", required=True)
    ap.add_argument("--batch-label", required=True, help="Fresh blind case-id prefix, e.g. batch3blind")
    args = ap.parse_args()

    source_path = pathlib.Path(args.source).resolve()
    rows = load_jsonl(source_path)
    if not rows:
        raise RuntimeError("no candidate rows found")

    blind_rows: list[dict[str, Any]] = []
    mapping_rows: list[dict[str, Any]] = []
    for idx, raw in enumerate(rows, start=1):
        language_tag = str(raw.get("language_tag") or "").strip()
        blind_case_id = build_blind_case_id(args.batch_label, language_tag, idx)
        blind_rows.append(blind_row(raw, blind_case_id=blind_case_id))
        mapping_rows.append(mapping_row(raw, blind_case_id=blind_case_id))

    blind_out = pathlib.Path(args.blind_out).resolve()
    mapping_out = pathlib.Path(args.mapping_out).resolve()
    blind_out.parent.mkdir(parents=True, exist_ok=True)
    mapping_out.parent.mkdir(parents=True, exist_ok=True)
    with blind_out.open("w", encoding="utf-8") as fh:
        for row in blind_rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    with mapping_out.open("w", encoding="utf-8") as fh:
        for row in mapping_rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    print(json.dumps({
        "ok": True,
        "source": str(source_path),
        "blind_out": str(blind_out),
        "mapping_out": str(mapping_out),
        "case_count": len(blind_rows),
        "batch_label": args.batch_label,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
