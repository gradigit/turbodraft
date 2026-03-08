#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
from typing import Any

from build_human_adjudication_packet import load_jsonl, normalize_case


def stable_bool(*parts: str) -> bool:
    payload = "||".join(parts).encode("utf-8")
    digest = hashlib.sha256(payload).hexdigest()
    return int(digest[:8], 16) % 2 == 1


def workbook_meta_integrity(meta: dict[str, Any]) -> str:
    payload = json.dumps(meta, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def render_workbook(
    *,
    title: str,
    rows: list[dict[str, Any]],
    seed: str,
    rater_label: str,
) -> str:
    parts: list[str] = []
    parts.append(f"# {title}\n\n")
    parts.append("## Instructions\n")
    parts.append("- Make your blind decision in this file directly.\n")
    parts.append("- Do not open any AI-assist appendix until the blind pass is finished.\n")
    parts.append("- Required per case: winner + confidence.\n")
    parts.append("- Optional per case: short note.\n")
    parts.append("- Candidate order is randomized per case; do not infer quality from position.\n\n")
    parts.append("## Confidence rubric\n")
    parts.append("- **High** — clear winner; materially better on multiple important criteria.\n")
    parts.append("- **Medium** — likely winner; better overall, but there is a real tradeoff or ambiguity.\n")
    parts.append("- **Low** — close call; uncertain or difficult to distinguish.\n")

    for index, raw in enumerate(rows, start=1):
        case = normalize_case(raw, index)
        swap = stable_bool(case.case_id, seed, rater_label)
        display_a = case.candidate_b if swap else case.candidate_a
        display_b = case.candidate_a if swap else case.candidate_b
        display_map = {"A": "candidate_b" if swap else "candidate_a", "B": "candidate_a" if swap else "candidate_b"}
        meta = {
            "case_id": case.case_id,
            "preset_family": case.preset_family,
            "language_tag": case.language_tag,
            "split": case.split,
            "display_map": display_map,
            "seed": seed,
            "rater_label": rater_label,
        }
        meta["integrity_sha256"] = workbook_meta_integrity(meta)
        parts.append("\n")
        parts.append(f"<!-- TD_CASE_META {json.dumps(meta, ensure_ascii=False)} -->\n")
        parts.append(f"## Case {index:02d}\n\n")
        parts.append("### Draft\n")
        parts.append(f"```text\n{case.draft_prompt}\n```\n")
        parts.append("### Candidate A\n")
        parts.append(f"```text\n{display_a}\n```\n")
        parts.append("### Candidate B\n")
        parts.append(f"```text\n{display_b}\n```\n")
        parts.append("### Blind decision\n")
        parts.append("Winner:\n")
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
    ap = argparse.ArgumentParser(description="Build a blinded markdown workbook for human adjudication.")
    ap.add_argument("--candidates", required=True, help="JSONL file containing candidate pair rows")
    ap.add_argument("--workbook-out", required=True, help="Markdown workbook output path")
    ap.add_argument("--title", default="TurboDraft Human Adjudication Workbook")
    ap.add_argument("--seed", default="0", help="Stable seed used for candidate-order randomization")
    ap.add_argument("--rater-label", default="rater", help="Stable per-rater label to vary order across raters")
    ap.add_argument("--max-cases", type=int, default=0)
    args = ap.parse_args()

    candidates_path = pathlib.Path(args.candidates).resolve()
    rows = load_jsonl(candidates_path)
    if args.max_cases > 0:
        rows = rows[: args.max_cases]
    if not rows:
        raise RuntimeError("no candidate cases found")

    workbook_path = pathlib.Path(args.workbook_out).resolve()
    workbook_path.parent.mkdir(parents=True, exist_ok=True)
    workbook_path.write_text(
        render_workbook(title=args.title, rows=rows, seed=str(args.seed), rater_label=str(args.rater_label)),
        encoding="utf-8",
    )

    print(
        json.dumps(
            {
                "ok": True,
                "candidates": str(candidates_path),
                "workbook_out": str(workbook_path),
                "case_count": len(rows),
                "seed": str(args.seed),
                "rater_label": str(args.rater_label),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
