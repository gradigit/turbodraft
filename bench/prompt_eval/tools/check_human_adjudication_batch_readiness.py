#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
from collections import defaultdict
from typing import Any

from parse_human_adjudication_workbook import iter_case_blocks, validate_case_block


def summarize_workbook(path: pathlib.Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    blocks = iter_case_blocks(text)
    cases: list[dict[str, Any]] = []
    seen_case_ids: set[str] = set()
    duplicate_case_ids: list[str] = []
    for meta, block in blocks:
        case = validate_case_block(meta, block)
        case_id = str(case.get("case_id") or "").strip()
        if case_id in seen_case_ids:
            duplicate_case_ids.append(case_id)
            continue
        seen_case_ids.add(case_id)
        cases.append(case)
    complete = sum(1 for case in cases if case["ready"])
    return {
        "workbook": str(path),
        "case_count": len(cases),
        "complete_case_count": complete,
        "ready_for_parse": complete == len(cases) and not duplicate_case_ids,
        "duplicate_case_ids": duplicate_case_ids,
        "cases": cases,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Report per-workbook and per-case readiness for blind human adjudication batches.")
    ap.add_argument("--workbook", action="append", required=True, help="Workbook markdown file. May be repeated.")
    ap.add_argument("--require-raters", type=int, default=2, help="Minimum complete workbook count required per case before compile.")
    ap.add_argument("--out", help="Optional JSON summary output path.")
    args = ap.parse_args()

    workbook_paths = list(dict.fromkeys(pathlib.Path(item).resolve() for item in args.workbook))
    summaries = [summarize_workbook(path) for path in workbook_paths]

    per_case: dict[str, dict[str, Any]] = {}
    coverage: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for summary in summaries:
        for case in summary["cases"]:
            coverage[str(case["case_id"])].append(
                {
                    "workbook": summary["workbook"],
                    "ready": bool(case["ready"]),
                    "errors": list(case["errors"]),
                }
            )
    for case_id, entries in sorted(coverage.items()):
        unique_entries = {entry["workbook"]: entry for entry in entries}
        complete_entries = [entry for entry in unique_entries.values() if entry["ready"]]
        per_case[case_id] = {
            "complete_rater_count": len(complete_entries),
            "required_rater_count": args.require_raters,
            "ready_for_compile": len(complete_entries) >= args.require_raters,
            "entries": list(unique_entries.values()),
        }

    ready_for_compile = bool(per_case) and all(item["ready_for_compile"] for item in per_case.values())
    payload = {
        "ok": True,
        "require_raters": args.require_raters,
        "workbook_count": len(summaries),
        "workbooks": summaries,
        "per_case": per_case,
        "ready_for_compile": ready_for_compile,
    }

    if args.out:
        out_path = pathlib.Path(args.out).resolve()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
