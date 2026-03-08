#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import re
import subprocess
from typing import Any

from armj_common import (
    calibration_profile,
    brier_and_ece,
    compute_dataset_fingerprint,
    deterministic_sample,
    extract_usage,
    fill_template,
    load_codex_judge_provider,
    load_json,
    load_jsonl,
    median,
    merge_usage,
    run_codex_judge,
    spearman,
    wilson_lower,
    write_json,
    write_jsonl,
)
from provider_contract import DEFAULT_PROVIDER_CONTRACT, ProviderContractError

REPO = pathlib.Path(__file__).resolve().parents[3]
DEFAULT_DATASET_DIR = REPO / "bench/prompt_eval/datasets/judge_quality"
DEFAULT_SCHEMA = REPO / "bench/prompt_eval/schemas/judge_decision.schema.json"
DEFAULT_JUDGE_PROMPT = REPO / "bench/prompt_eval/prompts/judge_pairwise_v6.md"

CRITICAL_TAG_KEYWORDS = {
    "role_leakage": ["role", "leak", "execution_agent", "drafting_agent"],
    "safety_boundary": ["boundary", "unsafe", "ignore", "bypass"],
    "missing_constraint": ["constraint", "missing", "drop", "omitted"],
    "contract_loss": ["contract", "schema", "format", "validation"],
    "schema_loss": ["schema", "json", "format"],
}


def looks_like_invalid_judge_output(error: str | None) -> bool:
    if not error:
        return False
    text = str(error).lower()
    markers = (
        "json",
        "schema",
        "parse",
        "missing judge output",
        "output-schema",
        "validation",
    )
    return any(marker in text for marker in markers)


def parse_splits(raw: str) -> set[str]:
    splits = {part.strip() for part in raw.split(",") if part.strip()}
    allowed = {"dev", "tune", "sealed_test"}
    invalid = sorted(s for s in splits if s not in allowed)
    if invalid:
        raise ValueError(f"invalid split(s): {', '.join(invalid)}")
    return splits or {"dev", "tune"}


def stable_score_from_pair(pair: dict[str, Any], gold_score: float, perturb_score: float) -> tuple[float, float, float]:
    margin = max(1.0, min(40.0, float(gold_score - perturb_score)))
    base = 50.0
    score_a = round(base + (margin / 2.0), 3)
    score_b = round(base - (margin / 2.0), 3)
    confidence = 0.92 if pair.get("expected_winner") in {"A", "B"} else 0.58
    return score_a, score_b, confidence


def detect_critical_from_decision(
    decision: dict[str, Any],
    *,
    tags: list[str],
) -> bool:
    reasons = [str(x).lower() for x in (decision.get("reasons") or []) if isinstance(x, str)]
    penalties_a = [str(x).lower() for x in (decision.get("penalties_a") or []) if isinstance(x, str)]
    penalties_b = [str(x).lower() for x in (decision.get("penalties_b") or []) if isinstance(x, str)]
    haystack = " ".join(reasons + penalties_a + penalties_b)
    if not haystack:
        return False
    for tag in tags:
        for keyword in CRITICAL_TAG_KEYWORDS.get(tag, []):
            if keyword in haystack:
                return True
    return False


def find_margin_scores(
    pair_rows: list[dict[str, Any]],
    gold_rows: list[dict[str, Any]],
    perturb_rows: list[dict[str, Any]],
) -> dict[str, tuple[float, float]]:
    gold_scores: dict[str, float] = {
        str(row["id"]): float(row["absolute_score_0_100"])
        for row in gold_rows
        if isinstance(row.get("absolute_score_0_100"), (int, float))
    }
    perturb_index: dict[tuple[str, str, str], float] = {}
    for row in perturb_rows:
        parent = str(row.get("parent_prompt_id") or "")
        template_id = str(row.get("perturbation_template_id") or "")
        split = str(row.get("split") or "")
        score = row.get("absolute_score_0_100")
        if parent and template_id and split and isinstance(score, (int, float)):
            perturb_index[(parent, template_id, split)] = float(score)
    out: dict[str, tuple[float, float]] = {}
    for pair in pair_rows:
        parent = str(pair.get("parent_prompt_id") or "")
        template_id = str(pair.get("perturbation_template_id") or "")
        split = str(pair.get("split") or "")
        pair_id = str(pair.get("id") or "")
        if not parent or not template_id or not split or not pair_id:
            continue
        if parent not in gold_scores:
            continue
        perturb_score = perturb_index.get((parent, template_id, split))
        if perturb_score is None:
            continue
        out[pair_id] = (gold_scores[parent], perturb_score)
    return out


