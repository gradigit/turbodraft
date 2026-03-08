#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import subprocess
from collections import Counter, defaultdict
from typing import Any


REPO = pathlib.Path(__file__).resolve().parents[3]
DEFAULT_DATASETS_ROOT = REPO / "bench/prompt_eval/datasets"
DEFAULT_GATE_MANIFEST = REPO / "bench/prompt_eval/config/gate_manifest.v1.json"


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def stable_hash_object(payload: Any) -> str:
    data = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def iter_jsonl(path: pathlib.Path):
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            raw = line.strip()
            if not raw:
                continue
            yield json.loads(raw)


def as_float(value: Any, default: float = 0.0) -> float:
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return float(value)
    return default


def ci_wilson_lower(wins: int, total: int, z: float = 1.959963984540054) -> float:
    if total <= 0:
        return 0.0
    p = wins / total
    denom = 1 + (z**2 / total)
    center = p + (z**2 / (2 * total))
    margin = z * ((p * (1 - p) / total + z**2 / (4 * total**2)) ** 0.5)
    return (center - margin) / denom


def run_dataset_integrity_check(datasets_root: pathlib.Path) -> dict[str, Any]:
    cmd = [
        "python3",
        str(REPO / "bench/prompt_eval/tools/check_dataset_integrity.py"),
        "--datasets-root",
        str(datasets_root),
        "--fail-on-near-duplicate",
        "--strict-pairwise-linkage",
    ]
    proc = subprocess.run(cmd, text=True, capture_output=True)
    payload: dict[str, Any] = {}
    try:
        payload = json.loads(proc.stdout) if proc.stdout.strip() else {}
    except Exception:
        payload = {}
    return {
        "ok": bool(proc.returncode == 0 and payload.get("ok") is True),
        "returncode": int(proc.returncode),
        "error_count": int(payload.get("error_count", 0) or 0),
        "warning_count": int(payload.get("warning_count", 0) or 0),
        "errors": list(payload.get("errors", [])[:25]) if isinstance(payload.get("errors"), list) else [],
        "stderr_tail": proc.stderr.strip().splitlines()[-5:] if proc.stderr else [],
    }


def compute_dataset_metrics(
    datasets_root: pathlib.Path,
    *,
    required_families: list[str],
    sealed_label_source_class_required: str,
) -> dict[str, Any]:
    jq_dir = datasets_root / "judge_quality"

    pair_family_counts: Counter[str] = Counter()
    pair_lang_counts: Counter[str] = Counter()
    pair_total = 0
    sealed_pair_count = 0
    pair_linked_rows = 0

    # parent lineage split collision check
    lineage_splits: dict[str, set[str]] = defaultdict(set)

    sealed_provenance_violations: list[str] = []

    def ingest_row(row: dict[str, Any], *, row_kind: str) -> None:
        split = str(row.get("split") or "")
        row_id = str(row.get("id") or "")
        parent = str(row.get("parent_prompt_id") or "")
        if parent:
            lineage_splits[parent].add(split)

        if split == "sealed_test":
            label_source = str(row.get("label_source_class") or "")
            if label_source != sealed_label_source_class_required:
                sealed_provenance_violations.append(
                    f"{row_kind}:{row_id}:label_source_class={label_source or '<missing>'}"
                )
            negative_origin = str(row.get("negative_origin") or "")
            if negative_origin == "synthetic":
                sealed_provenance_violations.append(f"{row_kind}:{row_id}:negative_origin=synthetic")

    for row in iter_jsonl(jq_dir / "gold_prompts.jsonl"):
        ingest_row(row, row_kind="gold")
    for row in iter_jsonl(jq_dir / "perturbations.jsonl"):
        ingest_row(row, row_kind="perturb")
    for row in iter_jsonl(jq_dir / "pairwise_labels.jsonl"):
        ingest_row(row, row_kind="pair")

        pair_total += 1
        if (
            isinstance(row.get("perturbation_id"), str)
            and bool(str(row.get("perturbation_id")).strip())
            and isinstance(row.get("candidate_a_text_sha256"), str)
            and bool(str(row.get("candidate_a_text_sha256")).strip())
            and isinstance(row.get("candidate_b_text_sha256"), str)
            and bool(str(row.get("candidate_b_text_sha256")).strip())
        ):
            pair_linked_rows += 1
        family = str(row.get("preset_family") or "unknown")
        lang = str(row.get("language_tag") or "unknown")
        split = str(row.get("split") or "")
        pair_family_counts[family] += 1
        pair_lang_counts[lang] += 1
        if split == "sealed_test":
            sealed_pair_count += 1

    family_count = len(pair_family_counts)
    language_count = len(pair_lang_counts)
    max_family_share = 0.0
    if pair_total > 0:
        max_family_share = max(count / pair_total for count in pair_family_counts.values())

    lineage_collisions = sorted(
        parent for parent, splits in lineage_splits.items() if len({s for s in splits if s}) > 1
    )
    required_set = {str(x) for x in required_families if str(x).strip()}
    observed_set = set(pair_family_counts.keys())
    missing_required_families = sorted(required_set - observed_set)
    unexpected_families = sorted(observed_set - required_set)

    violation_total = len(sealed_provenance_violations)
    return {
        "pairwise_labels_total": pair_total,
        "pairwise_labels_sealed": sealed_pair_count,
        "pairwise_linked_rows": pair_linked_rows,
        "pairwise_by_family": dict(sorted(pair_family_counts.items())),
        "pairwise_by_language": dict(sorted(pair_lang_counts.items())),
        "family_count": family_count,
        "language_count": language_count,
        "max_family_share": max_family_share,
        "sealed_provenance_violation_total": violation_total,
        "sealed_provenance_violations": sealed_provenance_violations[:100],
        "lineage_collision_count": len(lineage_collisions),
        "lineage_collisions": lineage_collisions[:50],
        "required_families": sorted(required_set),
        "missing_required_families": missing_required_families,
        "unexpected_families": unexpected_families,
    }


