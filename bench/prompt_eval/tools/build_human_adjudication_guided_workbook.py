#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
from typing import Any

from build_human_adjudication_packet import load_jsonl, normalize_case
from build_human_adjudication_workbook import case_content_integrity, stable_bool, workbook_meta_integrity


def load_guidance(path: pathlib.Path | None) -> dict[str, dict[str, Any]]:
    if path is None:
        return {}
    payload = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(payload, dict):
        raise RuntimeError('guidance file must be a JSON object keyed by case_id')
    out: dict[str, dict[str, Any]] = {}
    for case_id, item in payload.items():
        if not isinstance(item, dict):
            raise RuntimeError(f'guidance[{case_id}] must be an object')
        out[str(case_id)] = item
    return out


def render_list(items: list[str]) -> str:
    if not items:
        return '- None\n'
    return ''.join(f'- {item}\n' for item in items)


def normalize_str_list(value: Any) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise RuntimeError('guidance checklist/disqualifier values must be arrays of strings')
    return [str(v).strip() for v in value if str(v).strip()]


def render_workbook(
    *,
    title: str,
    rows: list[dict[str, Any]],
    seed: str,
    rater_label: str,
    guidance_by_case: dict[str, dict[str, Any]],
) -> str:
    parts: list[str] = []
    parts.append(f'# {title}\n\n')
    parts.append('## Instructions\n')
    parts.append('- This is the **guided blind core** lane for lock-grade human evidence.\n')
    parts.append('- Use the checklist as a reading aid, but make your own decision.\n')
    parts.append('- Do not open any AI-assisted workbook or appendix first.\n')
    parts.append('- Required per case: winner + confidence.\n')
    parts.append('- Optional per case: short note.\n')
    parts.append('- If both candidates seem acceptable, use the checklist to identify which one is less likely to fail the draft.\n')
    parts.append('- If you still genuinely cannot tell, choose `Tie` with `Low` confidence.\n\n')
    parts.append('## Confidence rubric\n')
    parts.append('- **High** — one candidate clearly satisfies the draft better with fewer obvious risks.\n')
    parts.append('- **Medium** — likely winner, but there is a real tradeoff or ambiguity.\n')
    parts.append('- **Low** — still hard to distinguish from text alone.\n')

    for index, raw in enumerate(rows, start=1):
        case = normalize_case(raw, index)
        swap = stable_bool(case.case_id, seed, rater_label)
        display_a = case.candidate_b if swap else case.candidate_a
        display_b = case.candidate_a if swap else case.candidate_b
        display_map = {'A': 'candidate_b' if swap else 'candidate_a', 'B': 'candidate_a' if swap else 'candidate_b'}
        meta = {
            'case_id': case.case_id,
            'preset_family': case.preset_family,
            'language_tag': case.language_tag,
            'split': case.split,
            'display_map': display_map,
            'seed': seed,
            'rater_label': rater_label,
            'lane': 'guided_blind_core',
        }
        guidance = guidance_by_case.get(case.case_id, {})
        quick_checks = normalize_str_list(guidance.get('checklist'))
        disqualifiers = normalize_str_list(guidance.get('disqualifiers'))
        why_it_matters = str(guidance.get('why_it_matters') or '').strip()
        case_body_parts: list[str] = []
        case_body_parts.append(f'## Case {index:02d}\n\n')
        case_body_parts.append('### Draft\n')
        case_body_parts.append(f'```text\n{case.draft_prompt}\n```\n')
        if why_it_matters:
            case_body_parts.append('### Why this case matters\n')
            case_body_parts.append(f'> {why_it_matters}\n')
        case_body_parts.append('### Quick checklist\n')
        case_body_parts.append(render_list(quick_checks))
        case_body_parts.append('### Disqualifiers to look for\n')
        case_body_parts.append(render_list(disqualifiers))
        case_body_parts.append('### Candidate A\n')
        case_body_parts.append(f'```text\n{display_a}\n```\n')
        case_body_parts.append('### Candidate B\n')
        case_body_parts.append(f'```text\n{display_b}\n```\n')
        case_body = ''.join(case_body_parts)
        meta['content_sha256'] = case_content_integrity(case_body)
        meta['integrity_sha256'] = workbook_meta_integrity(meta)

        parts.append('\n')
        parts.append(f'<!-- TD_CASE_META {json.dumps(meta, ensure_ascii=False)} -->\n')
        parts.append(case_body)
        parts.append('### Blind decision\n')
        parts.append('Winner:\n')
        parts.append('- [ ] A\n')
        parts.append('- [ ] B\n')
        parts.append('- [ ] Tie\n')
        parts.append('- [ ] BothBad\n\n')
        parts.append('Confidence:\n')
        parts.append('- [ ] High\n')
        parts.append('- [ ] Medium\n')
        parts.append('- [ ] Low\n\n')
        parts.append('Optional note:\n')
        parts.append('> \n')
    return ''.join(parts)


def main() -> int:
    ap = argparse.ArgumentParser(description='Build a guided blind-core markdown workbook for human adjudication.')
    ap.add_argument('--candidates', required=True)
    ap.add_argument('--workbook-out', required=True)
    ap.add_argument('--title', default='TurboDraft Guided Blind Core Workbook')
    ap.add_argument('--seed', default='0')
    ap.add_argument('--rater-label', default='rater')
    ap.add_argument('--max-cases', type=int, default=0)
    ap.add_argument('--guidance-json', help='Optional JSON file keyed by case_id with checklist/disqualifier hints')
    args = ap.parse_args()

    candidates_path = pathlib.Path(args.candidates).resolve()
    rows = load_jsonl(candidates_path)
    if args.max_cases > 0:
        rows = rows[: args.max_cases]
    if not rows:
        raise RuntimeError('no candidate cases found')

    guidance_path = pathlib.Path(args.guidance_json).resolve() if args.guidance_json else None
    guidance_by_case = load_guidance(guidance_path)

    workbook_path = pathlib.Path(args.workbook_out).resolve()
    workbook_path.parent.mkdir(parents=True, exist_ok=True)
    workbook_path.write_text(
        render_workbook(
            title=args.title,
            rows=rows,
            seed=str(args.seed),
            rater_label=str(args.rater_label),
            guidance_by_case=guidance_by_case,
        ),
        encoding='utf-8',
    )

    print(json.dumps({
        'ok': True,
        'candidates': str(candidates_path),
        'guidance_json': str(guidance_path) if guidance_path else None,
        'workbook_out': str(workbook_path),
        'case_count': len(rows),
        'seed': str(args.seed),
        'rater_label': str(args.rater_label),
        'lane': 'guided_blind_core',
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
