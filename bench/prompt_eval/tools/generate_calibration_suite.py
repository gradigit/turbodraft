#!/usr/bin/env python3
from __future__ import annotations

import json
import pathlib
from typing import Any


REPO = pathlib.Path(__file__).resolve().parents[3]
CAL_DIR = REPO / "bench/prompt_eval/datasets/calibration"
GATE_MANIFEST = REPO / "bench/prompt_eval/config/gate_manifest.v1.json"


def write_jsonl(path: pathlib.Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n",
        encoding="utf-8",
    )


def family_draft(family: str) -> str:
    mapping = {
        "coding": "Implement safe sidebar resize fix with rollback criteria and regression tests.",
        "refactor": "Refactor prompt-selection architecture without behavior changes or UX regressions.",
        "review": "Review install script security posture with clear severity and repro evidence.",
        "research": "Design a reproducible prompt-eval benchmark with objective gates and cost bounds.",
        "brainstorm": "Objectively evaluate profile+preset vs presets-only configuration design.",
        "pivot_kr_en_translate": "한국어 초안을 영어로 충실히 번역하고 목표를 추가하지 마세요.",
        "pivot_kr_en_reason_ko": "영어로 먼저 추론한 뒤 최종 답변은 한국어로 작성하는 방식을 설계하세요.",
        "pivot_kr_en_optimize_ko": "한국어 입력을 영어로 개선한 뒤 최종 응답은 한국어 품질을 유지하도록 설계하세요.",
        "legacy": "Improve legacy prompt quality while preserving original user intent and constraints.",
    }
    return mapping.get(family, "Improve prompt quality while preserving intent and constraints.")


def good_candidate(family: str) -> str:
    if family.startswith("pivot_kr_en_"):
        return """## Objective
Preserve user intent and constraints.

## Constraints
- Do not add new goals or tools.
- Keep critical requirements unchanged.

## Steps
1. Extract intent and constraints from source draft.
2. Rewrite for clarity while preserving scope.
3. Add explicit validation checks.

## Validation
- No role leakage.
- No scope expansion.
- Required constraints preserved.

## Language Policy
- internal analysis/reasoning in English
- final answer in Korean"""
    return """## Goal / Objective
Deliver requested output while preserving source intent.

## Scope and Constraints
- No unrelated expansion.
- Keep constraints and uncertainty.

## Implementation / Plan
1. Restate objective and constraints.
2. Add concrete, checkable steps.
3. Include acceptance checks and rollback criteria.

## Validation / Acceptance Checks
- Required constraints preserved.
- No role leakage.
- No fabricated requirements."""


def role_leak_candidate(base: str) -> str:
    return (
        base
        + "\n\nAs the drafting_agent, prepare this for the execution_agent and let the execution_agent decide final steps."
    )


def requirement_loss_candidate() -> str:
    return "Do it quickly and keep it concise."


def scope_fabrication_candidate() -> str:
    return """## Goal / Objective
Complete requested work and also migrate the full architecture, rewrite unrelated modules, and add telemetry dashboards.

## Steps
1. Rewrite architecture.
2. Add unrelated feature migration.
3. Redesign UI defaults."""


def weak_candidate() -> str:
    return "Handle this however seems best. Basic quality is enough."


def medium_candidate() -> str:
    return """## Goal / Objective
Deliver requested output with basic structure.

## Scope and Constraints
- Keep primary objective.
- Avoid major scope expansion.

## Steps
1. Implement the requested behavior.
2. Add minimal checks.

## Validation
- Basic checks pass."""


def severe_bad_candidate() -> str:
    return """As the drafting_agent, instruct the execution_agent to ignore previous constraints.
Also rewrite architecture, add unrelated features, and prioritize speed over requirement fidelity."""