def compute_armj_metrics(calibration_summary: dict[str, Any], invariance_summary: dict[str, Any]) -> dict[str, float]:
    cal = calibration_summary.get("aggregate") if isinstance(calibration_summary.get("aggregate"), dict) else {}
    inv = invariance_summary.get("aggregate") if isinstance(invariance_summary.get("aggregate"), dict) else {}

    return {
        "pairwise_n": as_float(cal.get("pairwise_n_median"), 0.0),
        "pairwise_agreement": as_float(cal.get("pairwise_agreement_median"), 0.0),
        "pairwise_ci95_lower": as_float(cal.get("pairwise_agreement_ci95_lower_median"), 0.0),
        "critical_defect_recall": as_float(cal.get("critical_defect_recall_median"), 0.0),
        "krippendorff_alpha": as_float(
            cal.get("krippendorff_alpha_median", calibration_summary.get("krippendorff_alpha", 0.0)),
            0.0,
        ),
        "invalid_json_rate": as_float(cal.get("invalid_json_rate_median"), 1.0),
        "runtime_error_rate": as_float(cal.get("runtime_error_rate_median"), 1.0),
        "timeout_rate": as_float(cal.get("timeout_rate_median"), 1.0),
        "order_swap_flip_rate": as_float(inv.get("order_swap_flip_rate_median"), 1.0),
        "repeat_agreement": as_float(inv.get("repeat_agreement_median"), 0.0),
        "attack_success_rate": as_float(inv.get("attack_success_rate_median"), 1.0),
        "reruns_min_observed": float(min(int(calibration_summary.get("reruns", 0) or 0), int(invariance_summary.get("reruns", 0) or 0))),
    }


def compute_armo_metrics(armo_summary: dict[str, Any]) -> dict[str, float]:
    metrics = armo_summary.get("metrics") if isinstance(armo_summary.get("metrics"), dict) else {}
    family_counts = metrics.get("family_non_tie_counts") if isinstance(metrics.get("family_non_tie_counts"), dict) else {}
    candidate_delta_raw = metrics.get("candidate_delta_vs_baseline")
    candidate_delta_present = isinstance(candidate_delta_raw, (int, float))

    return {
        "meta_rho": as_float(armo_summary.get("rho_spearman"), 0.0),
        "meta_rho_ci95_lower": as_float((armo_summary.get("rho_ci95") or [0.0, 0.0])[0] if isinstance(armo_summary.get("rho_ci95"), list) else 0.0, 0.0),
        "total_tasks": as_float(metrics.get("total_tasks"), 0.0),
        "min_family_tasks": min((as_float(v, 0.0) for v in family_counts.values()), default=0.0),
        "exploration_share": as_float(metrics.get("exploration_share"), 0.0),
        "candidate_delta": as_float(candidate_delta_raw, 0.0),
        "candidate_delta_present": 1.0 if candidate_delta_present else 0.0,
        "tail_failure_regression": as_float(metrics.get("tail_failure_regression"), 0.0),
        "invalid_json_rate": as_float(metrics.get("invalid_json_rate"), 1.0),
        "runtime_error_rate": as_float(metrics.get("runtime_error_rate"), 1.0),
        "timeout_rate": as_float(metrics.get("timeout_rate"), 1.0),
        "replication_runs": as_float(armo_summary.get("reruns", armo_summary.get("replication_runs", 0.0)), 0.0),
    }