def open_sealed_guard(
    manifest: dict[str, Any],
    *,
    splits: set[str],
    open_sealed_test: bool,
    open_sealed_test_reason: str,
) -> None:
    if "sealed_test" not in splits:
        return
    if not open_sealed_test:
        raise RuntimeError("sealed_test split requested without --open-sealed-test")
    reason = open_sealed_test_reason.strip()
    if not reason:
        raise RuntimeError("--open-sealed-test-reason is required when sealed_test split is used")
    governance = manifest.get("governance") or {}
    count = governance.get("sealed_open_count")
    if isinstance(count, int) and count > 0:
        raise RuntimeError("sealed_test already opened previously; rerun requires governed export path")


def evaluate_run(
    *,
    run_index: int,
    rows: list[dict[str, Any]],
    prompt_template: str,
    model: str,
    reasoning_effort: str,
    schema_path: pathlib.Path,
    timeout_s: int,
    simulate_no_provider: bool,
    critical_tags: set[str],
    margin_labels: dict[str, tuple[float, float]],
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, float]]:
    by_case: list[dict[str, Any]] = []
    usage_totals: dict[str, float] = {}

    total = len(rows)
    correct = 0
    invalid_json = 0
    timeout_count = 0
    runtime_errors = 0
    critical_total = 0
    critical_detected = 0

    confidence_values: list[float] = []
    correctness_values: list[int] = []
    predicted_margins: list[float] = []
    labeled_margins: list[float] = []

    for row in rows:
        pair_id = str(row.get("id") or "")
        expected = str(row.get("expected_winner") or "Tie")
        split = str(row.get("split") or "")
        tags = [str(x) for x in (row.get("error_tags") or []) if isinstance(x, str)]
        draft_prompt = str(row.get("draft_prompt") or "")
        candidate_a = str(row.get("candidate_a") or "")
        candidate_b = str(row.get("candidate_b") or "")
        preset = str(row.get("preset_family") or row.get("preset") or "unknown")

        decision: dict[str, Any] = {}
        error: str | None = None
        case_invalid = False

        if simulate_no_provider:
            margins = margin_labels.get(pair_id, (90.0, 60.0))
            score_a, score_b, confidence = stable_score_from_pair(row, margins[0], margins[1])
            decision = {
                "winner": expected if expected in {"A", "B", "Tie"} else "Tie",
                "score_a": score_a,
                "score_b": score_b,
                "confidence": confidence,
                "reasons": ["simulated-run"],
                "penalties_a": [],
                "penalties_b": [",".join(tags)] if tags else [],
            }
        else:
            judge_prompt = fill_template(
                prompt_template,
                {
                    "preset": preset,
                    "draft_prompt": draft_prompt,
                    "candidate_a": candidate_a,
                    "candidate_b": candidate_b,
                },
            )
            try:
                decision, events = run_codex_judge(
                    prompt=judge_prompt,
                    model=model,
                    reasoning_effort=reasoning_effort,
                    schema_path=schema_path,
                    timeout_s=timeout_s,
                )
                merge_usage(usage_totals, extract_usage(events))
            except subprocess.TimeoutExpired:
                timeout_count += 1
                decision = {"winner": "Tie", "score_a": 0, "score_b": 0, "confidence": 0.0, "reasons": [], "penalties_a": [], "penalties_b": []}
                error = "timeout"
            except Exception as exc:  # noqa: BLE001
                runtime_errors += 1
                decision = {"winner": "Tie", "score_a": 0, "score_b": 0, "confidence": 0.0, "reasons": [], "penalties_a": [], "penalties_b": []}
                error = str(exc)
                if looks_like_invalid_judge_output(error):
                    case_invalid = True

        winner = str(decision.get("winner") or "Tie")
        if winner not in {"A", "B", "Tie"}:
            winner = "Tie"
            case_invalid = True

        score_a = decision.get("score_a")
        score_b = decision.get("score_b")
        if not isinstance(score_a, (int, float)) or not isinstance(score_b, (int, float)):
            case_invalid = True
            score_a = 0.0
            score_b = 0.0

        confidence = decision.get("confidence")
        if not isinstance(confidence, (int, float)):
            confidence = 0.5
            case_invalid = True
        confidence = max(0.0, min(1.0, float(confidence)))
        if case_invalid:
            invalid_json += 1

        is_correct = int(winner == expected)
        correct += is_correct
        confidence_values.append(confidence)
        correctness_values.append(is_correct)

        labeled = margin_labels.get(pair_id)
        pred_margin = float(score_a) - float(score_b)
        if labeled is not None:
            labeled_margin = float(labeled[0] - labeled[1])
            predicted_margins.append(pred_margin)
            labeled_margins.append(labeled_margin)

        critical_expected = any(tag in critical_tags for tag in tags)
        critical_hit = False
        if critical_expected:
            critical_total += 1
            if simulate_no_provider:
                critical_hit = True
            else:
                critical_hit = detect_critical_from_decision(decision, tags=tags) and (winner == expected)
            if critical_hit:
                critical_detected += 1

        by_case.append(
            {
                "run_index": run_index,
                "id": pair_id,
                "split": split,
                "preset_family": preset,
                "expected_winner": expected,
                "winner": winner,
                "score_a": float(score_a),
                "score_b": float(score_b),
                "confidence": confidence,
                "correct": bool(is_correct),
                "critical_expected": critical_expected,
                "critical_detected": critical_hit,
                "error_tags": tags,
                "error": error,
            }
        )

    pairwise_agreement = (correct / total) if total else 0.0
    critical_recall = (critical_detected / critical_total) if critical_total else 0.0
    brier, ece = brier_and_ece(confidence_values, correctness_values)
    conf_profile = calibration_profile(confidence_values, correctness_values, bins=10)
    abs_gaps = [float(bin_row.get("abs_gap", 0.0) or 0.0) for bin_row in conf_profile]
    weighted_abs_gap = sum(
        float(bin_row.get("share", 0.0) or 0.0) * float(bin_row.get("abs_gap", 0.0) or 0.0)
        for bin_row in conf_profile
    )
    spearman_margin = spearman(predicted_margins, labeled_margins) if predicted_margins and labeled_margins else 0.0
    ci95_lower = wilson_lower(correct, total)
    invalid_rate = (invalid_json / total) if total else 0.0
    timeout_rate = (timeout_count / total) if total else 0.0
    runtime_error_rate = (runtime_errors / total) if total else 0.0

    metrics = {
        "pairwise_n": total,
        "pairwise_agreement": pairwise_agreement,
        "pairwise_agreement_ci95_lower": ci95_lower,
        "critical_defect_recall": critical_recall,
        "spearman_margin_vs_label": spearman_margin,
        "brier": brier,
        "ece": ece,
        "confidence_abs_gap_max": max(abs_gaps) if abs_gaps else 0.0,
        "confidence_abs_gap_weighted": weighted_abs_gap,
        "invalid_json_rate": invalid_rate,
        "timeout_rate": timeout_rate,
        "runtime_error_rate": runtime_error_rate,
        "critical_defect_n": critical_total,
        "confidence_calibration_bins": conf_profile,
    }
    return metrics, by_case, usage_totals