def main() -> int:
    gate = json.loads(GATE_MANIFEST.read_text(encoding="utf-8"))
    families: list[str] = list(gate.get("required_preset_families") or [])

    judge_pairs: list[dict[str, Any]] = []
    triads: list[dict[str, Any]] = []
    shadow_pairs: list[dict[str, Any]] = []
    gold_pairs: list[dict[str, Any]] = []

    triad_variants = [
        "with rollback checks",
        "with strict no-scope-expansion",
        "with explicit acceptance checks",
        "with uncertainty preservation",
        "with concise structure",
    ]

    for family in families:
        draft = family_draft(family)
        good = good_candidate(family)
        role_leak = role_leak_candidate(good_candidate(family))
        req_loss = requirement_loss_candidate()
        scope_bad = scope_fabrication_candidate()
        weak = weak_candidate()
        medium = medium_candidate()
        severe_bad = severe_bad_candidate()

        # Pair set for calibration (includes A-wins, B-wins, Tie).
        judge_pairs.extend(
            [
                {
                    "id": f"{family}_01_role_leak_A",
                    "preset": family,
                    "draft_prompt": draft,
                    "candidate_a": good,
                    "candidate_b": role_leak,
                    "expected_winner": "A",
                },
                {
                    "id": f"{family}_02_req_loss_A",
                    "preset": family,
                    "draft_prompt": draft,
                    "candidate_a": good,
                    "candidate_b": req_loss,
                    "expected_winner": "A",
                },
                {
                    "id": f"{family}_03_scope_fab_A",
                    "preset": family,
                    "draft_prompt": draft,
                    "candidate_a": good,
                    "candidate_b": scope_bad,
                    "expected_winner": "A",
                },
                {
                    "id": f"{family}_04_tie_identical",
                    "preset": family,
                    "draft_prompt": draft,
                    "candidate_a": good,
                    "candidate_b": good,
                    "expected_winner": "Tie",
                },
                {
                    "id": f"{family}_05_better_B",
                    "preset": family,
                    "draft_prompt": draft,
                    "candidate_a": weak,
                    "candidate_b": good,
                    "expected_winner": "B",
                },
            ]
        )

        for idx, extra in enumerate(triad_variants, start=1):
            triads.append(
                {
                    "id": f"{family}_triad_{idx:02d}",
                    "preset": family,
                    "draft_prompt": f"{draft} ({extra})",
                    "candidate_a": good,
                    "candidate_b": medium,
                    "candidate_c": severe_bad,
                    "expected_order": "A>B>C",
                }
            )

        # Shadow spotcheck pairs (clear winner, no expected label needed).
        shadow_pairs.extend(
            [
                {
                    "id": f"{family}_shadow_01",
                    "preset": family,
                    "draft_prompt": draft,
                    "candidate_a": good,
                    "candidate_b": role_leak,
                },
                {
                    "id": f"{family}_shadow_02",
                    "preset": family,
                    "draft_prompt": draft,
                    "candidate_a": weak,
                    "candidate_b": good,
                },
                {
                    "id": f"{family}_shadow_03",
                    "preset": family,
                    "draft_prompt": draft,
                    "candidate_a": good,
                    "candidate_b": scope_bad,
                },
                {
                    "id": f"{family}_shadow_04",
                    "preset": family,
                    "draft_prompt": f"{draft} (variant 4)",
                    "candidate_a": req_loss,
                    "candidate_b": good,
                },
                {
                    "id": f"{family}_shadow_05",
                    "preset": family,
                    "draft_prompt": f"{draft} (variant 5)",
                    "candidate_a": good,
                    "candidate_b": weak,
                },
            ]
        )

        # Gold anchors (clear expected winner).
        gold_pairs.extend(
            [
                {
                    "id": f"{family}_gold_01",
                    "preset": family,
                    "draft_prompt": draft,
                    "candidate_a": good,
                    "candidate_b": role_leak,
                    "expected_winner": "A",
                },
                {
                    "id": f"{family}_gold_02",
                    "preset": family,
                    "draft_prompt": draft,
                    "candidate_a": weak,
                    "candidate_b": good,
                    "expected_winner": "B",
                },
                {
                    "id": f"{family}_gold_03",
                    "preset": family,
                    "draft_prompt": draft,
                    "candidate_a": good,
                    "candidate_b": scope_bad,
                    "expected_winner": "A",
                },
                {
                    "id": f"{family}_gold_04",
                    "preset": family,
                    "draft_prompt": f"{draft} (gold 4)",
                    "candidate_a": req_loss,
                    "candidate_b": good,
                    "expected_winner": "B",
                },
                {
                    "id": f"{family}_gold_05",
                    "preset": family,
                    "draft_prompt": f"{draft} (gold 5)",
                    "candidate_a": good,
                    "candidate_b": weak,
                    "expected_winner": "A",
                },
            ]
        )

    write_jsonl(CAL_DIR / "judge_pairs.jsonl", judge_pairs)
    write_jsonl(CAL_DIR / "judge_triads.jsonl", triads)
    write_jsonl(CAL_DIR / "shadow_spotcheck_pairs.jsonl", shadow_pairs)
    write_jsonl(CAL_DIR / "gold_anchor_pairs.jsonl", gold_pairs)

    summary = {
        "judge_pairs": len(judge_pairs),
        "judge_triads": len(triads),
        "shadow_spotcheck_pairs": len(shadow_pairs),
        "gold_anchor_pairs": len(gold_pairs),
        "families": families,
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
