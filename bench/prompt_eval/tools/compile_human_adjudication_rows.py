#!/usr/bin/env python3
from __future__ import annotations
import argparse
import csv
import json
import pathlib
from collections import Counter, defaultdict
from statistics import mean
from typing import Any
from build_human_adjudication_packet import load_jsonl, normalize_case
VALID_DECISIONS = {"A", "B", "Tie", "BothBad"}
LOCK_GRADE_LANES = {"blind_gold", "guided_blind_core"}


def parse_tags(value: str) -> list[str]:
    raw = (value or "").strip()
    if not raw:
        return []
    if "|" in raw:
        return [part.strip() for part in raw.split("|") if part.strip()]
    if "," in raw:
        return [part.strip() for part in raw.split(",") if part.strip()]
    return [raw]
def mean_score(values: list[float]) -> float:
    return round(mean(values), 2)


def load_answers(path: pathlib.Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as fh:
        return [{**dict(row), "__answer_source": str(path)} for row in csv.DictReader(fh)]


def resolve_winner(decisions: list[str]) -> str | None:
    vote_counts = Counter(decisions)
    threshold = len(decisions) / 2.0
    if vote_counts.get("A", 0) > vote_counts.get("B", 0) and vote_counts.get("A", 0) > threshold:
        return "A"
    if vote_counts.get("B", 0) > vote_counts.get("A", 0) and vote_counts.get("B", 0) > threshold:
        return "B"
    if vote_counts.get("Tie", 0) > 0 or vote_counts.get("BothBad", 0) > 0:
        return None
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Compile human answer-sheet rows into canonical gold/perturbation/pairwise JSONL rows.")
    ap.add_argument("--candidates", required=True)
    ap.add_argument("--answers", action="append", required=True, help="Parsed answer CSV. May be repeated for multiple raters/workbooks.")
    ap.add_argument("--out", required=True)
    ap.add_argument("--provenance-source", required=True)
    ap.add_argument("--provenance-artifact", required=True)
    ap.add_argument("--min-raters", type=int, default=2)
    ap.add_argument("--skip-unresolved", action="store_true")
    args = ap.parse_args()
    candidate_rows = load_jsonl(pathlib.Path(args.candidates).resolve())
    cases = {c.case_id: c for c in (normalize_case(row, i + 1) for i, row in enumerate(candidate_rows))}
    answer_paths = list(dict.fromkeys(pathlib.Path(item).resolve() for item in args.answers))
    answers: list[dict[str, str]] = []
    for path in answer_paths:
        answers.extend(load_answers(path))
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in answers:
        grouped[str(row.get("case_id") or "").strip()].append(row)
    out_rows: list[dict[str, Any]] = []
    unresolved: list[str] = []
    missing: list[str] = []
    for case_id, case in cases.items():
        rows = grouped.get(case_id, [])
        unique_rows: list[dict[str, str]] = []
        seen_raters: dict[str, str] = {}
        for row in rows:
            rater_id = str(row.get("rater_id_hashed") or "").strip()
            if not rater_id:
                raise RuntimeError(f"{case_id}: rater_id_hashed required for every answer row")
            source = str(row.get("__answer_source") or "").strip()
            prior_source = seen_raters.get(rater_id)
            if prior_source is not None:
                raise RuntimeError(
                    f"{case_id}: duplicate rater_id_hashed {rater_id!r} "
                    f"across answer sources {prior_source!r} and {source!r}"
                )
            seen_raters[rater_id] = source
            unique_rows.append(row)
        if len(unique_rows) < args.min_raters:
            missing.append(case_id)
            continue
        decisions = []
        rater_ids: list[str] = []
        score_a: list[float] = []
        score_b: list[float] = []
        tags_a: set[str] = set()
        tags_b: set[str] = set()
        blind_vote_details: list[dict[str, Any]] = []
        lane_values: set[str] = set()
        for row in unique_rows:
            decision = str(row.get("decision") or "").strip()
            if decision not in VALID_DECISIONS:
                raise RuntimeError(f"{case_id}: decision must be one of {sorted(VALID_DECISIONS)}")
            rater_id = str(row.get("rater_id_hashed") or "").strip()
            try:
                qa = float(str(row.get("quality_a_0_100") or "").strip())
                qb = float(str(row.get("quality_b_0_100") or "").strip())
            except ValueError as exc:
                raise RuntimeError(f"{case_id}: quality_a_0_100 and quality_b_0_100 required") from exc
            decisions.append(decision)
            rater_ids.append(rater_id)
            score_a.append(qa)
            score_b.append(qb)
            tags_a.update(parse_tags(str(row.get("defect_tags_a") or "")))
            tags_b.update(parse_tags(str(row.get("defect_tags_b") or "")))
            lane = str(row.get("decision_mode") or "blind_gold").strip() or "blind_gold"
            if lane not in LOCK_GRADE_LANES | {"assisted_expansion"}:
                raise RuntimeError(f"{case_id}: unsupported decision_mode {lane!r}")
            lane_values.add(lane)
            blind_vote_details.append(
                {
                    "rater_id_hashed": rater_id,
                    "blind_decision_raw": str(row.get("blind_decision_raw") or decision).strip(),
                    "blind_confidence_label": str(row.get("blind_confidence_label") or "").strip() or None,
                    "canonical_decision": decision,
                    "note": str(row.get("notes") or "").strip() or None,
                    "decision_mode": lane,
                    "assist_model_label": str(row.get("assist_model_label") or "").strip() or None,
                    "assist_display_winner": str(row.get("assist_display_winner") or "").strip() or None,
                    "assist_canonical_winner": str(row.get("assist_canonical_winner") or "").strip() or None,
                    "assist_confidence_label": str(row.get("assist_confidence_label") or "").strip() or None,
                    "assist_relation": str(row.get("assist_relation") or "").strip() or None,
                }
            )
        adjudication_lane = lane_values.pop() if len(lane_values) == 1 else "mixed"
        winner = resolve_winner(decisions)
        if winner is None:
            if args.skip_unresolved:
                unresolved.append(case_id)
                continue
            raise RuntimeError(f"{case_id}: unresolved adjudication; use --skip-unresolved or resolve tie/bothbad cases")
        review_metadata = {
            "source_case_id": case_id,
            "consensus_method": "majority_no_tie",
            "blind_vote_details": blind_vote_details,
            "adjudication_lane": adjudication_lane,
            "lock_eligible": adjudication_lane in LOCK_GRADE_LANES,
        }
        gold_id = f"{case_id}__gold"
        perturb_id = f"{case_id}__perturbation"
        pair_id = f"{case_id}__pairwise"
        if winner == "A":
            gold_text, perturb_text = case.candidate_a, case.candidate_b
            gold_scores, perturb_scores = score_a, score_b
            gold_tags, perturb_tags = sorted(tags_a), sorted(tags_b)
        else:
            gold_text, perturb_text = case.candidate_b, case.candidate_a
            gold_scores, perturb_scores = score_b, score_a
            gold_tags, perturb_tags = sorted(tags_b), sorted(tags_a)
        out_rows.extend([
            {
                "id": gold_id,
                "preset_family": case.preset_family,
                "item_type": "gold",
                "language_tag": case.language_tag,
                "split": case.split,
                "prompt_text": gold_text,
                "absolute_score_0_100": mean_score(gold_scores),
                "error_tags": gold_tags,
                "adjudication_status": "adjudicated",
                "rater_count": len(rater_ids),
                "blinded_ratings": gold_scores,
                "rater_ids_hashed": rater_ids,
                "provenance_source": args.provenance_source,
                "provenance_artifact": args.provenance_artifact,
                "label_source_class": "human_adjudicated",
                "review_metadata": review_metadata,
            },
            {
                "id": perturb_id,
                "preset_family": case.preset_family,
                "item_type": "perturbation",
                "language_tag": case.language_tag,
                "split": case.split,
                "parent_prompt_id": gold_id,
                "prompt_text": perturb_text,
                "absolute_score_0_100": mean_score(perturb_scores),
                "error_tags": perturb_tags,
                "adjudication_status": "adjudicated",
                "rater_count": len(rater_ids),
                "blinded_ratings": perturb_scores,
                "rater_ids_hashed": rater_ids,
                "provenance_source": args.provenance_source,
                "provenance_artifact": args.provenance_artifact,
                "label_source_class": "human_adjudicated",
                "negative_origin": "natural",
                "hard_negative": False,
                "expected_relation": "worse_than_parent",
                "review_metadata": review_metadata,
            },
            {
                "id": pair_id,
                "preset_family": case.preset_family,
                "item_type": "pairwise",
                "language_tag": case.language_tag,
                "split": case.split,
                "parent_prompt_id": gold_id,
                "perturbation_id": perturb_id,
                "draft_prompt": case.draft_prompt,
                "candidate_a": case.candidate_a,
                "candidate_b": case.candidate_b,
                "candidate_a_source": case.candidate_a_source,
                "candidate_b_source": case.candidate_b_source,
                "expected_winner": winner,
                "adjudication_status": "adjudicated",
                "rater_count": len(rater_ids),
                "rater_ids_hashed": rater_ids,
                "provenance_source": args.provenance_source,
                "provenance_artifact": args.provenance_artifact,
                "label_source_class": "human_adjudicated",
                "negative_origin": "natural",
                "hard_negative": False,
                "review_metadata": review_metadata,
            },
        ])
    out_path = pathlib.Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as fh:
        for row in out_rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(json.dumps({
        "ok": True,
        "out": str(out_path),
        "answer_sources": [str(path) for path in answer_paths],
        "case_count": len(cases),
        "compiled_case_count": len(out_rows) // 3,
        "unresolved_cases": unresolved,
        "missing_cases": missing,
    }, indent=2, ensure_ascii=False))
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