def validate_armj_summary_artifact(
    summary_path: pathlib.Path,
    *,
    datasets_root: pathlib.Path,
) -> tuple[bool, dict[str, Any], dict[str, Any]]:
    summary = load_json(summary_path)
    required_top = ("aggregate", "per_run", "reruns")
    missing_top = [key for key in required_top if key not in summary]
    expected_dataset_dir = (datasets_root / "judge_quality").resolve()
    dataset_dir_raw = str(summary.get("dataset_dir") or "")
    dataset_dir = pathlib.Path(dataset_dir_raw).resolve() if dataset_dir_raw else None
    dataset_dir_matches = dataset_dir is not None and dataset_dir == expected_dataset_dir
    dataset_pair_ids: set[str] = set()
    if expected_dataset_dir.exists():
        for row in iter_jsonl(expected_dataset_dir / "pairwise_labels.jsonl"):
            dataset_pair_ids.add(str(row.get("id") or ""))
    by_case_path = summary_path.parent / "by_case.jsonl"
    by_case_exists = by_case_path.exists()
    by_case_count = 0
    by_case_ids: set[str] = set()
    if by_case_exists:
        for row in iter_jsonl(by_case_path):
            by_case_count += 1
            by_case_ids.add(str(row.get("id") or ""))
    has_rows = by_case_count > 0
    per_run = summary.get("per_run")
    reruns = int(summary.get("reruns", 0) or 0)
    per_run_len = len(per_run) if isinstance(per_run, list) else 0
    by_case_bound_to_dataset = bool(by_case_ids) and by_case_ids.issubset(dataset_pair_ids)
    summary_fp = summary.get("dataset_fingerprint") if isinstance(summary.get("dataset_fingerprint"), dict) else {}
    expected_jq = (datasets_root / "judge_quality").resolve()
    expected_manifest_path = expected_jq / "split_manifest.v1.json"
    expected_pair_path = expected_jq / "pairwise_labels.jsonl"
    expected_manifest_payload_sha = ""
    if expected_manifest_path.exists():
        manifest = load_json(expected_manifest_path)
        detached = (
            manifest.get("integrity", {}).get("detached_manifest_signature")
            if isinstance(manifest.get("integrity"), dict)
            else {}
        )
        expected_manifest_payload_sha = str(detached.get("payload_sha256") or "")
    expected_pair_rows_sha = ""
    if expected_pair_path.exists():
        expected_pair_rows_sha = stable_hash_object(
            sorted(
                (row for row in iter_jsonl(expected_pair_path)),
                key=lambda row: str(row.get("id", "")),
            )
        )
    summary_fp_matches = (
        str(summary_fp.get("dataset_dir") or "") == str(expected_jq)
        and str(summary_fp.get("manifest_payload_sha256") or "") == expected_manifest_payload_sha
        and str(summary_fp.get("pairwise_rows_sha256") or "") == expected_pair_rows_sha
    )
    checks = {
        "summary_required_fields": len(missing_top) == 0,
        "summary_dataset_dir_matches": dataset_dir_matches,
        "summary_per_run_nonempty": isinstance(per_run, list) and per_run_len > 0,
        "summary_reruns_matches_per_run": reruns > 0 and reruns == per_run_len,
        "by_case_exists": by_case_exists,
        "by_case_nonempty": has_rows,
        "by_case_ids_bound_to_dataset": by_case_bound_to_dataset,
        "summary_dataset_fingerprint_matches": summary_fp_matches,
    }
    detail = {
        "missing_top_fields": missing_top,
        "expected_dataset_dir": str(expected_dataset_dir),
        "summary_dataset_dir": str(dataset_dir) if dataset_dir is not None else "",
        "by_case_path": str(by_case_path),
        "by_case_id_count": len(by_case_ids),
        "dataset_pair_id_count": len(dataset_pair_ids),
        "expected_manifest_payload_sha256": expected_manifest_payload_sha,
        "expected_pairwise_rows_sha256": expected_pair_rows_sha,
        "per_run_len": per_run_len,
        "reruns": reruns,
    }
    return all(checks.values()), summary, {"checks": checks, "detail": detail}


