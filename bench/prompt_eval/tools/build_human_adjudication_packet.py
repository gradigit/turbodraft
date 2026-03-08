#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import pathlib
from dataclasses import dataclass
from typing import Any


DEFECT_TAGS: list[tuple[str, str]] = [
    ("missing_constraint", "Drops or weakens an explicit requirement or constraint."),
    ("scope_fabrication", "Adds meaningful scope that was not requested."),
    ("structural_noncompliance", "Misses required sections or output structure."),
    ("unverifiable_output", "Does not define a checkable deliverable or validation path."),
    ("prompt_injection_leak", "Treats quoted/untrusted text as instructions."),
    ("ambiguity", "Leaves important choices underspecified or unclear."),
    ("verbosity_bloat", "Adds unnecessary filler or bloated prose."),
    ("language_mismatch", "Uses the wrong language or mishandles bilingual requirements."),
    ("tool_mismatch", "Assumes the wrong tools/agent capabilities."),
    ("other", "Another defect not covered above; explain in notes."),
]


@dataclass(frozen=True)
class CandidateCase:
    case_id: str
    preset_family: str
    language_tag: str
    split: str
    draft_prompt: str
    candidate_a: str
    candidate_b: str
    candidate_a_source: str | None
    candidate_b_source: str | None
    source_ids: list[str]
    notes: str
    demo_only: bool
    candidate_a_hash: str
    candidate_b_hash: str
    draft_hash: str


