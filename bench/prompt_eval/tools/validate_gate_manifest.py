#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
from typing import Any


def require_keys(obj: dict[str, Any], keys: list[str], ctx: str) -> list[str]:
    errs = []
    for k in keys:
        if k not in obj:
            errs.append(f"{ctx}: missing key '{k}'")
    return errs


def require_rate(obj: dict[str, Any], key: str, ctx: str) -> list[str]:
    errs = []
    v = obj.get(key)
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        errs.append(f"{ctx}.{key}: must be number")
    elif not (0.0 <= float(v) <= 1.0):
        errs.append(f"{ctx}.{key}: must be within [0,1]")
    return errs


def require_positive(obj: dict[str, Any], key: str, ctx: str, min_val: float = 0.0) -> list[str]:
    errs = []
    v = obj.get(key)
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        errs.append(f"{ctx}.{key}: must be number")
    elif float(v) <= min_val:
        errs.append(f"{ctx}.{key}: must be > {min_val}")
    return errs


def validate(manifest: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    errors += require_keys(manifest, [
        "version",
        "required_preset_families",
        "judge_thresholds",
        "judge_provider_lock",
        "promotion_thresholds",
        "minimum_sample_floors",
        "budget_caps",
        "source_policy",
        "mode_policy",
    ], "root")

    if manifest.get("version") != "v1":
        errors.append("root.version: must equal 'v1'")

    fams = manifest.get("required_preset_families")
    if not isinstance(fams, list) or not fams or not all(isinstance(x, str) and x for x in fams):
        errors.append("root.required_preset_families: must be non-empty list[str]")

    judge = manifest.get("judge_thresholds") if isinstance(manifest.get("judge_thresholds"), dict) else {}
    errors += require_keys(judge, [
        "invalid_json_rate_max",
        "calibration_accuracy_min",
        "symmetry_rate_min",
        "repeat_agreement_min",
        "transitivity_violation_ci_upper_max",
        "shadow_judge_disagreement_max",
        "gold_anchor_accuracy_min",
    ], "judge_thresholds")
    for k in [
        "invalid_json_rate_max",
        "calibration_accuracy_min",
        "symmetry_rate_min",
        "repeat_agreement_min",
        "transitivity_violation_ci_upper_max",
        "shadow_judge_disagreement_max",
        "gold_anchor_accuracy_min",
    ]:
        errors += require_rate(judge, k, "judge_thresholds")

    provider_lock = manifest.get("judge_provider_lock") if isinstance(manifest.get("judge_provider_lock"), dict) else {}
    errors += require_keys(provider_lock, ["primary", "shadow"], "judge_provider_lock")
    for side in ["primary", "shadow"]:
        node = provider_lock.get(side) if isinstance(provider_lock.get(side), dict) else {}
        errors += require_keys(node, ["runner", "model", "reasoning_effort"], f"judge_provider_lock.{side}")
        for key in ["runner", "model", "reasoning_effort"]:
            val = node.get(key)
            if not isinstance(val, str) or not val.strip():
                errors.append(f"judge_provider_lock.{side}.{key}: must be non-empty string")

    promo = manifest.get("promotion_thresholds") if isinstance(manifest.get("promotion_thresholds"), dict) else {}
    errors += require_keys(promo, [
        "holdout_winrate_ci95_lower_min",
        "holdout_non_loss_rate_min",
        "holm_adjusted_pvalue_max",
        "repeat_winrate_stddev_max",
        "critical_failures_max",
        "pairwise_orientation_disagreement_max",
        "timeout_rate_max",
    ], "promotion_thresholds")
    for k in [
        "holdout_winrate_ci95_lower_min",
        "holdout_non_loss_rate_min",
        "holm_adjusted_pvalue_max",
        "repeat_winrate_stddev_max",
        "pairwise_orientation_disagreement_max",
        "timeout_rate_max",
    ]:
        errors += require_rate(promo, k, "promotion_thresholds")
    if (
        not isinstance(promo.get("critical_failures_max"), int)
        or isinstance(promo.get("critical_failures_max"), bool)
        or promo["critical_failures_max"] < 0
    ):
        errors.append("promotion_thresholds.critical_failures_max: must be int >= 0")

    floors = manifest.get("minimum_sample_floors") if isinstance(manifest.get("minimum_sample_floors"), dict) else {}
    errors += require_keys(floors, [
        "critical_failure_checked_cases_min",
        "holdout_non_tie_pairs_per_family_min",
        "holdout_looks_per_cycle_max",
        "judge_calibration_pairs_min",
        "judge_triads_per_family_min",
        "shadow_spotcheck_pairs_min",
        "gold_anchor_pairs_min",
        "judge_repeats_min",
        "pairwise_orientation_pairs_min",
    ], "minimum_sample_floors")
    for k in [
        "critical_failure_checked_cases_min",
        "holdout_non_tie_pairs_per_family_min",
        "holdout_looks_per_cycle_max",
        "judge_calibration_pairs_min",
        "judge_triads_per_family_min",
        "shadow_spotcheck_pairs_min",
        "gold_anchor_pairs_min",
        "judge_repeats_min",
        "pairwise_orientation_pairs_min",
    ]:
        if (
            not isinstance(floors.get(k), int)
            or isinstance(floors.get(k), bool)
            or floors[k] <= 0
        ):
            errors.append(f"minimum_sample_floors.{k}: must be int > 0")

    budget = manifest.get("budget_caps") if isinstance(manifest.get("budget_caps"), dict) else {}
    errors += require_keys(budget, [
        "cycle_max_tokens",
        "cycle_max_cost_usd",
        "cycle_max_wall_clock_minutes",
        "warning_ratio",
    ], "budget_caps")
    for k in ["cycle_max_tokens", "cycle_max_cost_usd", "cycle_max_wall_clock_minutes"]:
        errors += require_positive(budget, k, "budget_caps", 0.0)
    errors += require_rate(budget, "warning_ratio", "budget_caps")

    source_policy = manifest.get("source_policy") if isinstance(manifest.get("source_policy"), dict) else {}
    errors += require_keys(source_policy, [
        "research_artifact_path",
        "required_provider_coverage",
        "minimum_total_sources",
        "minimum_recent_non_provider_sources",
        "minimum_recent_source_date",
    ], "source_policy")
    research_artifact_path = source_policy.get("research_artifact_path")
    if not isinstance(research_artifact_path, str) or not research_artifact_path.strip():
        errors.append("source_policy.research_artifact_path: must be non-empty string")
    provider_coverage = source_policy.get("required_provider_coverage")
    if (
        not isinstance(provider_coverage, list)
        or not provider_coverage
        or not all(isinstance(x, str) and x for x in provider_coverage)
    ):
        errors.append("source_policy.required_provider_coverage: must be non-empty list[str]")
    else:
        allowed = {"openai", "anthropic", "google", "promptfoo"}
        unknown = sorted(set(provider_coverage) - allowed)
        if unknown:
            errors.append(
                "source_policy.required_provider_coverage: unknown providers: "
                + ", ".join(unknown)
            )
    for k in ["minimum_total_sources", "minimum_recent_non_provider_sources"]:
        if (
            not isinstance(source_policy.get(k), int)
            or isinstance(source_policy.get(k), bool)
            or source_policy[k] <= 0
        ):
            errors.append(f"source_policy.{k}: must be int > 0")
    min_recent_date = source_policy.get("minimum_recent_source_date")
    if not isinstance(min_recent_date, str):
        errors.append("source_policy.minimum_recent_source_date: must be YYYY-MM-DD string")
    else:
        try:
            dt.date.fromisoformat(min_recent_date)
        except ValueError:
            errors.append("source_policy.minimum_recent_source_date: invalid YYYY-MM-DD date")

    mode_policy = manifest.get("mode_policy") if isinstance(manifest.get("mode_policy"), dict) else {}
    errors += require_keys(mode_policy, [
        "fail_closed_manifest_validation",
        "enforce_holdout_isolation",
        "allow_policy_mutation_mid_cycle",
    ], "mode_policy")
    for k in ["fail_closed_manifest_validation", "enforce_holdout_isolation", "allow_policy_mutation_mid_cycle"]:
        if not isinstance(mode_policy.get(k), bool):
            errors.append(f"mode_policy.{k}: must be boolean")

    return errors


def main() -> int:
    ap = argparse.ArgumentParser(description="Validate gate manifest (fail-closed)")
    ap.add_argument("--manifest", default="bench/prompt_eval/config/gate_manifest.v1.json")
    args = ap.parse_args()

    path = pathlib.Path(args.manifest).resolve()
    manifest = json.loads(path.read_text(encoding="utf-8"))
    errors = validate(manifest)

    out = {
        "ok": len(errors) == 0,
        "manifest": str(path),
        "error_count": len(errors),
        "errors": errors,
    }
    print(json.dumps(out, indent=2, ensure_ascii=False))
    return 0 if not errors else 2


if __name__ == "__main__":
    raise SystemExit(main())