def summarize_reruns(runs: list[dict[str, Any]]) -> dict[str, float]:
    keys = [
        "pairwise_n",
        "pairwise_agreement",
        "pairwise_agreement_ci95_lower",
        "critical_defect_recall",
        "spearman_margin_vs_label",
        "brier",
        "ece",
        "confidence_abs_gap_max",
        "confidence_abs_gap_weighted",
        "invalid_json_rate",
        "timeout_rate",
        "runtime_error_rate",
        "critical_defect_n",
    ]
    out: dict[str, float] = {}
    for key in keys:
        vals = [float(run.get(key, 0.0)) for run in runs]
        out[f"{key}_median"] = median(vals)
        out[f"{key}_min"] = min(vals) if vals else 0.0
        out[f"{key}_max"] = max(vals) if vals else 0.0
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Arm J judge-quality calibration.")
    parser.add_argument("--repo", default=str(REPO))
    parser.add_argument("--provider-contract", default=DEFAULT_PROVIDER_CONTRACT)
    parser.add_argument("--dataset-dir", default=str(DEFAULT_DATASET_DIR))
    parser.add_argument("--judge-prompt", default=str(DEFAULT_JUDGE_PROMPT))
    parser.add_argument("--judge-schema", default=str(DEFAULT_SCHEMA))
    parser.add_argument("--splits", default="dev,tune")
    parser.add_argument("--max-pairs", type=int, default=0)
    parser.add_argument("--reruns", type=int, default=5)
    parser.add_argument("--seed", type=int, default=20260305)
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--simulate-no-provider", action="store_true")
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--open-sealed-test", action="store_true")
    parser.add_argument("--open-sealed-test-reason", default="")
    parser.add_argument("--critical-tags", default="role_leakage,safety_boundary,missing_constraint,contract_loss,schema_loss")
    parser.add_argument("--min-pairwise-labels", type=int, default=500)
    parser.add_argument("--pairwise-agreement-min", type=float, default=0.75)
    parser.add_argument("--pairwise-ci95-lower-min", type=float, default=0.50)
    parser.add_argument("--critical-defect-recall-min", type=float, default=0.90)
    parser.add_argument("--critical-defect-cases-min", type=int, default=20)
    parser.add_argument("--invalid-json-rate-max", type=float, default=0.005)
    parser.add_argument("--timeout-rate-max", type=float, default=0.02)
    parser.add_argument("--runtime-error-rate-max", type=float, default=0.01)
    parser.add_argument("--rerun-underflow-delta", type=float, default=0.02)
    args = parser.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    dataset_dir = pathlib.Path(args.dataset_dir).resolve()
    prompt_path = pathlib.Path(args.judge_prompt).resolve()
    schema_path = pathlib.Path(args.judge_schema).resolve()
    splits = parse_splits(args.splits)

    manifest = load_json(dataset_dir / "split_manifest.v1.json")
    open_sealed_guard(
        manifest,
        splits=splits,
        open_sealed_test=bool(args.open_sealed_test),
        open_sealed_test_reason=str(args.open_sealed_test_reason or ""),
    )

    pair_rows = load_jsonl(dataset_dir / "pairwise_labels.jsonl")
    gold_rows = load_jsonl(dataset_dir / "gold_prompts.jsonl")
    perturb_rows = load_jsonl(dataset_dir / "perturbations.jsonl")
    margin_labels = find_margin_scores(pair_rows, gold_rows, perturb_rows)

    selected_rows = [
        row
        for row in pair_rows
        if str(row.get("split") or "") in splits and str(row.get("adjudication_status") or "") == "adjudicated"
    ]
    if not selected_rows:
        raise RuntimeError(f"no adjudicated pairwise rows for splits={sorted(splits)}")

    provider_model = "simulated"
    provider_effort = "simulated"
    if not args.simulate_no_provider:
        try:
            provider = load_codex_judge_provider(repo, args.provider_contract)
        except ProviderContractError as exc:
            raise RuntimeError(f"provider contract load failed: {exc}") from exc
        provider_model = provider["model"]
        provider_effort = provider["reasoning_effort"]

    prompt_template = prompt_path.read_text(encoding="utf-8")
    critical_tags = {tag.strip() for tag in str(args.critical_tags).split(",") if tag.strip()}
    reruns = max(1, int(args.reruns))
    by_case_all: list[dict[str, Any]] = []
    per_run: list[dict[str, Any]] = []
    usage_totals: dict[str, float] = {}
    for run_index in range(reruns):
        sampled = deterministic_sample(
            selected_rows,
            max_rows=max(0, int(args.max_pairs)),
            seed=int(args.seed),
            rerun_index=run_index,
        )
        metrics, by_case, usage = evaluate_run(
            run_index=run_index,
            rows=sampled,
            prompt_template=prompt_template,
            model=provider_model,
            reasoning_effort=provider_effort,
            schema_path=schema_path,
            timeout_s=max(1, int(args.timeout)),
            simulate_no_provider=bool(args.simulate_no_provider),
            critical_tags=critical_tags,
            margin_labels=margin_labels,
        )
        per_run.append(metrics)
        by_case_all.extend(by_case)
        merge_usage(usage_totals, usage)

    aggregate = summarize_reruns(per_run)
    confidence_values_all = [float(row.get("confidence", 0.0) or 0.0) for row in by_case_all]
    correctness_values_all = [1 if bool(row.get("correct")) else 0 for row in by_case_all]
    confidence_profile_all = calibration_profile(confidence_values_all, correctness_values_all, bins=10)
    confidence_abs_gaps_all = [float(bin_row.get("abs_gap", 0.0) or 0.0) for bin_row in confidence_profile_all]
    confidence_weighted_gap_all = sum(
        float(bin_row.get("share", 0.0) or 0.0) * float(bin_row.get("abs_gap", 0.0) or 0.0)
        for bin_row in confidence_profile_all
    )
    checks = {
        "sample_floor": aggregate["pairwise_n_median"] >= float(args.min_pairwise_labels),
        "pairwise_agreement": aggregate["pairwise_agreement_median"] >= float(args.pairwise_agreement_min),
        "pairwise_ci95_lower": aggregate["pairwise_agreement_ci95_lower_median"] >= float(args.pairwise_ci95_lower_min),
        "critical_defect_case_floor": aggregate["critical_defect_n_median"] >= float(args.critical_defect_cases_min),
        "critical_defect_recall": aggregate["critical_defect_recall_median"] >= float(args.critical_defect_recall_min),
        "invalid_json_rate": aggregate["invalid_json_rate_median"] <= float(args.invalid_json_rate_max),
        "timeout_rate": aggregate["timeout_rate_median"] <= float(args.timeout_rate_max),
        "runtime_error_rate": aggregate["runtime_error_rate_median"] <= float(args.runtime_error_rate_max),
    }

    underflow_delta = float(args.rerun_underflow_delta)
    rerun_underflow_violations: list[str] = []
    for idx, run in enumerate(per_run):
        if float(run["pairwise_agreement"]) + underflow_delta < float(args.pairwise_agreement_min):
            rerun_underflow_violations.append(f"run{idx}:pairwise_agreement")
        if float(run["critical_defect_n"]) + underflow_delta < float(args.critical_defect_cases_min):
            rerun_underflow_violations.append(f"run{idx}:critical_defect_case_floor")
        if float(run["critical_defect_recall"]) + underflow_delta < float(args.critical_defect_recall_min):
            rerun_underflow_violations.append(f"run{idx}:critical_defect_recall")
        if float(run["invalid_json_rate"]) - underflow_delta > float(args.invalid_json_rate_max):
            rerun_underflow_violations.append(f"run{idx}:invalid_json_rate")
        if float(run["timeout_rate"]) - underflow_delta > float(args.timeout_rate_max):
            rerun_underflow_violations.append(f"run{idx}:timeout_rate")
        if float(run["runtime_error_rate"]) - underflow_delta > float(args.runtime_error_rate_max):
            rerun_underflow_violations.append(f"run{idx}:runtime_error_rate")
    checks["rerun_stability"] = len(rerun_underflow_violations) == 0

    ok = all(checks.values())
    reason_codes: list[str] = []
    if not checks["sample_floor"]:
        reason_codes.append("CHECK_FAILED:insufficient_sample_size")
    if not checks["critical_defect_case_floor"]:
        reason_codes.append("CHECK_FAILED:insufficient_critical_defect_samples")
    for key, passed in checks.items():
        if key in {"sample_floor", "critical_defect_case_floor"}:
            continue
        if not passed:
            reason_codes.append(f"CHECK_FAILED:{key}")

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = pathlib.Path(args.out_dir).resolve() if args.out_dir else (repo / "bench/prompt_eval/reports" / f"armj_calibration_{stamp}")
    out_dir.mkdir(parents=True, exist_ok=True)
    dataset_fingerprint = compute_dataset_fingerprint(dataset_dir)
    summary = {
        "ok": ok,
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "dataset_dir": str(dataset_dir),
        "splits": sorted(splits),
        "reruns": reruns,
        "simulate_no_provider": bool(args.simulate_no_provider),
        "provider": {
            "runner": "codex" if not args.simulate_no_provider else "simulated",
            "model": provider_model,
            "reasoning_effort": provider_effort,
        },
        "judge_prompt": str(prompt_path),
        "judge_schema": str(schema_path),
        "checks": checks,
        "reason_codes": reason_codes,
        "rerun_underflow_violations": rerun_underflow_violations,
        "thresholds": {
            "min_pairwise_labels": int(args.min_pairwise_labels),
            "pairwise_agreement_min": float(args.pairwise_agreement_min),
            "pairwise_ci95_lower_min": float(args.pairwise_ci95_lower_min),
            "critical_defect_recall_min": float(args.critical_defect_recall_min),
            "critical_defect_cases_min": int(args.critical_defect_cases_min),
            "invalid_json_rate_max": float(args.invalid_json_rate_max),
            "timeout_rate_max": float(args.timeout_rate_max),
            "runtime_error_rate_max": float(args.runtime_error_rate_max),
            "rerun_underflow_delta": underflow_delta,
        },
        "dataset_fingerprint": dataset_fingerprint,
        "aggregate": aggregate,
        "per_run": per_run,
        "confidence_calibration": {
            "bins": confidence_profile_all,
            "abs_gap_max": max(confidence_abs_gaps_all) if confidence_abs_gaps_all else 0.0,
            "abs_gap_weighted": confidence_weighted_gap_all,
        },
        "usage_totals": {k: round(v, 4) for k, v in usage_totals.items()},
    }
    write_json(out_dir / "summary.json", summary)
    write_jsonl(out_dir / "by_case.jsonl", by_case_all)
    print(json.dumps({"ok": ok, "out_dir": str(out_dir), "summary": summary}, indent=2, ensure_ascii=False))
    return 0 if ok else 3


if __name__ == "__main__":
    raise SystemExit(main())
