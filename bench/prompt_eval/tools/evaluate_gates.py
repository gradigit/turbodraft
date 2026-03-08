#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
from typing import Any


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def ci_wilson_lower(wins: int, total: int, z: float = 1.959963984540054) -> float:
    if total <= 0:
        return 0.0
    p = wins / total
    denom = 1 + (z**2 / total)
    center = p + (z**2 / (2 * total))
    margin = z * ((p * (1 - p) / total + z**2 / (4 * total**2)) ** 0.5)
    return (center - margin) / denom


def as_float(value: Any, default: float) -> float:
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return float(value)
    return default


def choose_best_variant(summary: dict[str, Any], baseline_variant: str) -> tuple[str | None, dict[str, Any]]:
    best_name = None
    best_data: dict[str, Any] = {}
    best_score = -1.0
    for variant, data in (summary.get("results") or {}).items():
        if variant == baseline_variant:
            continue
        pair = data.get("pairwise_vs_baseline") or {}
        score = float(pair.get("win_rate", 0.0) or 0.0)
        if score > best_score:
            best_name = variant
            best_data = data
            best_score = score
    return best_name, best_data


def family_gate_snapshot(
    phase_summary: dict[str, Any],
    required_families: list[str],
    baseline_variant: str,
) -> dict[str, dict[str, Any]]:
    family_results = phase_summary.get("family_results")
    snapshot: dict[str, dict[str, Any]] = {}

    if isinstance(family_results, dict):
        for family in required_families:
            details = family_results.get(family)
            if not isinstance(details, dict):
                snapshot[family] = {"present": False, "best_variant": None, "pair": {}}
                continue
            pair = details.get("best_pairwise_vs_baseline") or {}
            best_variant = details.get("best_variant")
            snapshot[family] = {
                "present": True,
                "best_variant": best_variant if isinstance(best_variant, str) and best_variant else None,
                "pair": pair if isinstance(pair, dict) else {},
            }
        return snapshot

    for family in required_families:
        snapshot[family] = {
            "present": False,
            "best_variant": None,
            "pair": {},
        }
    return snapshot