def stable_sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_jsonl(path: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if line:
                payload = json.loads(line)
                if not isinstance(payload, dict):
                    raise RuntimeError(f"{path}: every row must be a JSON object")
                rows.append(payload)
    return rows


def parse_listish(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    if isinstance(value, str):
        raw = value.strip()
        if not raw:
            return []
        if raw.startswith("["):
            data = json.loads(raw)
            if not isinstance(data, list):
                raise RuntimeError("expected JSON list for source_ids")
            return [str(v).strip() for v in data if str(v).strip()]
        if "|" in raw:
            return [part.strip() for part in raw.split("|") if part.strip()]
        if "," in raw:
            return [part.strip() for part in raw.split(",") if part.strip()]
        return [raw]
    raise RuntimeError(f"invalid list-like value: {value!r}")


def normalize_case(row: dict[str, Any], index: int) -> CandidateCase:
    case_id = str(row.get("case_id") or row.get("id") or f"case_{index:03d}").strip()
    preset_family = str(row.get("preset_family") or "").strip()
    language_tag = str(row.get("language_tag") or "").strip()
    split = str(row.get("split") or "").strip()
    draft_prompt = str(row.get("draft_prompt") or "").strip()
    candidate_a = str(row.get("candidate_a") or "").strip()
    candidate_b = str(row.get("candidate_b") or "").strip()
    if not preset_family:
        raise RuntimeError(f"{case_id}: preset_family required")
    if not language_tag:
        raise RuntimeError(f"{case_id}: language_tag required")
    if split not in {"dev", "tune", "sealed_test"}:
        raise RuntimeError(f"{case_id}: split must be dev|tune|sealed_test")
    if not draft_prompt:
        raise RuntimeError(f"{case_id}: draft_prompt required")
    if not candidate_a or not candidate_b:
        raise RuntimeError(f"{case_id}: candidate_a and candidate_b required")
    return CandidateCase(
        case_id=case_id,
        preset_family=preset_family,
        language_tag=language_tag,
        split=split,
        draft_prompt=draft_prompt,
        candidate_a=candidate_a,
        candidate_b=candidate_b,
        candidate_a_source=str(row.get("candidate_a_source") or "").strip() or None,
        candidate_b_source=str(row.get("candidate_b_source") or "").strip() or None,
        source_ids=parse_listish(row.get("source_ids")),
        notes=str(row.get("notes") or "").strip(),
        demo_only=bool(row.get("demo_only", False)),
        candidate_a_hash=stable_sha256(candidate_a),
        candidate_b_hash=stable_sha256(candidate_b),
        draft_hash=stable_sha256(draft_prompt),
    )


def render_packet(title: str, cases: list[CandidateCase], *, show_internal_metadata: bool = False) -> str:
    parts: list[str] = []
    demo_only = any(case.demo_only for case in cases)
    parts.append(f"# {title}\n")
    parts.append("## Reviewer Instructions\n")
    if demo_only:
        parts.append(
            "> This packet contains demo/sample rows for UX review. It is **not** lock-grade evidence and must not be imported as adjudicated truth.\n"
        )
    parts.append(
        "Use this packet together with the companion CSV answer sheet. Read the draft, compare Candidate A vs Candidate B, and record your decision in the CSV.\n"
    )
    parts.append("### Decision rules\n")
    parts.append("- Prefer the prompt that better preserves the user objective, constraints, and usable output contract.\n")
    parts.append("- Use `Tie` only when the prompts are genuinely equivalent in engineering quality.\n")
    parts.append("- Use `BothBad` only when both prompts are materially unacceptable.\n")
    parts.append("- Leave short notes whenever you choose `Tie`, `BothBad`, or confidence <= 2.\n")
    parts.append("- Unresolved `Tie` / `BothBad` cases must go to tie-break review before canonical import.\n")
    parts.append("### Recommended batch size\n")
    parts.append("- 20–30 pairwise cases per packet\n")
    parts.append("- 2 primary raters + 1 tie-breaker on disagreements\n")
    parts.append("- Randomized A/B order; do not infer quality from position\n")
    parts.append("- Reviewer packets are blinded to source metadata and seed expectations by default\n")
    parts.append("### Defect taxonomy\n")
    for key, desc in DEFECT_TAGS:
        parts.append(f"- `{key}` — {desc}\n")

    for idx, case in enumerate(cases, start=1):
        parts.append(f"\n## Case {idx} — `{case.case_id}`\n")
        parts.append(f"- Preset family: `{case.preset_family}`\n")
        parts.append(f"- Language: `{case.language_tag}`\n")
        parts.append(f"- Split target: `{case.split}`\n")
        if show_internal_metadata and case.source_ids:
            parts.append(f"- Source IDs: `{', '.join(case.source_ids)}`\n")
        if show_internal_metadata and case.notes:
            parts.append(f"- Packet notes: {case.notes}\n")
        parts.append("\n### Draft\n")
        parts.append(f"```text\n{case.draft_prompt}\n```\n")
        parts.append("### Candidate A\n")
        parts.append(f"```text\n{case.candidate_a}\n```\n")
        parts.append("### Candidate B\n")
        parts.append(f"```text\n{case.candidate_b}\n```\n")
        parts.append("### Fill-in checklist\n")
        parts.append("- Winner\n")
        parts.append("  - [ ] A\n")
        parts.append("  - [ ] B\n")
        parts.append("  - [ ] Tie\n")
        parts.append("  - [ ] BothBad\n")
        parts.append("- Quality A (0-100): ______\n")
        parts.append("- Quality B (0-100): ______\n")
        parts.append("- Confidence (1-5): ______\n")
        parts.append("- Defect tags A (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______\n")
        parts.append("- Defect tags B (optional; record in CSV, recommended for low confidence / Tie / BothBad / material defects): ______\n")
        parts.append("- Notes:\n")
        parts.append("  - ____________________________________________\n")
        parts.append("  - ____________________________________________\n")
    return "".join(parts)


def write_answer_sheet(path: pathlib.Path, cases: list[CandidateCase]) -> None:
    fieldnames = [
        "case_id",
        "preset_family",
        "language_tag",
        "split",
        "rater_id_hashed",
        "decision",
        "quality_a_0_100",
        "quality_b_0_100",
        "confidence_1_5",
        "defect_tags_a",
        "defect_tags_b",
        "notes",
    ]
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for case in cases:
            writer.writerow(
                {
                    "case_id": case.case_id,
                    "preset_family": case.preset_family,
                    "language_tag": case.language_tag,
                    "split": case.split,
                    "rater_id_hashed": "",
                    "decision": "",
                    "quality_a_0_100": "",
                    "quality_b_0_100": "",
                    "confidence_1_5": "",
                    "defect_tags_a": "",
                    "defect_tags_b": "",
                    "notes": "",
                }
            )


def main() -> int:
    ap = argparse.ArgumentParser(description="Build a human-adjudication markdown packet and companion CSV answer sheet.")
    ap.add_argument("--candidates", required=True, help="JSONL file containing candidate pair rows")
    ap.add_argument("--packet-out", required=True, help="Markdown packet output path")
    ap.add_argument("--answers-out", required=True, help="CSV answer-sheet output path")
    ap.add_argument("--title", default="TurboDraft Human Adjudication Packet")
    ap.add_argument("--max-cases", type=int, default=0)
    ap.add_argument("--show-internal-metadata", action="store_true", help="Include internal source IDs and notes in the markdown packet (not recommended for blinded human review)")
    args = ap.parse_args()

    candidates_path = pathlib.Path(args.candidates).resolve()
    rows = load_jsonl(candidates_path)
    cases = [normalize_case(row, index=i + 1) for i, row in enumerate(rows)]
    if args.max_cases > 0:
        cases = cases[: args.max_cases]
    if not cases:
        raise RuntimeError("no candidate cases found")

    packet_path = pathlib.Path(args.packet_out).resolve()
    answers_path = pathlib.Path(args.answers_out).resolve()
    packet_path.parent.mkdir(parents=True, exist_ok=True)
    answers_path.parent.mkdir(parents=True, exist_ok=True)

    packet_path.write_text(render_packet(args.title, cases, show_internal_metadata=args.show_internal_metadata), encoding="utf-8")
    write_answer_sheet(answers_path, cases)

    print(
        json.dumps(
            {
                "ok": True,
                "candidates": str(candidates_path),
                "packet_out": str(packet_path),
                "answers_out": str(answers_path),
                "case_count": len(cases),
            },
            indent=2,
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
