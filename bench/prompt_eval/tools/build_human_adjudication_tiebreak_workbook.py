#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import pathlib
from collections import defaultdict

from build_human_adjudication_packet import load_jsonl, normalize_case
from build_human_adjudication_workbook import render_workbook


def load_answers(path: pathlib.Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as fh:
        return [dict(row) for row in csv.DictReader(fh)]


def needs_tiebreak(rows: list[dict[str, str]]) -> bool:
    decisions = {str(row.get("decision") or "").strip() for row in rows if str(row.get("decision") or "").strip()}
    if not decisions:
        return False
    if "Tie" in decisions or "BothBad" in decisions:
        return True
    if len(decisions) > 1:
        return True
    if any(str(row.get("blind_confidence_label") or "").strip() == "Low" for row in rows):
        return True
    if any(str(row.get("confidence_1_5") or "").strip() == "1" for row in rows):
        return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description="Build a blind tie-break workbook from parsed adjudication answer CSVs.")
    ap.add_argument("--candidates", required=True)
    ap.add_argument("--answers", nargs="+", required=True, help="One or more parsed answer CSV files")
    ap.add_argument("--workbook-out", required=True)
    ap.add_argument("--title", default="TurboDraft Human Adjudication Workbook — Tie-break")
    ap.add_argument("--seed", default="0")
    ap.add_argument("--rater-label", default="tiebreak")
    args = ap.parse_args()

    candidate_rows = load_jsonl(pathlib.Path(args.candidates).resolve())
    cases = [normalize_case(row, i + 1) for i, row in enumerate(candidate_rows)]
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for answer_path in args.answers:
        for row in load_answers(pathlib.Path(answer_path).resolve()):
            case_id = str(row.get("case_id") or "").strip()
            if case_id:
                grouped[case_id].append(row)

    selected = [case for case in cases if needs_tiebreak(grouped.get(case.case_id, []))]
    if not selected:
        raise RuntimeError("no cases require tie-break")

    workbook_path = pathlib.Path(args.workbook_out).resolve()
    workbook_path.parent.mkdir(parents=True, exist_ok=True)
    workbook_path.write_text(
        render_workbook(title=args.title, rows=[case.__dict__ for case in selected], seed=str(args.seed), rater_label=str(args.rater_label)),
        encoding="utf-8",
    )

    print(json.dumps({
        "ok": True,
        "candidates": str(pathlib.Path(args.candidates).resolve()),
        "workbook_out": str(workbook_path),
        "case_count": len(selected),
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