def main() -> int:
    ap = argparse.ArgumentParser(description="Evaluate phase gate pass/fail from report artifacts")
    ap.add_argument("--gate-manifest", default="bench/prompt_eval/config/gate_manifest.v1.json")
    ap.add_argument("--calibration-summary", required=True)
    ap.add_argument("--symmetry-summary", required=True)
    ap.add_argument("--phase-summary", required=True)
    ap.add_argument("--judge-audit", default="")
    ap.add_argument("--armj-calibration-summary", default="")
    ap.add_argument("--armj-invariance-summary", default="")
    ap.add_argument("--armo-summary", default="")
    strict_group = ap.add_mutually_exclusive_group()
    strict_group.add_argument("--strict", dest="strict", action="store_true")
    strict_group.add_argument("--non-strict", dest="strict", action="store_false")
    ap.set_defaults(strict=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    gate = load_json(pathlib.Path(args.gate_manifest).resolve())
    cal = load_json(pathlib.Path(args.calibration_summary).resolve())
    sym = load_json(pathlib.Path(args.symmetry_summary).resolve())
    phase = load_json(pathlib.Path(args.phase_summary).resolve())
    judge_audit: dict[str, Any] = {}
    if args.judge_audit:
        judge_audit = load_json(pathlib.Path(args.judge_audit).resolve())
    armj_calibration: dict[str, Any] = {}
    if args.armj_calibration_summary:
        armj_calibration = load_json(pathlib.Path(args.armj_calibration_summary).resolve())
    armj_invariance: dict[str, Any] = {}
    if args.armj_invariance_summary:
        armj_invariance = load_json(pathlib.Path(args.armj_invariance_summary).resolve())
    armo_summary: dict[str, Any] = {}
    if args.armo_summary:
        armo_summary = load_json(pathlib.Path(args.armo_summary).resolve())

    judge_t = gate["judge_thresholds"]
    judge_lock_t = gate.get("judge_lock_thresholds") or {}
    outcome_align_t = gate.get("outcome_alignment_thresholds") or {}
    provider_lock = gate.get("judge_provider_lock") or {}
    promo_t = gate["promotion_thresholds"]
    floor_t = gate["minimum_sample_floors"]
    required_families = list(gate.get("required_preset_families") or [])

    recommended = cal.get("recommended_prompt") or {}
    n_cal = int(recommended.get("n", 0) or 0)
    acc = float(recommended.get("accuracy", 0.0) or 0.0)
    invalid = int(recommended.get("invalid_count", 0) or 0)
    invalid_rate = invalid / max(1, n_cal)

    symmetry = float(sym.get("symmetry_rate", 0.0) or 0.0)
    repeat = min(
        float(sym.get("forward_repeat_agreement", 0.0) or 0.0),
        float(sym.get("reverse_repeat_agreement", 0.0) or 0.0),
    )

    baseline = phase.get("baseline_variant", "overlay_baseline")
    best_variant, best_data = choose_best_variant(phase, baseline)
    pair = best_data.get("pairwise_vs_baseline") or {}
    n_pair = int(pair.get("n", 0) or 0)
    wins = int(pair.get("wins", 0) or 0)
    losses = int(pair.get("losses", 0) or 0)
    ties = int(pair.get("ties", 0) or 0)
    non_tie_n = int(pair.get("non_tie_n", 0) or 0)
    if non_tie_n <= 0:
        non_tie_n = max(0, wins + losses)
    if (wins + losses + ties) <= 0 and n_pair > 0:
        # Backward-compatible fallback for older summaries that only include rates.
        wins = round(float(pair.get("win_rate", 0.0) or 0.0) * n_pair)
        losses = round(float(pair.get("loss_rate", 0.0) or 0.0) * n_pair)
        ties = max(0, n_pair - wins - losses)
        non_tie_n = wins + losses
    win_rate = float(pair.get("win_rate", 0.0) or 0.0)
    non_loss_rate = float(pair.get("non_loss_rate", 0.0) or 0.0)
    ci_lower = ci_wilson_lower(wins, non_tie_n)

    promotion_stats = phase.get("promotion_statistics")
    if not isinstance(promotion_stats, dict):
        promotion_stats = {}
    holm_max = promotion_stats.get("family_holm_adjusted_pvalue_max")
    repeat_stddev_max = promotion_stats.get("repeat_winrate_stddev_max")
    critical_failures = promotion_stats.get("critical_failures")
    critical_checked_cases = promotion_stats.get("critical_failure_checked_cases")
    simulated_artifacts = bool(phase.get("simulated_artifacts", False) or promotion_stats.get("simulated_artifacts", False))
    orientation_pairs_evaluated = int(phase.get("pairwise_orientation_pairs_evaluated", 0) or 0)
    orientation_raw = phase.get("pairwise_orientation_disagreement_rate")
    orientation_disagreement_rate = float(orientation_raw) if isinstance(orientation_raw, (int, float)) else None
    error_stats = phase.get("error_stats") if isinstance(phase.get("error_stats"), dict) else {}
    timeout_rate = float(error_stats.get("model_timeout_rate", 0.0) or 0.0)

    family_snapshot = family_gate_snapshot(phase, required_families, baseline)
    family_presence_ok = all(family_snapshot[f]["present"] for f in required_families)
    family_non_loss_ok = True
    family_ci_ok = True
    family_floor_ok = True
    family_non_tie_counts: dict[str, int] = {}
    family_ci_lower: dict[str, float] = {}
    family_non_loss: dict[str, float] = {}
    for family in required_families:
        info = family_snapshot[family]
        pair_data = info.get("pair") or {}
        fwins = int(pair_data.get("wins", 0) or 0)
        flosses = int(pair_data.get("losses", 0) or 0)
        fnon_tie = int(pair_data.get("non_tie_n", 0) or 0)
        if fnon_tie <= 0:
            fnon_tie = max(0, fwins + flosses)
        family_non_tie_counts[family] = fnon_tie
        fci = ci_wilson_lower(fwins, fnon_tie)
        family_ci_lower[family] = fci
        fnon_loss = float(pair_data.get("non_loss_rate", 0.0) or 0.0)
        family_non_loss[family] = fnon_loss
        if fnon_loss < float(promo_t["holdout_non_loss_rate_min"]):
            family_non_loss_ok = False
        if fci < float(promo_t["holdout_winrate_ci95_lower_min"]):
            family_ci_ok = False
        if fnon_tie < int(floor_t["holdout_non_tie_pairs_per_family_min"]):
            family_floor_ok = False

    audit_mode = str(judge_audit.get("mode", "unknown"))
    metrics = judge_audit.get("metrics") if isinstance(judge_audit.get("metrics"), dict) else {}
    trans = metrics.get("transitivity") if isinstance(metrics.get("transitivity"), dict) else {}
    shadow = metrics.get("shadow_drift") if isinstance(metrics.get("shadow_drift"), dict) else {}
    gold = metrics.get("gold_anchor") if isinstance(metrics.get("gold_anchor"), dict) else {}

    transitivity_ok = bool(judge_audit.get("transitivity_ok", False))
    shadow_ok = bool(judge_audit.get("shadow_drift_ok", False))
    gold_ok = bool(judge_audit.get("gold_anchor_ok", False))
    if trans:
        transitivity_ok = float(trans.get("violation_ci95_upper", 1.0) or 1.0) <= float(judge_t["transitivity_violation_ci_upper_max"])
    if shadow:
        shadow_ok = float(shadow.get("disagreement_rate", 1.0) or 1.0) <= float(judge_t["shadow_judge_disagreement_max"])
    if gold:
        gold_ok = float(gold.get("accuracy", 0.0) or 0.0) >= float(judge_t["gold_anchor_accuracy_min"])

    primary = (judge_audit.get("providers") or {}).get("primary") if isinstance(judge_audit.get("providers"), dict) else {}
    shadow_provider = (judge_audit.get("providers") or {}).get("shadow") if isinstance(judge_audit.get("providers"), dict) else {}
    provider_lock_ok = True
    if provider_lock:
        req_primary = provider_lock.get("primary") or {}
        req_shadow = provider_lock.get("shadow") or {}
        provider_lock_ok = (
            isinstance(primary, dict)
            and isinstance(shadow_provider, dict)
            and str(primary.get("runner", "")).lower() == str(req_primary.get("runner", "")).lower()
            and str(primary.get("model", "")).lower() == str(req_primary.get("model", "")).lower()
            and str(primary.get("reasoning_effort", "")).lower() == str(req_primary.get("reasoning_effort", "")).lower()
            and str(shadow_provider.get("runner", "")).lower() == str(req_shadow.get("runner", "")).lower()
            and str(shadow_provider.get("model", "")).lower() == str(req_shadow.get("model", "")).lower()
            and str(shadow_provider.get("reasoning_effort", "")).lower() == str(req_shadow.get("reasoning_effort", "")).lower()
        )
    audit_real_provider_ok = audit_mode == "real"

    if not args.strict:
        transitivity_ok = True if not args.judge_audit else transitivity_ok
        shadow_ok = True if not args.judge_audit else shadow_ok
        gold_ok = True if not args.judge_audit else gold_ok
        provider_lock_ok = True if not args.judge_audit else provider_lock_ok
        audit_real_provider_ok = True if not args.judge_audit else audit_real_provider_ok

    # Optional Arm J lock checks (active only when summaries are provided).
    armj_enabled = bool(armj_calibration and armj_invariance)
    armj_checks: dict[str, bool] = {}
    armj_metrics: dict[str, Any] = {}
    if armj_enabled and isinstance(judge_lock_t, dict):
        cal_agg = armj_calibration.get("aggregate") if isinstance(armj_calibration.get("aggregate"), dict) else {}
        inv_agg = armj_invariance.get("aggregate") if isinstance(armj_invariance.get("aggregate"), dict) else {}
        cal_reruns = int(armj_calibration.get("reruns", 0) or 0)
        inv_reruns = int(armj_invariance.get("reruns", 0) or 0)
        armj_metrics = {
            "pairwise_n_median": cal_agg.get("pairwise_n_median"),
            "pairwise_agreement_median": cal_agg.get("pairwise_agreement_median"),
            "pairwise_agreement_ci95_lower_median": cal_agg.get("pairwise_agreement_ci95_lower_median"),
            "critical_defect_recall_median": cal_agg.get("critical_defect_recall_median"),
            "invalid_json_rate_median": cal_agg.get("invalid_json_rate_median"),
            "runtime_error_rate_median": cal_agg.get("runtime_error_rate_median"),
            "timeout_rate_median": cal_agg.get("timeout_rate_median"),
            "order_swap_flip_rate_median": inv_agg.get("order_swap_flip_rate_median"),
            "repeat_agreement_median": inv_agg.get("repeat_agreement_median"),
            "paraphrase_drift_median": inv_agg.get("paraphrase_median_abs_drift_median"),
            "verbosity_drift_median": inv_agg.get("verbosity_median_abs_drift_median"),
            "family_source_bias_delta_median": inv_agg.get("family_source_bias_delta_median"),
            "attack_success_rate_median": inv_agg.get("attack_success_rate_median"),
            "attack_invalid_json_amplification_median": inv_agg.get("attack_invalid_json_amplification_median"),
            "reruns_min_observed": min(cal_reruns, inv_reruns),
        }
        armj_checks = {
            "judge_lock_pairwise_labels_floor": as_float(armj_metrics.get("pairwise_n_median"), 0.0)
            >= float(judge_lock_t.get("pairwise_labels_min", 0)),
            "judge_lock_pairwise_agreement": as_float(armj_metrics.get("pairwise_agreement_median"), 0.0)
            >= float(judge_lock_t.get("pairwise_agreement_min", 0)),
            "judge_lock_pairwise_ci95_lower": as_float(armj_metrics.get("pairwise_agreement_ci95_lower_median"), 0.0)
            >= float(judge_lock_t.get("pairwise_agreement_ci95_lower_min", 0)),
            "judge_lock_critical_defect_recall": as_float(armj_metrics.get("critical_defect_recall_median"), 0.0)
            >= float(judge_lock_t.get("critical_defect_recall_min", 0)),
            "judge_lock_order_swap_flip_rate": as_float(armj_metrics.get("order_swap_flip_rate_median"), 1.0)
            <= float(judge_lock_t.get("order_swap_flip_rate_max", 1.0)),
            "judge_lock_repeat_agreement": as_float(armj_metrics.get("repeat_agreement_median"), 0.0)
            >= float(judge_lock_t.get("repeat_agreement_min", 0)),
            "judge_lock_paraphrase_drift": as_float(armj_metrics.get("paraphrase_drift_median"), 999.0)
            <= float(judge_lock_t.get("paraphrase_drift_median_max", 999.0)),
            "judge_lock_verbosity_drift": as_float(armj_metrics.get("verbosity_drift_median"), 999.0)
            <= float(judge_lock_t.get("verbosity_drift_median_max", 999.0)),
            "judge_lock_family_source_bias_delta": as_float(armj_metrics.get("family_source_bias_delta_median"), 999.0)
            <= float(judge_lock_t.get("family_source_bias_delta_max", 999.0)),
            "judge_lock_attack_success_rate": as_float(armj_metrics.get("attack_success_rate_median"), 1.0)
            <= float(judge_lock_t.get("attack_success_rate_max", 1.0)),
            "judge_lock_attack_invalid_json_amplification": as_float(
                armj_metrics.get("attack_invalid_json_amplification_median"), 999.0
            )
            <= float(judge_lock_t.get("attack_invalid_json_amplification_max", 999.0)),
            "judge_lock_invalid_json_rate": as_float(armj_metrics.get("invalid_json_rate_median"), 1.0)
            <= float(judge_lock_t.get("invalid_json_rate_max", 1.0)),
            "judge_lock_runtime_error_rate": as_float(armj_metrics.get("runtime_error_rate_median"), 1.0)
            <= float(judge_lock_t.get("runtime_error_rate_max", 1.0)),
            "judge_lock_timeout_rate": as_float(armj_metrics.get("timeout_rate_median"), 1.0)
            <= float(judge_lock_t.get("timeout_rate_max", 1.0)),
            "judge_lock_rerun_floor": as_float(armj_metrics.get("reruns_min_observed"), 0.0)
            >= float(judge_lock_t.get("reruns_min", 0)),
        }

    # Optional Arm O + meta-agreement checks.
    armo_enabled = bool(armo_summary)
    armo_checks: dict[str, bool] = {}
    armo_metrics: dict[str, Any] = {}
    if armo_enabled and isinstance(outcome_align_t, dict):
        metrics = armo_summary.get("metrics") if isinstance(armo_summary.get("metrics"), dict) else {}
        armo_metrics = {
            "meta_rho": armo_summary.get("rho_spearman"),
            "meta_rho_ci95_lower": ((armo_summary.get("rho_ci95") or [None, None])[0] if isinstance(armo_summary.get("rho_ci95"), list) else None),
            "outcome_total_tasks": metrics.get("total_tasks"),
            "outcome_family_counts": metrics.get("family_non_tie_counts") if isinstance(metrics.get("family_non_tie_counts"), dict) else {},
            "exploration_share": metrics.get("exploration_share"),
        }
        family_counts = armo_metrics["outcome_family_counts"] if isinstance(armo_metrics["outcome_family_counts"], dict) else {}
        armo_checks = {
            "outcome_meta_rho": as_float(armo_metrics.get("meta_rho"), 0.0)
            >= float(outcome_align_t.get("meta_rho_min", 0)),
            "outcome_meta_rho_ci95_lower": as_float(armo_metrics.get("meta_rho_ci95_lower"), 0.0)
            >= float(outcome_align_t.get("meta_rho_ci95_lower_min", 0)),
            "outcome_total_tasks_floor": as_float(armo_metrics.get("outcome_total_tasks"), 0.0)
            >= float(outcome_align_t.get("outcome_total_tasks_min", 0)),
            "outcome_per_family_floor": (
                True
                if float(outcome_align_t.get("outcome_per_family_tasks_min", 0)) <= 0
                else (
                    bool(family_counts)
                    and all(
                        float(v) >= float(outcome_align_t.get("outcome_per_family_tasks_min", 0))
                        for v in family_counts.values()
                        if isinstance(v, (int, float))
                    )
                )
            ),
            "outcome_exploration_share_floor": as_float(armo_metrics.get("exploration_share"), 0.0)
            >= float(outcome_align_t.get("exploration_share_min", 0)),
        }

    armj_required_in_strict = bool(args.strict and isinstance(judge_lock_t, dict) and len(judge_lock_t) > 0)
    armo_required_in_strict = bool(args.strict and isinstance(outcome_align_t, dict) and len(outcome_align_t) > 0)

    checks: dict[str, bool] = {
        "judge_invalid_json_rate": invalid_rate <= float(judge_t["invalid_json_rate_max"]),
        "judge_calibration_accuracy": acc >= float(judge_t["calibration_accuracy_min"]),
        "judge_calibration_sample_floor": n_cal >= int(floor_t.get("judge_calibration_pairs_min", 1)),
        "judge_symmetry": symmetry >= float(judge_t["symmetry_rate_min"]),
        "judge_repeat_agreement": repeat >= float(judge_t["repeat_agreement_min"]),
        "judge_provider_lock": provider_lock_ok,
        "judge_audit_real_provider": audit_real_provider_ok,
        "judge_transitivity": transitivity_ok,
        "judge_shadow_drift": shadow_ok,
        "judge_gold_anchor": gold_ok,
        "promotion_no_simulated_artifacts": not simulated_artifacts,
        "promotion_non_loss": non_loss_rate >= float(promo_t["holdout_non_loss_rate_min"]),
        "promotion_ci95_lower": ci_lower >= float(promo_t["holdout_winrate_ci95_lower_min"]),
        "promotion_sample_floor": non_tie_n >= int(floor_t["holdout_non_tie_pairs_per_family_min"]),
        "promotion_required_family_coverage": family_presence_ok,
        "promotion_per_family_non_loss": family_non_loss_ok,
        "promotion_per_family_ci95_lower": family_ci_ok,
        "promotion_per_family_sample_floor": family_floor_ok,
        "promotion_pairwise_orientation_sample_floor": (
            orientation_pairs_evaluated >= int(floor_t.get("pairwise_orientation_pairs_min", 1))
        ),
        "promotion_pairwise_orientation_stability": (
            isinstance(orientation_disagreement_rate, (int, float))
            and orientation_disagreement_rate <= float(promo_t.get("pairwise_orientation_disagreement_max", 1.0))
        ),
        "promotion_timeout_rate": (
            timeout_rate <= float(promo_t.get("timeout_rate_max", 1.0))
        ),
        "promotion_holm_adjusted_pvalue": (
            isinstance(holm_max, (int, float))
            and float(holm_max) <= float(promo_t["holm_adjusted_pvalue_max"])
        ),
        "promotion_repeat_winrate_stddev": (
            isinstance(repeat_stddev_max, (int, float))
            and float(repeat_stddev_max) <= float(promo_t["repeat_winrate_stddev_max"])
        ),
        "promotion_critical_failure_count": (
            isinstance(critical_failures, int)
            and int(critical_failures) <= int(promo_t["critical_failures_max"])
        ),
        "promotion_critical_failure_sample_floor": (
            isinstance(critical_checked_cases, int)
            and int(critical_checked_cases) >= int(floor_t["critical_failure_checked_cases_min"])
        ),
        "judge_lock_artifacts_present": (armj_enabled if armj_required_in_strict else True),
        "outcome_alignment_artifact_present": (armo_enabled if armo_required_in_strict else True),
    }
    checks.update(armj_checks)
    checks.update(armo_checks)

    if args.strict:
        blocking_names = list(checks.keys())
    else:
        blocking_names = [
            "promotion_no_simulated_artifacts",
            "judge_invalid_json_rate",
            "judge_calibration_accuracy",
            "judge_calibration_sample_floor",
            "judge_symmetry",
            "judge_repeat_agreement",
        ]

    reason_codes: list[str] = []
    warning_codes: list[str] = []
    for name, passed in checks.items():
        if not passed:
            if name in blocking_names:
                reason_codes.append(f"CHECK_FAILED:{name}")
            else:
                warning_codes.append(f"CHECK_WARN:{name}")

    out = {
        "ok": len(reason_codes) == 0,
        "strict_mode": args.strict,
        "blocking_checks": blocking_names,
        "best_variant": best_variant,
        "metrics": {
            "judge": {
                "n_calibration": n_cal,
                "accuracy": acc,
                "invalid_rate": invalid_rate,
                "symmetry_rate": symmetry,
                "repeat_agreement_min": repeat,
                "transitivity_ok": transitivity_ok,
                "shadow_drift_ok": shadow_ok,
                "gold_anchor_ok": gold_ok,
                "audit_mode": audit_mode,
                "provider_lock_ok": provider_lock_ok,
                "transitivity_violation_ci95_upper": trans.get("violation_ci95_upper") if isinstance(trans, dict) else None,
                "shadow_disagreement_rate": shadow.get("disagreement_rate") if isinstance(shadow, dict) else None,
                "gold_anchor_accuracy": gold.get("accuracy") if isinstance(gold, dict) else None,
            },
            "judge_lock": armj_metrics,
            "promotion": {
                "n_pairwise": n_pair,
                "wins": wins,
                "losses": losses,
                "ties": ties,
                "non_tie_n": non_tie_n,
                "win_rate": win_rate,
                "non_loss_rate": non_loss_rate,
                "win_rate_ci95_lower": ci_lower,
                "required_families": required_families,
                "family_presence": {k: bool(v["present"]) for k, v in family_snapshot.items()},
                "family_best_variants": {k: v["best_variant"] for k, v in family_snapshot.items()},
                "family_non_tie_n": family_non_tie_counts,
                "family_non_loss_rate": family_non_loss,
                "family_win_rate_ci95_lower": family_ci_lower,
                "holm_adjusted_pvalue_max": holm_max,
                "repeat_winrate_stddev_max": repeat_stddev_max,
                "critical_failures": critical_failures,
                "critical_failure_checked_cases": critical_checked_cases,
                "simulated_artifacts": simulated_artifacts,
                "pairwise_orientation_pairs_evaluated": orientation_pairs_evaluated,
                "pairwise_orientation_disagreement_rate": orientation_disagreement_rate,
                "model_timeout_rate": timeout_rate,
            },
            "outcome_alignment": armo_metrics,
        },
        "checks": checks,
        "reason_codes": reason_codes,
        "warning_codes": warning_codes,
    }

    out_path = pathlib.Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"ok": out["ok"], "out": str(out_path), "result": out}, indent=2, ensure_ascii=False))
    return 0 if out["ok"] else 3


if __name__ == "__main__":
    raise SystemExit(main())
