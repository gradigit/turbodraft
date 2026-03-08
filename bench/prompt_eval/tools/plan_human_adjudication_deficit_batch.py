#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
from collections import Counter
from typing import Any

from build_human_adjudication_packet import load_jsonl, normalize_case

JUDGE_SPLITS = ("dev", "tune", "sealed_test")


def load_pairwise_counts(paths: list[pathlib.Path]) -> tuple[Counter[str], Counter[str], Counter[str], int, set[str]]:
    family_counts: Counter[str] = Counter()
    language_counts: Counter[str] = Counter()
    split_counts: Counter[str] = Counter()
    total = 0
    case_ids: set[str] = set()
    for path in paths:
        for row in load_jsonl(path):
            item_type = str(row.get("item_type") or "").strip()
            if item_type and item_type != "pairwise":
                continue
            family = str(row.get("preset_family") or "").strip()
            language_tag = str(row.get("language_tag") or "").strip()
            split = str(row.get("split") or "").strip()
            if not family or not language_tag or split not in JUDGE_SPLITS:
                continue
            case_id = str(((row.get("review_metadata") or {}).get("source_case_id")) or row.get("case_id") or row.get("id") or "").strip()
            if case_id:
                case_ids.add(case_id)
            family_counts[family] += 1
            language_counts[language_tag] += 1
            split_counts[split] += 1
            total += 1
    return family_counts, language_counts, split_counts, total, case_ids


def candidate_score(
    *,
    case: Any,
    family_counts: Counter[str],
    language_counts: Counter[str],
    split_counts: Counter[str],
    total_pairwise: int,
    pairwise_target: int,
    sealed_target: int,
    family_target: int,
    language_target: int,
    max_family_share: float,
) -> tuple[float, tuple[Any, ...]]:
    family = case.preset_family
    language = case.language_tag
    split = case.split
    family_count = family_counts[family]
    language_count = language_counts[language]
    sealed_count = split_counts["sealed_test"]
    projected_total = total_pairwise + 1
    projected_family_share = (family_count + 1) / projected_total if projected_total else 1.0

    score = 0.0
    if total_pairwise < pairwise_target:
        score += 10.0
    if split == "sealed_test" and sealed_count < sealed_target:
        score += 1000.0 + float(sealed_target - sealed_count)
    if family_count < family_target:
        score += 100.0 + float(family_target - family_count)
    if language_count < language_target:
        score += 50.0 + float(language_target - language_count)
    if split == "tune":
        score += 2.0
    if projected_family_share > max_family_share:
        score -= 500.0 + projected_family_share * 100.0
    tie_break = (
        -split_counts[split],
        -family_count,
        -language_count,
        case.case_id,
    )
    return score, tie_break


def main() -> int:
    ap = argparse.ArgumentParser(description="Select the next blind adjudication candidate pack based on lock-floor deficits only.")
    ap.add_argument("--current", action="append", default=[], help="Existing canonical adjudicated JSONL (pairwise rows counted). May be repeated.")
    ap.add_argument("--candidates", action="append", required=True, help="Candidate pair JSONL file(s). May be repeated.")
    ap.add_argument("--out-jsonl", required=True, help="Selected candidate pack output path.")
    ap.add_argument("--summary-out", help="Optional JSON summary path.")
    ap.add_argument("--max-cases", type=int, default=12)
    ap.add_argument("--pairwise-target", type=int, default=500)
    ap.add_argument("--sealed-target", type=int, default=200)
    ap.add_argument("--family-target", type=int, default=40)
    ap.add_argument("--language-target", type=int, default=80)
    ap.add_argument("--max-family-share", type=float, default=0.40)
    args = ap.parse_args()

    current_paths = [pathlib.Path(item).resolve() for item in args.current]
    candidate_paths = [pathlib.Path(item).resolve() for item in args.candidates]
    family_counts, language_counts, split_counts, total_pairwise, current_case_ids = load_pairwise_counts(current_paths)
    current_family_counts = Counter(family_counts)
    current_language_counts = Counter(language_counts)
    current_split_counts = Counter(split_counts)
    current_total_pairwise = total_pairwise

    candidate_entries: list[tuple[str, dict[str, Any], Any]] = []
    seen_case_ids: set[str] = set()
    for path in candidate_paths:
        for index, row in enumerate(load_jsonl(path), start=1):
            case = normalize_case(row, index)
            if case.case_id in current_case_ids:
                continue
            if case.case_id in seen_case_ids:
                continue
            seen_case_ids.add(case.case_id)
            candidate_entries.append((case.case_id, row, case))

    selected: list[dict[str, Any]] = []
    selected_case_ids: list[str] = []
    remaining = list(candidate_entries)
    while remaining and len(selected) < args.max_cases:
        scored: list[tuple[float, tuple[Any, ...], str, dict[str, Any], Any]] = []
        for case_id, row, case in remaining:
            score, tie_break = candidate_score(
                case=case,
                family_counts=family_counts,
                language_counts=language_counts,
                split_counts=split_counts,
                total_pairwise=total_pairwise,
                pairwise_target=args.pairwise_target,
                sealed_target=args.sealed_target,
                family_target=args.family_target,
                language_target=args.language_target,
                max_family_share=args.max_family_share,
            )
            scored.append((score, tie_break, case_id, row, case))
        scored.sort(key=lambda item: (item[0], item[1]), reverse=True)
        score, _, case_id, row, case = scored[0]
        if score <= 0:
            break
        selected.append(row)
        selected_case_ids.append(case_id)
        family_counts[case.preset_family] += 1
        language_counts[case.language_tag] += 1
        split_counts[case.split] += 1
        total_pairwise += 1
        remaining = [item for item in remaining if item[0] != case_id]

    out_path = pathlib.Path(args.out_jsonl).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as fh:
        for row in selected:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    payload = {
        "ok": True,
        "selected_case_count": len(selected),
        "selected_case_ids": selected_case_ids,
        "selected_out": str(out_path),
        "current_pairwise_labels": current_total_pairwise,
        "projected_pairwise_labels": total_pairwise,
        "current_counts_by_family": dict(sorted(current_family_counts.items())),
        "current_counts_by_language": dict(sorted(current_language_counts.items())),
        "current_counts_by_split": {split: int(current_split_counts.get(split, 0)) for split in JUDGE_SPLITS},
        "projected_counts_by_family": dict(sorted(family_counts.items())),
        "projected_counts_by_language": dict(sorted(language_counts.items())),
        "projected_counts_by_split": {split: int(split_counts.get(split, 0)) for split in JUDGE_SPLITS},
        "remaining_deficits": {
            "pairwise_labels": max(0, args.pairwise_target - total_pairwise),
            "sealed_labels": max(0, args.sealed_target - int(split_counts.get("sealed_test", 0))),
            "families_below_target": {
                family: max(0, args.family_target - count)
                for family, count in sorted(family_counts.items())
                if count < args.family_target
            },
            "languages_below_target": {
                language: max(0, args.language_target - count)
                for language, count in sorted(language_counts.items())
                if count < args.language_target
            },
        },
    }

    if args.summary_out:
        summary_path = pathlib.Path(args.summary_out).resolve()
        summary_path.parent.mkdir(parents=True, exist_ok=True)
        summary_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