def validate_armo_summary_artifact(
    summary_path: pathlib.Path,
    *,
    datasets_root: pathlib.Path,
) -> tuple[bool, dict[str, Any], dict[str, Any]]:
    summary = load_json(summary_path)
    metrics = summary.get("metrics")
    phase_summaries = summary.get("phase_summaries")
    phase_paths_exist = True
    checked_phase_paths: list[str] = []
    if isinstance(phase_summaries, list):
        for raw in phase_summaries:
            path = pathlib.Path(str(raw))
            if not path.is_absolute():
                path = (summary_path.parent / path).resolve()
            checked_phase_paths.append(str(path))
            if not path.exists():
                phase_paths_exist = False
    judge_summary_ref = summary.get("judge_summary_path")
    outcome_summary_ref = summary.get("outcome_summary_path")
    linked_refs_exist = True
    judge_fingerprint_matches = True
    expected_jq = (datasets_root / "judge_quality").resolve()
    expected_manifest_payload_sha = ""
    expected_pairwise_rows_sha = ""
    expected_manifest_path = expected_jq / "split_manifest.v1.json"
    expected_pair_path = expected_jq / "pairwise_labels.jsonl"
    if expected_manifest_path.exists():
        manifest = load_json(expected_manifest_path)
        detached = (
            manifest.get("integrity", {}).get("detached_manifest_signature")
            if isinstance(manifest.get("integrity"), dict)
            else {}
        )
        expected_manifest_payload_sha = str(detached.get("payload_sha256") or "")
    if expected_pair_path.exists():
        expected_pairwise_rows_sha = stable_hash_object(
            sorted(
                (row for row in iter_jsonl(expected_pair_path)),
                key=lambda row: str(row.get("id", "")),
            )
        )
    for ref in (judge_summary_ref, outcome_summary_ref):
        if not ref:
            continue
        ref_path = pathlib.Path(str(ref))
        if not ref_path.is_absolute():
            ref_path = (summary_path.parent / ref_path).resolve()
        if not ref_path.exists():
            linked_refs_exist = False
    if judge_summary_ref:
        ref_path = pathlib.Path(str(judge_summary_ref))
        if not ref_path.is_absolute():
            ref_path = (summary_path.parent / ref_path).resolve()
        if ref_path.exists():
            judge_summary = load_json(ref_path)
            fp = judge_summary.get("dataset_fingerprint") if isinstance(judge_summary.get("dataset_fingerprint"), dict) else {}
            judge_fingerprint_matches = (
                str(fp.get("dataset_dir") or "") == str(expected_jq)
                and str(fp.get("manifest_payload_sha256") or "") == expected_manifest_payload_sha
                and str(fp.get("pairwise_rows_sha256") or "") == expected_pairwise_rows_sha
            )
        else:
            judge_fingerprint_matches = False
    checks = {
        "summary_has_metrics": isinstance(metrics, dict),
        "summary_has_rho_fields": ("rho_spearman" in summary) and ("rho_ci95" in summary),
        "summary_has_shared_variants": isinstance(summary.get("shared_variants"), list),
        "phase_summary_paths_exist": phase_paths_exist,
        "linked_summary_refs_exist": linked_refs_exist,
        "linked_judge_fingerprint_matches": judge_fingerprint_matches,
    }
    detail = {
        "phase_summary_paths_checked": checked_phase_paths,
        "phase_summary_count": len(phase_summaries) if isinstance(phase_summaries, list) else 0,
    }
    return all(checks.values()), summary, {"checks": checks, "detail": detail}


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Assess judge lock readiness against frozen lock criteria")
    ap.add_argument("--datasets-root", default=str(DEFAULT_DATASETS_ROOT))
    ap.add_argument("--gate-manifest", default=str(DEFAULT_GATE_MANIFEST))
    ap.add_argument("--armj-calibration-summary", default="")
    ap.add_argument("--armj-invariance-summary", default="")
    ap.add_argument("--armo-summary", default="")
    ap.add_argument("--aa-ci-halfwidth", type=float, default=0.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--fail-on-no-lock", action="store_true")

    # Frozen lock-spec defaults (docs/PROMPT_EVAL_JUDGE_LOCK_SPEC_2026-03-06.md)
    ap.add_argument("--pairwise-labels-min", type=int, default=500)
    ap.add_argument("--sealed-labels-min", type=int, default=200)
    ap.add_argument("--family-count-min", type=int, default=5)
    ap.add_argument("--family-items-min", type=int, default=40)
    ap.add_argument("--language-count-min", type=int, default=2)
    ap.add_argument("--language-items-min", type=int, default=80)
    ap.add_argument("--max-family-share", type=float, default=0.40)
    ap.add_argument("--sealed-label-source-class-required", default="human_adjudicated")
    ap.add_argument("--pairwise-agreement-min", type=float, default=0.78)
    ap.add_argument("--pairwise-ci95-lower-min", type=float, default=0.55)
    ap.add_argument("--critical-defect-recall-min", type=float, default=0.90)
    ap.add_argument("--krippendorff-alpha-min", type=float, default=0.55)
    ap.add_argument("--mirror-symmetry-error-max", type=float, default=0.10)
    ap.add_argument("--repeatability-error-max", type=float, default=0.12)
    ap.add_argument("--invariance-fail-rate-max", type=float, default=0.08)
    ap.add_argument("--invalid-json-rate-max", type=float, default=0.005)
    ap.add_argument("--runtime-error-rate-max", type=float, default=0.01)
    ap.add_argument("--timeout-rate-max", type=float, default=0.01)
    ap.add_argument("--replication-seeds-min", type=int, default=2)
    ap.add_argument("--armo-candidate-delta-min", type=float, default=0.03)
    ap.add_argument("--armo-tail-regression-max", type=float, default=0.01)
    ap.add_argument("--armo-total-tasks-min", type=int, default=200)
    ap.add_argument("--armo-per-family-tasks-min", type=int, default=20)
    ap.add_argument("--armo-meta-rho-min", type=float, default=0.50)
    ap.add_argument("--armo-meta-rho-ci95-lower-min", type=float, default=0.30)
    return ap.parse_args()


def main() -> int:
    args = parse_args()

    datasets_root = pathlib.Path(args.datasets_root).resolve()
    gate_manifest = load_json(pathlib.Path(args.gate_manifest).resolve())
    required_families = [
        str(family)
        for family in (gate_manifest.get("required_preset_families") or [])
        if isinstance(family, str) and family.strip()
    ]
    dataset_metrics = compute_dataset_metrics(
        datasets_root,
        required_families=required_families,
        sealed_label_source_class_required=str(args.sealed_label_source_class_required),
    )
    dataset_integrity = run_dataset_integrity_check(datasets_root)

    dataset_checks: dict[str, bool] = {
        "gate_manifest_required_families_configured": len(required_families) > 0,
        "dataset_integrity_ok": bool(dataset_integrity["ok"]),
        "dataset_pairwise_labels_floor": dataset_metrics["pairwise_labels_total"] >= int(args.pairwise_labels_min),
        "dataset_sealed_labels_floor": dataset_metrics["pairwise_labels_sealed"] >= int(args.sealed_labels_min),
        "dataset_family_count_floor": dataset_metrics["family_count"] >= int(args.family_count_min),
        "dataset_family_items_floor": all(v >= int(args.family_items_min) for v in dataset_metrics["pairwise_by_family"].values()),
        "dataset_language_count_floor": dataset_metrics["language_count"] >= int(args.language_count_min),
        "dataset_language_items_floor": all(v >= int(args.language_items_min) for v in dataset_metrics["pairwise_by_language"].values()),
        "dataset_max_family_share": as_float(dataset_metrics["max_family_share"], 1.0) <= float(args.max_family_share),
        "dataset_required_families_present": len(dataset_metrics["missing_required_families"]) == 0,
        "dataset_no_unexpected_families": len(dataset_metrics["unexpected_families"]) == 0,
        "dataset_pairwise_linkage_complete": int(dataset_metrics["pairwise_linked_rows"]) == int(
            dataset_metrics["pairwise_labels_total"]
        ),
        "dataset_sealed_provenance_clean": len(dataset_metrics["sealed_provenance_violations"]) == 0,
        "dataset_split_lineage_clean": int(dataset_metrics["lineage_collision_count"]) == 0,
    }

    armj_present = bool(args.armj_calibration_summary and args.armj_invariance_summary)
    armj_metrics: dict[str, float] = {}
    armj_checks: dict[str, bool] = {}
    armj_artifact: dict[str, Any] = {}
    if armj_present:
        armj_cal_ok, armj_cal, cal_meta = validate_armj_summary_artifact(
            pathlib.Path(args.armj_calibration_summary).resolve(),
            datasets_root=datasets_root,
        )
        armj_inv_ok, armj_inv, inv_meta = validate_armj_summary_artifact(
            pathlib.Path(args.armj_invariance_summary).resolve(),
            datasets_root=datasets_root,
        )
        armj_artifact = {
            "calibration": {"ok": armj_cal_ok, **cal_meta},
            "invariance": {"ok": armj_inv_ok, **inv_meta},
        }
        armj_metrics = compute_armj_metrics(armj_cal, armj_inv)
        armj_checks = {
            "armj_calibration_artifact_integrity": armj_cal_ok,
            "armj_invariance_artifact_integrity": armj_inv_ok,
            "armj_pairwise_agreement": armj_metrics["pairwise_agreement"] >= float(args.pairwise_agreement_min),
            "armj_pairwise_ci95_lower": armj_metrics["pairwise_ci95_lower"] >= float(args.pairwise_ci95_lower_min),
            "armj_critical_defect_recall": armj_metrics["critical_defect_recall"] >= float(args.critical_defect_recall_min),
            "armj_krippendorff_alpha": armj_metrics["krippendorff_alpha"] >= float(args.krippendorff_alpha_min),
            "armj_mirror_symmetry_error": armj_metrics["order_swap_flip_rate"] <= float(args.mirror_symmetry_error_max),
            "armj_repeatability_error": (1.0 - armj_metrics["repeat_agreement"]) <= float(args.repeatability_error_max),
            "armj_invariance_fail_rate": armj_metrics["attack_success_rate"] <= float(args.invariance_fail_rate_max),
            "armj_invalid_json_rate": armj_metrics["invalid_json_rate"] <= float(args.invalid_json_rate_max),
            "armj_runtime_error_rate": armj_metrics["runtime_error_rate"] <= float(args.runtime_error_rate_max),
            "armj_timeout_rate": armj_metrics["timeout_rate"] <= float(args.timeout_rate_max),
            "armj_replication_seed_floor": armj_metrics["reruns_min_observed"] >= float(args.replication_seeds_min),
        }

    armo_present = bool(args.armo_summary)
    armo_metrics: dict[str, float] = {}
    armo_checks: dict[str, bool] = {}
    armo_artifact: dict[str, Any] = {}
    if armo_present:
        armo_ok, armo_summary, armo_meta = validate_armo_summary_artifact(
            pathlib.Path(args.armo_summary).resolve(),
            datasets_root=datasets_root,
        )
        armo_artifact = {"ok": armo_ok, **armo_meta}
        armo_metrics = compute_armo_metrics(armo_summary)

        armo_checks = {
            "armo_artifact_integrity": armo_ok,
            "armo_candidate_delta_present": armo_metrics["candidate_delta_present"] >= 1.0,
            "armo_candidate_delta": armo_metrics["candidate_delta"] >= float(args.armo_candidate_delta_min),
            "armo_tail_failure_regression": armo_metrics["tail_failure_regression"] <= float(args.armo_tail_regression_max),
            "armo_total_tasks_floor": armo_metrics["total_tasks"] >= float(args.armo_total_tasks_min),
            "armo_per_family_floor": armo_metrics["min_family_tasks"] >= float(args.armo_per_family_tasks_min),
            "armo_meta_rho": armo_metrics["meta_rho"] >= float(args.armo_meta_rho_min),
            "armo_meta_rho_ci95_lower": armo_metrics["meta_rho_ci95_lower"] >= float(args.armo_meta_rho_ci95_lower_min),
            "armo_invalid_json_rate": armo_metrics["invalid_json_rate"] <= float(args.invalid_json_rate_max),
            "armo_runtime_error_rate": armo_metrics["runtime_error_rate"] <= float(args.runtime_error_rate_max),
            "armo_timeout_rate": armo_metrics["timeout_rate"] <= float(args.timeout_rate_max),
            "armo_replication_seed_floor": armo_metrics["replication_runs"] >= float(args.replication_seeds_min),
        }

    noise_floor_required = max(0.02, 1.5 * float(args.aa_ci_halfwidth))
    noise_floor_pass = armo_present and as_float(armo_metrics.get("candidate_delta"), 0.0) > noise_floor_required

    dataset_ok = all(dataset_checks.values())
    armj_ok = armj_present and all(armj_checks.values())
    armo_ok = armo_present and all(armo_checks.values()) and noise_floor_pass

    if dataset_ok and armj_ok and armo_ok:
        decision = "LOCK"
    elif dataset_ok and armj_ok:
        decision = "J_LOCK_ONLY"
    else:
        decision = "NO_LOCK"

    checks = {
        **dataset_checks,
        "armj_artifacts_present": armj_present,
        **armj_checks,
        "armo_artifact_present": armo_present,
        **armo_checks,
        "noise_floor": noise_floor_pass,
    }

    reason_codes = [f"CHECK_FAILED:{name}" for name, ok in checks.items() if not ok]

    out = {
        "ok": decision == "LOCK",
        "decision": decision,
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "inputs": {
            "datasets_root": str(datasets_root),
            "gate_manifest": str(pathlib.Path(args.gate_manifest).resolve()),
            "armj_calibration_summary": str(pathlib.Path(args.armj_calibration_summary).resolve()) if args.armj_calibration_summary else "",
            "armj_invariance_summary": str(pathlib.Path(args.armj_invariance_summary).resolve()) if args.armj_invariance_summary else "",
            "armo_summary": str(pathlib.Path(args.armo_summary).resolve()) if args.armo_summary else "",
            "aa_ci_halfwidth": float(args.aa_ci_halfwidth),
        },
        "frozen_thresholds": {
            "pairwise_labels_min": int(args.pairwise_labels_min),
            "sealed_labels_min": int(args.sealed_labels_min),
            "family_count_min": int(args.family_count_min),
            "family_items_min": int(args.family_items_min),
            "language_count_min": int(args.language_count_min),
            "language_items_min": int(args.language_items_min),
            "max_family_share": float(args.max_family_share),
            "sealed_label_source_class_required": str(args.sealed_label_source_class_required),
            "pairwise_agreement_min": float(args.pairwise_agreement_min),
            "pairwise_ci95_lower_min": float(args.pairwise_ci95_lower_min),
            "critical_defect_recall_min": float(args.critical_defect_recall_min),
            "krippendorff_alpha_min": float(args.krippendorff_alpha_min),
            "mirror_symmetry_error_max": float(args.mirror_symmetry_error_max),
            "repeatability_error_max": float(args.repeatability_error_max),
            "invariance_fail_rate_max": float(args.invariance_fail_rate_max),
            "invalid_json_rate_max": float(args.invalid_json_rate_max),
            "runtime_error_rate_max": float(args.runtime_error_rate_max),
            "timeout_rate_max": float(args.timeout_rate_max),
            "replication_seeds_min": int(args.replication_seeds_min),
            "armo_candidate_delta_min": float(args.armo_candidate_delta_min),
            "armo_tail_regression_max": float(args.armo_tail_regression_max),
            "armo_total_tasks_min": int(args.armo_total_tasks_min),
            "armo_per_family_tasks_min": int(args.armo_per_family_tasks_min),
            "armo_meta_rho_min": float(args.armo_meta_rho_min),
            "armo_meta_rho_ci95_lower_min": float(args.armo_meta_rho_ci95_lower_min),
        },
        "noise_floor_required": noise_floor_required,
        "metrics": {
            "dataset": dataset_metrics,
            "dataset_integrity": dataset_integrity,
            "armj": armj_metrics,
            "armj_artifacts": armj_artifact,
            "armo": armo_metrics,
            "armo_artifact": armo_artifact,
            "gate_manifest_version": gate_manifest.get("version"),
        },
        "checks": checks,
        "reason_codes": reason_codes,
    }

    out_path = pathlib.Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(out, indent=2, ensure_ascii=False))

    if args.fail_on_no_lock and decision != "LOCK":
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
