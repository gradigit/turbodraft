#!/usr/bin/env python3
import argparse
import json
import pathlib
from collections import Counter


def load_json(path: pathlib.Path) -> dict:
    return json.loads(path.read_text(encoding='utf-8'))


def load_jsonl(path: pathlib.Path):
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if line:
            yield json.loads(line)


def latest_report_dir(base: pathlib.Path, prefix: str) -> pathlib.Path:
    dirs = [p for p in base.iterdir() if p.is_dir() and p.name.startswith(prefix)]
    if not dirs:
        raise FileNotFoundError(f'No report dirs with prefix {prefix} under {base}')
    dirs.sort(key=lambda p: p.name)
    return dirs[-1]


def main() -> int:
    ap = argparse.ArgumentParser(description='Audit prompt-eval design readiness')
    ap.add_argument('--repo', default='.')
    ap.add_argument('--reports-dir', default='bench/prompt_eval/reports')
    ap.add_argument('--cases', default='bench/prompt_eval/datasets/pilot_cases.jsonl')
    ap.add_argument('--schema', default='bench/prompt_eval/schemas/judge_decision.schema.json')
    ap.add_argument('--calibration-summary', default='')
    ap.add_argument('--pilot-summary', default='')
    ap.add_argument('--symmetry-summary', default='')
    ap.add_argument('--out', default='')
    args = ap.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    reports_dir = (repo / args.reports_dir).resolve()

    if args.calibration_summary:
        cal_summary_path = (repo / args.calibration_summary).resolve()
    else:
        cal_summary_path = latest_report_dir(reports_dir, 'judge_calibration_') / 'summary.json'

    if args.pilot_summary:
        pilot_summary_path = (repo / args.pilot_summary).resolve()
    else:
        pilot_summary_path = latest_report_dir(reports_dir, 'pilot_') / 'summary.json'

    if args.symmetry_summary:
        sym_summary_path = (repo / args.symmetry_summary).resolve()
    else:
        sym_summary_path = latest_report_dir(reports_dir, 'judge_symmetry_') / 'summary.json'

    cal = load_json(cal_summary_path)
    pilot = load_json(pilot_summary_path)
    sym = load_json(sym_summary_path)
    schema = load_json((repo / args.schema).resolve())
    cases = list(load_jsonl((repo / args.cases).resolve()))

    # Dataset coverage
    by_preset = Counter(c['preset'] for c in cases)

    # Schema strictness
    schema_checks = {
        'additionalProperties_false': schema.get('additionalProperties') is False,
        'winner_enum_present': 'winner' in schema.get('properties', {}),
        'required_includes_core_fields': set(['winner', 'score_a', 'score_b', 'confidence', 'reasons']).issubset(set(schema.get('required', []))),
    }

    # Calibration checks
    prompt_summaries = cal.get('prompt_summaries', [])
    best = cal.get('recommended_prompt') or (prompt_summaries[0] if prompt_summaries else {})
    n_cal = int(best.get('n', 0) or 0)
    acc = float(best.get('accuracy', 0.0) or 0.0)
    invalid = float(best.get('invalid_count', 0) or 0)
    invalid_rate = invalid / max(1, n_cal)

    calibration_checks = {
        'accuracy_ge_0_8': acc >= 0.8,
        'invalid_rate_le_0_05': invalid_rate <= 0.05,
        'sample_size_ge_30': n_cal >= 30,
    }

    # Symmetry checks
    symmetry_checks = {
        'symmetry_rate_ge_0_95': float(sym.get('symmetry_rate', 0.0) or 0.0) >= 0.95,
        'repeat_agreement_ge_0_9': float(sym.get('forward_repeat_agreement', 0.0) or 0.0) >= 0.9,
    }

    # Pilot sensitivity
    results = pilot.get('results', {})
    sensitivity_checks = {}
    for variant, stats in results.items():
        p = stats.get('pairwise_vs_baseline')
        if p:
            sensitivity_checks[f'{variant}_has_signal'] = (
                p.get('win_rate', 0) > 0 or p.get('loss_rate', 0) > 0 or p.get('tie_rate', 0) > 0
            )

    all_checks = {}
    all_checks.update(schema_checks)
    all_checks.update(calibration_checks)
    all_checks.update(symmetry_checks)
    all_checks.update(sensitivity_checks)

    pass_count = sum(1 for v in all_checks.values() if v)
    total = len(all_checks)

    truth_readiness = all([
        schema_checks['additionalProperties_false'],
        calibration_checks['accuracy_ge_0_8'],
        calibration_checks['invalid_rate_le_0_05'],
        symmetry_checks['symmetry_rate_ge_0_95'],
        # strict requirement for truth-level decisions
        calibration_checks['sample_size_ge_30'],
    ])

    verdict = 'READY_FOR_DIRECTIONAL_DECISIONS' if not truth_readiness else 'READY_FOR_TRUTH_LEVEL_GATING'

    report = {
        'calibration_summary': str(cal_summary_path),
        'pilot_summary': str(pilot_summary_path),
        'symmetry_summary': str(sym_summary_path),
        'dataset_coverage_by_preset': dict(by_preset),
        'checks': all_checks,
        'pass_count': pass_count,
        'total_checks': total,
        'pass_rate': round(pass_count / max(1, total), 4),
        'truth_readiness': truth_readiness,
        'verdict': verdict,
        'blocking_reasons': [
            'Calibration sample size below 30' if not calibration_checks['sample_size_ge_30'] else None,
            'Pilot dataset too small for production truth claims' if len(cases) < 50 else None,
        ],
    }
    report['blocking_reasons'] = [x for x in report['blocking_reasons'] if x]

    if args.out:
        out_path = (repo / args.out).resolve()
    else:
        out_path = (reports_dir / 'eval_design_audit_latest.json').resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

    print(json.dumps({'ok': True, 'out': str(out_path), 'report': report}, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
