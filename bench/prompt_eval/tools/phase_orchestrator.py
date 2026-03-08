#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import subprocess
import time
from typing import Any

from provider_contract import (
    DEFAULT_PROVIDER_CONTRACT,
    ProviderContractError,
    load_provider_contract,
)

PHASES = [
    "phase0_bootstrap",
    "phaseA_policy_freeze",
    "phaseB_judge_reliability",
    "phaseC_candidate_generation",
    "phaseD_dev",
    "phaseE_adversarial",
    "phaseF_holdout",
    "phaseG_promotion",
]
DEFAULT_JUDGE_PROMPT = "bench/prompt_eval/prompts/judge_pairwise_v2.md"


def run_cmd(cmd: list[str], cwd: pathlib.Path, phase_dir: pathlib.Path, name: str, timeout_s: int = 600) -> dict[str, Any]:
    start = time.time()
    try:
        proc = subprocess.run(cmd, cwd=str(cwd), text=True, capture_output=True, timeout=timeout_s)
        stdout = proc.stdout or ""
        stderr = proc.stderr or ""
        returncode = proc.returncode
    except subprocess.TimeoutExpired as exc:
        stdout = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
        stderr = (exc.stderr or "") if isinstance(exc.stderr, str) else ""
        stderr += f"\n[timeout] command exceeded {timeout_s}s\n"
        returncode = 124
    elapsed = time.time() - start
    (phase_dir / f"{name}.stdout.log").write_text(stdout, encoding="utf-8")
    (phase_dir / f"{name}.stderr.log").write_text(stderr, encoding="utf-8")
    return {
        "name": name,
        "cmd": cmd,
        "returncode": returncode,
        "elapsed_seconds": round(elapsed, 3),
    }


def collect_nonzero_returncodes(obj: Any, prefix: str = "") -> list[str]:
    issues: list[str] = []
    if isinstance(obj, dict):
        if "returncode" in obj:
            try:
                rc = int(obj["returncode"])
            except Exception:
                rc = 1
            if rc != 0:
                label = obj.get("name") or prefix or "command"
                issues.append(f"{label}: rc={rc}")
        for k, v in obj.items():
            child_prefix = f"{prefix}.{k}" if prefix else k
            issues.extend(collect_nonzero_returncodes(v, child_prefix))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            child_prefix = f"{prefix}[{i}]"
            issues.extend(collect_nonzero_returncodes(v, child_prefix))
    return issues


def maybe_promptfoo_eval(repo: pathlib.Path, phase_dir: pathlib.Path, config: str, split: str, simulate_no_provider: bool) -> dict[str, Any]:
    if simulate_no_provider:
        simulated = {
            "ok": True,
            "simulated": True,
            "reason": "simulate_no_provider flag enabled",
            "split": split,
        }
        (phase_dir / "promptfoo_simulated.json").write_text(json.dumps(simulated, indent=2) + "\n", encoding="utf-8")
        return {"name": "promptfoo_eval", "returncode": 0, "elapsed_seconds": 0.0, "simulated": True}

    out_json = phase_dir / "promptfoo_results.json"
    cmd = [
        "npx",
        "--yes",
        "promptfoo@0.120.25",
        "eval",
        "-c",
        config,
        "--no-progress-bar",
        "--max-concurrency",
        "4",
        "--output",
        str(out_json),
    ]
    result = run_cmd(cmd, repo, phase_dir, "promptfoo_eval")
    if int(result.get("returncode", 0)) == 100:
        stats = extract_promptfoo_result_stats(out_json)
        # Promptfoo uses rc=100 for assertion failures. Treat this as a soft
        # evaluation failure (not an infra failure) only when we can verify
        # result artifacts exist and there are no provider/runtime errors.
        if stats and int(stats.get("errors", 0)) == 0 and int(stats.get("failures", 0)) > 0:
            result["raw_returncode"] = 100
            result["returncode"] = 0
            result["assertion_failures"] = True
            result["result_stats"] = stats
    return result


def ensure_promptfoo_phase_ok(result: dict[str, Any], phase_name: str) -> None:
    if int(result.get("returncode", 0)) != 0:
        raise RuntimeError(f"{phase_name} promptfoo failed: rc={result.get('returncode')}")
    if bool(result.get("assertion_failures")):
        raise RuntimeError(f"{phase_name} promptfoo assertions failed")


def ensure_files_exist(paths: list[pathlib.Path]) -> list[str]:
    errs = []
    for p in paths:
        if not p.exists():
            errs.append(f"missing file: {p}")
    return errs


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def compute_hash_map(paths: list[pathlib.Path]) -> dict[str, str | None]:
    out: dict[str, str | None] = {}
    for path in paths:
        rp = path.resolve()
        out[str(rp)] = sha256_file(rp) if rp.exists() else None
    return out


def extract_usage_totals_from_summary(summary_path: pathlib.Path) -> dict[str, float]:
    if not summary_path.exists():
        return {}
    try:
        data = json.loads(summary_path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    usage = data.get("usage_totals")
    if not isinstance(usage, dict):
        return {}
    out: dict[str, float] = {}
    for key in ("total_tokens", "input_tokens", "output_tokens", "reasoning_tokens", "cost_usd"):
        val = usage.get(key)
        if isinstance(val, (int, float)):
            out[key] = float(val)
    if "total_tokens" not in out:
        input_tokens = out.get("input_tokens", 0.0)
        output_tokens = out.get("output_tokens", 0.0)
        if input_tokens or output_tokens:
            out["total_tokens"] = input_tokens + output_tokens
    return out


def extract_eval_identity(summary_path: pathlib.Path) -> dict[str, str]:
    if not summary_path.exists():
        return {}
    try:
        data = json.loads(summary_path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    out: dict[str, str] = {}
    for key in ("judge_prompt", "judge_model", "draft_model"):
        val = data.get(key)
        if isinstance(val, str) and val.strip():
            out[key] = val
    return out


def extract_usage_totals_from_promptfoo_results(results_path: pathlib.Path) -> dict[str, float]:
    if not results_path.exists():
        return {}
    try:
        data = json.loads(results_path.read_text(encoding="utf-8"))
    except Exception:
        return {}

    stats = {}
    if isinstance(data.get("results"), dict):
        stats = (data["results"].get("stats") or {}) if isinstance(data["results"], dict) else {}
    token_usage = stats.get("tokenUsage") if isinstance(stats, dict) else None

    out: dict[str, float] = {}
    if isinstance(token_usage, dict):
        prompt_tokens = token_usage.get("prompt")
        completion_tokens = token_usage.get("completion")
        total_tokens = token_usage.get("total")
        completion_details = token_usage.get("completionDetails")
        reasoning_tokens = (
            completion_details.get("reasoning")
            if isinstance(completion_details, dict)
            else None
        )
        if isinstance(prompt_tokens, (int, float)):
            out["input_tokens"] = float(prompt_tokens)
        if isinstance(completion_tokens, (int, float)):
            out["output_tokens"] = float(completion_tokens)
        if isinstance(total_tokens, (int, float)):
            out["total_tokens"] = float(total_tokens)
        if isinstance(reasoning_tokens, (int, float)):
            out["reasoning_tokens"] = float(reasoning_tokens)

    if "total_tokens" not in out:
        input_tokens = out.get("input_tokens", 0.0)
        output_tokens = out.get("output_tokens", 0.0)
        if input_tokens or output_tokens:
            out["total_tokens"] = input_tokens + output_tokens

    if isinstance(stats, dict):
        stats_cost = stats.get("cost")
        if isinstance(stats_cost, (int, float)):
            out["cost_usd"] = float(stats_cost)
            return out

    cost = 0.0
    found_cost = False
    results_list = ((data.get("results") or {}).get("results") or []) if isinstance(data.get("results"), dict) else []
    if isinstance(results_list, list):
        for row in results_list:
            if not isinstance(row, dict):
                continue
            row_cost = row.get("cost")
            if isinstance(row_cost, (int, float)):
                cost += float(row_cost)
                found_cost = True

    if found_cost:
        out["cost_usd"] = cost

    return out


def extract_promptfoo_result_stats(results_path: pathlib.Path) -> dict[str, int]:
    if not results_path.exists():
        return {}
    try:
        data = json.loads(results_path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    results = data.get("results")
    if not isinstance(results, dict):
        return {}
    stats = results.get("stats")
    if not isinstance(stats, dict):
        return {}
    out: dict[str, int] = {}
    for key in ("successes", "failures", "errors"):
        value = stats.get(key)
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            out[key] = int(value)
        elif isinstance(value, float):
            out[key] = int(value)
    return out


def add_usage_to_cycle(
    cycle_usage: dict[str, float],
    usage_meta: dict[str, int],
    usage: dict[str, float],
) -> None:
    total_tokens = float(usage.get("total_tokens", 0.0))
    cost_usd = usage.get("cost_usd")
    cycle_usage["total_tokens"] += total_tokens
    if isinstance(cost_usd, (int, float)):
        cycle_usage["cost_usd"] += float(cost_usd)
        usage_meta["cost_observed_count"] += 1
    elif total_tokens > 0:
        usage_meta["missing_cost_count"] += 1


def build_manifest(
    repo: pathlib.Path,
    cycle_id: str,
    phase: str,
    split: str,
    phase_dir: pathlib.Path,
    config_paths: list[pathlib.Path],
    dataset_paths: list[pathlib.Path],
    reason_codes: list[str],
    judge_prompt: str | pathlib.Path | None = None,
    judge_model: str | None = None,
    draft_model: str | None = None,
    timeout_s: int = 120,
) -> None:
    cmd = [
        "python3",
        "bench/prompt_eval/tools/build_run_manifest.py",
        "--phase", phase,
        "--cycle-id", cycle_id,
        "--dataset-split", split,
        "--out", str(phase_dir / "run_manifest.json"),
    ]
    for p in config_paths:
        cmd.extend(["--config-path", str(p)])
    for p in dataset_paths:
        cmd.extend(["--dataset-path", str(p)])
    for r in reason_codes:
        cmd.extend(["--reason-code", r])
    if judge_prompt:
        cmd.extend(["--judge-prompt", str(judge_prompt)])
    if judge_model:
        cmd.extend(["--judge-model", str(judge_model)])
    if draft_model:
        cmd.extend(["--draft-model", str(draft_model)])
    proc = subprocess.run(cmd, cwd=str(repo), text=True, capture_output=True, timeout=timeout_s)
    (phase_dir / "build_run_manifest.stdout.log").write_text(proc.stdout or "", encoding="utf-8")
    (phase_dir / "build_run_manifest.stderr.log").write_text(proc.stderr or "", encoding="utf-8")
    if proc.returncode != 0:
        raise RuntimeError(f"build_run_manifest failed: rc={proc.returncode}")
    val = subprocess.run(
        [
            "python3",
            "bench/prompt_eval/tools/validate_run_manifest.py",
            "--manifest", str(phase_dir / "run_manifest.json"),
            "--schema", "bench/prompt_eval/config/run_manifest.schema.json",
        ],
        cwd=str(repo),
        text=True,
        capture_output=True,
        timeout=timeout_s,
    )
    (phase_dir / "validate_run_manifest.stdout.log").write_text(val.stdout or "", encoding="utf-8")
    (phase_dir / "validate_run_manifest.stderr.log").write_text(val.stderr or "", encoding="utf-8")
    if val.returncode != 0:
        raise RuntimeError(f"validate_run_manifest failed: rc={val.returncode}")


def phase_phase0(repo: pathlib.Path, phase_dir: pathlib.Path) -> dict[str, Any]:
    checks = []
    checks.append(run_cmd(["python3", "bench/prompt_eval/tools/validate_gate_manifest.py"], repo, phase_dir, "validate_gate_manifest"))
    checks.append(run_cmd(["python3", "bench/prompt_eval/tools/validate_holistic_sources.py"], repo, phase_dir, "validate_holistic_sources"))
    checks.append(run_cmd(["python3", "bench/prompt_eval/tools/check_dataset_integrity.py"], repo, phase_dir, "check_dataset_integrity"))
    checks.append(run_cmd([
        "npx", "--yes", "promptfoo@0.120.25", "validate", "config",
        "-c", "bench/prompt_eval/config/base.promptfoo.yaml",
        "-c", "bench/prompt_eval/config/dev.promptfoo.yaml",
        "-c", "bench/prompt_eval/config/adversarial.promptfoo.yaml",
        "-c", "bench/prompt_eval/config/holdout.promptfoo.yaml",
    ], repo, phase_dir, "validate_promptfoo_configs"))
    return {"checks": checks}


def phase_phaseA(repo: pathlib.Path, phase_dir: pathlib.Path) -> dict[str, Any]:
    gate_manifest_path = repo / "bench/prompt_eval/config/gate_manifest.v1.json"
    gate_manifest = json.loads(gate_manifest_path.read_text(encoding="utf-8"))
    source_doc_rel = (
        (gate_manifest.get("source_policy") or {}).get("research_artifact_path")
        or "docs/PROMPT_EVAL_HOLISTIC_RESEARCH_2026-03-01.md"
    )
    files = [
        repo / "bench/prompt_architecture/v1/preset_registry.json",
        repo / "bench/prompt_architecture/v1/selection_policy.json",
        gate_manifest_path,
        repo / "docs/PROMPT_EVAL_AUTONOMOUS_MASTER_PLAN_2026-02-28.md",
        (repo / source_doc_rel).resolve(),
    ]
    errors = ensure_files_exist(files)
    result = {"errors": errors, "file_count": len(files)}
    (phase_dir / "policy_freeze_check.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def phase_phaseB(
    repo: pathlib.Path,
    phase_dir: pathlib.Path,
    provider_contract: dict[str, Any],
    max_cases: int,
    timeout: int,
    judge_repeats: int,
    simulate_no_provider: bool,
    use_cache: bool = True,
) -> dict[str, Any]:
    phase_timeout_s = max(600, int(timeout) * 4)
    providers = provider_contract["providers"]
    primary_provider = providers["judge_primary"]
    shadow_provider = providers["judge_shadow"]
    preferred_judge_prompt_path = (repo / DEFAULT_JUDGE_PROMPT).resolve()
    calibrate_script_path = (repo / "bench/prompt_eval/calibrate_judge.py").resolve()
    symmetry_script_path = (repo / "bench/prompt_eval/assess_judge_symmetry.py").resolve()
    dataset_path = repo / "bench/prompt_eval/datasets/calibration/judge_pairs.jsonl"
    judge_prompt_paths = [
        repo / "bench/prompt_eval/prompts/judge_pairwise_v1.md",
        repo / "bench/prompt_eval/prompts/judge_pairwise_v2.md",
        repo / "bench/prompt_eval/prompts/judge_pairwise_v3.md",
    ]
    calibration_payload = {
        "dataset_sha256": sha256_file(dataset_path),
        "judge_prompt_sha256": {str(p): sha256_file(p) for p in judge_prompt_paths},
        "model": primary_provider["model"],
        "reasoning_effort": primary_provider["reasoning_effort"],
        "max_pairs": int(max_cases) if max_cases > 0 else 0,
        "preferred_judge_prompt": str(preferred_judge_prompt_path),
        "calibration_script_sha256": sha256_file(calibrate_script_path),
    }
    calibration_key = hashlib.sha256(json.dumps(calibration_payload, sort_keys=True).encode("utf-8")).hexdigest()[:16]

    calibration_cache_dir = repo / "bench/prompt_eval/reports/cache/judge_reliability/calibration" / calibration_key
    cache_cal = calibration_cache_dir / "judge_calibration_summary.json"

    cal_out = phase_dir / "judge_calibration"
    sym_out = phase_dir / "judge_symmetry"
    cal_out.mkdir(parents=True, exist_ok=True)
    sym_out.mkdir(parents=True, exist_ok=True)

    if simulate_no_provider:
        fixture_cal = repo / "bench/prompt_eval/fixtures/judge_calibration_summary.simulated.json"
        fixture_sym = repo / "bench/prompt_eval/fixtures/judge_symmetry_summary.simulated.json"
        fixture_audit = repo / "bench/prompt_eval/fixtures/judge_audit.simulated.json"
        if fixture_cal.exists() and fixture_sym.exists():
            (cal_out / "summary.json").write_text(fixture_cal.read_text(encoding="utf-8"), encoding="utf-8")
            (sym_out / "summary.json").write_text(fixture_sym.read_text(encoding="utf-8"), encoding="utf-8")
            if fixture_audit.exists():
                (phase_dir / "judge_audit.json").write_text(
                    fixture_audit.read_text(encoding="utf-8"),
                    encoding="utf-8",
                )
            return {
                "cache_hit": False,
                "simulated": True,
                "calibration_cache_hit": False,
                "symmetry_cache_hit": False,
                "calibration_key": calibration_key,
                "symmetry_key": "simulated",
                "calibration": {"name": "calibrate_judge", "returncode": 0, "elapsed_seconds": 0.0, "simulated": True},
                "symmetry": {"name": "assess_judge_symmetry", "returncode": 0, "elapsed_seconds": 0.0, "simulated": True},
                "judge_audit": {"name": "generate_judge_audit", "returncode": 0, "elapsed_seconds": 0.0, "simulated": True},
                "calibration_summary": str(cal_out / "summary.json"),
                "symmetry_summary": str(sym_out / "summary.json"),
                "judge_audit_path": str(phase_dir / "judge_audit.json"),
            }

    calibration_cache_hit = False
    symmetry_cache_hit = False
    if use_cache and cache_cal.exists():
        (cal_out / "summary.json").write_text(cache_cal.read_text(encoding="utf-8"), encoding="utf-8")
        calibration_cache_hit = True
    cal = {"name": "calibrate_judge", "returncode": 0, "elapsed_seconds": 0.0, "cache_hit": calibration_cache_hit}
    if not calibration_cache_hit:
        cal_cmd = [
            "python3", "bench/prompt_eval/calibrate_judge.py",
            "--dataset", "bench/prompt_eval/datasets/calibration/judge_pairs.jsonl",
            "--out-dir", str(cal_out),
            "--timeout", str(timeout),
            "--model", primary_provider["model"],
            "--reasoning-effort", primary_provider["reasoning_effort"],
            "--preferred-prompt", str(preferred_judge_prompt_path),
        ]
        if max_cases > 0:
            cal_cmd.extend(["--max-pairs", str(max_cases)])
        cal = run_cmd(cal_cmd, repo, phase_dir, "calibrate_judge", timeout_s=phase_timeout_s)
        cal["cache_hit"] = False

    if cal.get("returncode", 0) != 0:
        return {
            "cache_hit": False,
            "calibration_cache_hit": calibration_cache_hit,
            "symmetry_cache_hit": False,
            "calibration_key": calibration_key,
            "symmetry_key": None,
            "calibration": cal,
            "symmetry": {"name": "assess_judge_symmetry", "returncode": 125, "elapsed_seconds": 0.0, "skipped": True},
            "judge_audit": {"name": "generate_judge_audit", "returncode": 125, "elapsed_seconds": 0.0, "skipped": True},
            "selected_judge_prompt": str(repo / DEFAULT_JUDGE_PROMPT),
            "calibration_summary": str(cal_out / "summary.json"),
        }

    selected_judge_prompt = str(repo / DEFAULT_JUDGE_PROMPT)
    cal_summary_path = cal_out / "summary.json"
    if cal_summary_path.exists():
        try:
            cal_summary = json.loads(cal_summary_path.read_text(encoding="utf-8"))
            selected_judge_prompt = (
                ((cal_summary.get("recommended_prompt") or {}).get("prompt"))
                or selected_judge_prompt
            )
        except Exception:
            selected_judge_prompt = str(repo / DEFAULT_JUDGE_PROMPT)

    symmetry_payload = {
        **calibration_payload,
        "max_cases": max_cases,
        "judge_repeats": judge_repeats,
        "selected_judge_prompt": selected_judge_prompt,
        "selected_judge_prompt_sha256": sha256_file(pathlib.Path(selected_judge_prompt).resolve()),
        "symmetry_script_sha256": sha256_file(symmetry_script_path),
    }
    symmetry_key = hashlib.sha256(json.dumps(symmetry_payload, sort_keys=True).encode("utf-8")).hexdigest()[:16]
    symmetry_cache_dir = repo / "bench/prompt_eval/reports/cache/judge_reliability/symmetry" / symmetry_key
    cache_sym = symmetry_cache_dir / "judge_symmetry_summary.json"
    if use_cache and cache_sym.exists():
        (sym_out / "summary.json").write_text(cache_sym.read_text(encoding="utf-8"), encoding="utf-8")
        symmetry_cache_hit = True

    sym = {"name": "assess_judge_symmetry", "returncode": 0, "elapsed_seconds": 0.0, "cache_hit": symmetry_cache_hit}
    if not symmetry_cache_hit:
        sym_cmd = [
            "python3", "bench/prompt_eval/assess_judge_symmetry.py",
            "--dataset", "bench/prompt_eval/datasets/calibration/judge_pairs.jsonl",
            "--out-dir", str(sym_out),
            "--timeout", str(timeout),
            "--repeats", str(judge_repeats),
            "--judge-prompt", selected_judge_prompt,
            "--model", primary_provider["model"],
            "--reasoning-effort", primary_provider["reasoning_effort"],
        ]
        if max_cases > 0:
            sym_cmd.extend(["--max-cases", str(max_cases)])
        sym = run_cmd(sym_cmd, repo, phase_dir, "assess_judge_symmetry", timeout_s=phase_timeout_s)
        sym["cache_hit"] = False

    if sym.get("returncode", 0) != 0:
        return {
            "cache_hit": False,
            "calibration_cache_hit": calibration_cache_hit,
            "symmetry_cache_hit": symmetry_cache_hit,
            "calibration_key": calibration_key,
            "symmetry_key": symmetry_key,
            "calibration": cal,
            "symmetry": sym,
            "judge_audit": {"name": "generate_judge_audit", "returncode": 125, "elapsed_seconds": 0.0, "skipped": True},
            "selected_judge_prompt": selected_judge_prompt,
            "calibration_summary": str(cal_out / "summary.json"),
            "symmetry_summary": str(sym_out / "summary.json"),
        }

    if cal.get("returncode") == 0:
        src_cal = cal_out / "summary.json"
        if src_cal.exists():
            calibration_cache_dir.mkdir(parents=True, exist_ok=True)
            (calibration_cache_dir / "judge_calibration_summary.json").write_text(
                src_cal.read_text(encoding="utf-8"), encoding="utf-8"
            )
            (calibration_cache_dir / "cache_key_payload.json").write_text(
                json.dumps(calibration_payload, indent=2) + "\n", encoding="utf-8"
            )

    if sym.get("returncode") == 0:
        src_sym = sym_out / "summary.json"
        if src_sym.exists():
            symmetry_cache_dir.mkdir(parents=True, exist_ok=True)
            (symmetry_cache_dir / "judge_symmetry_summary.json").write_text(
                src_sym.read_text(encoding="utf-8"), encoding="utf-8"
            )
            (symmetry_cache_dir / "cache_key_payload.json").write_text(
                json.dumps(symmetry_payload, indent=2) + "\n", encoding="utf-8"
            )

    audit_out = phase_dir / "judge_audit.json"
    audit_cmd = [
        "python3",
        "bench/prompt_eval/tools/generate_judge_audit.py",
        "--gate-manifest", "bench/prompt_eval/config/gate_manifest.v1.json",
        "--calibration-summary", str(cal_out / "summary.json"),
        "--judge-prompt", selected_judge_prompt,
        "--judge-schema", "bench/prompt_eval/schemas/judge_decision.schema.json",
        "--primary-model", primary_provider["model"],
        "--primary-reasoning-effort", primary_provider["reasoning_effort"],
        "--shadow-runner", shadow_provider["runner"],
        "--shadow-model", shadow_provider["model"],
        "--shadow-reasoning-effort", shadow_provider["reasoning_effort"],
        "--triad-dataset", "bench/prompt_eval/datasets/calibration/judge_triads.jsonl",
        "--shadow-dataset", "bench/prompt_eval/datasets/calibration/shadow_spotcheck_pairs.jsonl",
        "--gold-dataset", "bench/prompt_eval/datasets/calibration/gold_anchor_pairs.jsonl",
        "--out", str(audit_out),
    ]
    if max_cases > 0:
        audit_cmd.extend(
            [
                "--max-triads", str(max_cases),
                "--max-shadow-pairs", str(max_cases),
                "--max-gold-pairs", str(max_cases),
            ]
        )
    if simulate_no_provider:
        audit_cmd.append("--simulate-no-provider")
    judge_audit = run_cmd(audit_cmd, repo, phase_dir, "generate_judge_audit", timeout_s=phase_timeout_s)

    return {
        "cache_hit": calibration_cache_hit and symmetry_cache_hit,
        "calibration_cache_hit": calibration_cache_hit,
        "symmetry_cache_hit": symmetry_cache_hit,
        "calibration_key": calibration_key,
        "symmetry_key": symmetry_key,
        "calibration": cal,
        "symmetry": sym,
        "judge_audit": judge_audit,
        "selected_judge_prompt": selected_judge_prompt,
        "calibration_summary": str(cal_out / "summary.json"),
        "symmetry_summary": str(sym_out / "summary.json"),
        "judge_audit_path": str(audit_out),
    }


def phase_phaseC(repo: pathlib.Path, phase_dir: pathlib.Path) -> dict[str, Any]:
    registry_path = repo / "bench/prompt_eval/config/candidate_registry.v1.json"
    data = json.loads(registry_path.read_text(encoding="utf-8"))
    missing = []
    for fam, arr in (data.get("families") or {}).items():
        for item in arr:
            p = repo / item["prompt_path"]
            if not p.exists():
                missing.append(f"{fam}:{item['id']} missing prompt {p}")
    result = {"missing_prompts": missing, "family_count": len(data.get("families") or {})}
    (phase_dir / "candidate_lint.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def phase_eval_split(
    repo: pathlib.Path,
    phase_dir: pathlib.Path,
    provider_contract: dict[str, Any],
    split: str,
    cases_rel: str,
    timeout: int,
    max_cases: int,
    pairwise_top_k: int,
    pairwise_repeats: int,
    simulate_no_provider: bool,
) -> dict[str, Any]:
    phase_timeout_s = max(600, int(timeout) * 6)
    out_dir = phase_dir / f"{split}_eval"
    out_dir.mkdir(parents=True, exist_ok=True)
    if simulate_no_provider:
        fixture = repo / "bench/prompt_eval/fixtures/split_eval_summary.simulated.json"
        if fixture.exists():
            fixture_json = json.loads(fixture.read_text(encoding="utf-8"))
            fixture_json["simulated_artifacts"] = True
            fixture_json["provider_contract_path"] = provider_contract["path"]
            (out_dir / "summary.json").write_text(json.dumps(fixture_json, indent=2) + "\n", encoding="utf-8")
            return {
                "run": {
                    "name": f"run_codex_prompt_eval_{split}",
                    "returncode": 0,
                    "elapsed_seconds": 0.0,
                    "simulated": True,
                },
                "summary": str(out_dir / "summary.json"),
                "simulated": True,
            }
    cmd = [
        "python3", "bench/prompt_eval/run_codex_prompt_eval.py",
        "--cases", cases_rel,
        "--out-dir", str(out_dir),
        "--timeout", str(timeout),
        "--pairwise-top-k", str(pairwise_top_k),
        "--pairwise-repeats", str(pairwise_repeats),
        "--provider-contract", provider_contract["path"],
    ]
    if split == "holdout":
        cmd.append("--redact-sensitive")
    if max_cases > 0:
        cmd.extend(["--max-cases", str(max_cases)])
    run = run_cmd(cmd, repo, phase_dir, f"run_codex_prompt_eval_{split}", timeout_s=phase_timeout_s)
    return {"run": run, "summary": str(out_dir / "summary.json")}


def phase_phaseG(
    repo: pathlib.Path,
    phase_dir: pathlib.Path,
    cal_summary: pathlib.Path,
    sym_summary: pathlib.Path,
    phase_summary: pathlib.Path,
    strict: bool,
    judge_audit: pathlib.Path | None = None,
    armj_calibration_summary: pathlib.Path | None = None,
    armj_invariance_summary: pathlib.Path | None = None,
    armo_summary: pathlib.Path | None = None,
) -> dict[str, Any]:
    out = phase_dir / "gate_report.json"
    cmd = [
        "python3", "bench/prompt_eval/tools/evaluate_gates.py",
        "--calibration-summary", str(cal_summary),
        "--symmetry-summary", str(sym_summary),
        "--phase-summary", str(phase_summary),
        "--out", str(out),
    ]
    if judge_audit is not None:
        cmd.extend(["--judge-audit", str(judge_audit)])
    if armj_calibration_summary is not None:
        cmd.extend(["--armj-calibration-summary", str(armj_calibration_summary)])
    if armj_invariance_summary is not None:
        cmd.extend(["--armj-invariance-summary", str(armj_invariance_summary)])
    if armo_summary is not None:
        cmd.extend(["--armo-summary", str(armo_summary)])
    if strict:
        cmd.append("--strict")
    ev = run_cmd(cmd, repo, phase_dir, "evaluate_gates")
    return {"gate_eval": ev, "gate_report": str(out)}


def main() -> int:
    ap = argparse.ArgumentParser(description="Autonomous phase orchestrator for prompt eval")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--provider-contract", default=DEFAULT_PROVIDER_CONTRACT)
    ap.add_argument("--cycle-id", default="")
    ap.add_argument("--phase", choices=PHASES + ["all"], default="all")
    ap.add_argument("--max-cases", type=int, default=0)
    ap.add_argument("--pairwise-top-k", type=int, default=0)
    ap.add_argument("--pairwise-repeats", type=int, default=0)
    ap.add_argument("--timeout", type=int, default=240)
    ap.add_argument("--skip-promptfoo", action="store_true")
    ap.add_argument("--simulate-no-provider", action="store_true")
    strict_group = ap.add_mutually_exclusive_group()
    strict_group.add_argument("--strict-promotion", dest="strict_promotion", action="store_true")
    strict_group.add_argument("--non-strict-promotion", dest="strict_promotion", action="store_false")
    ap.set_defaults(strict_promotion=True)
    ap.add_argument("--no-judge-cache", action="store_true")
    ap.add_argument("--allow-holdout", action="store_true")
    ap.add_argument("--judge-audit-path", default="")
    ap.add_argument("--armj-calibration-summary-path", default="")
    ap.add_argument("--armj-invariance-summary-path", default="")
    ap.add_argument("--armo-summary-path", default="")
    ap.add_argument("--continue-on-error", action="store_true")
    args = ap.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    try:
        provider_contract = load_provider_contract(repo, args.provider_contract)
    except ProviderContractError as exc:
        raise RuntimeError(f"provider contract load failed: {exc}") from exc
    providers = provider_contract["providers"]
    if providers["drafting"]["runner"] != "codex":
        raise RuntimeError(
            "unsupported provider runner for drafting role in orchestrator: "
            f"{providers['drafting']['runner']!r}"
        )
    if providers["judge_primary"]["runner"] != "codex":
        raise RuntimeError(
            "unsupported provider runner for judge_primary role in orchestrator: "
            f"{providers['judge_primary']['runner']!r}"
        )

    cycle_id = args.cycle_id or dt.datetime.now().strftime("cycle-%Y%m%d-%H%M%S")
    reports_root = repo / "bench" / "prompt_eval" / "reports" / cycle_id
    reports_root.mkdir(parents=True, exist_ok=True)
    gate_manifest_path = repo / "bench/prompt_eval/config/gate_manifest.v1.json"
    gate_manifest = json.loads(gate_manifest_path.read_text(encoding="utf-8"))
    mode_policy = gate_manifest.get("mode_policy") or {}
    budget_caps = gate_manifest.get("budget_caps") or {}
    allow_policy_mutation = bool(mode_policy.get("allow_policy_mutation_mid_cycle", False))
    cycle_start = time.time()
    cycle_usage = {
        "total_tokens": 0.0,
        "cost_usd": 0.0,
    }
    usage_meta = {
        "missing_cost_count": 0,
        "cost_observed_count": 0,
    }
    policy_paths = [
        gate_manifest_path,
        repo / "bench/prompt_eval/config/providers.v1.json",
        repo / "bench/prompt_eval/config/candidate_registry.v1.json",
        repo / "bench/prompt_architecture/v1/preset_registry.json",
        repo / "bench/prompt_architecture/v1/selection_policy.json",
    ]
    policy_hash_baseline = compute_hash_map(policy_paths)
    (reports_root / "policy_lock_baseline.json").write_text(
        json.dumps({"policy_hashes": policy_hash_baseline}, indent=2) + "\n",
        encoding="utf-8",
    )
    judge_repeats = int(
        ((gate_manifest.get("minimum_sample_floors") or {}).get("judge_repeats_min", 2))
    )
    pairwise_repeats = max(1, int(args.pairwise_repeats or judge_repeats))
    holdout_looks_max = int(
        ((gate_manifest.get("minimum_sample_floors") or {}).get("holdout_looks_per_cycle_max", 1))
    )

    selected = PHASES if args.phase == "all" else [args.phase]
    phase_results: dict[str, Any] = {}

    cal_summary_path: pathlib.Path | None = None
    sym_summary_path: pathlib.Path | None = None
    holdout_summary_path: pathlib.Path | None = None

    for phase in selected:
        phase_dir = reports_root / phase
        phase_dir.mkdir(parents=True, exist_ok=True)
        t0 = time.time()
        details: dict[str, Any] = {}
        status = "ok"
        error: str | None = None

        try:
            if (not allow_policy_mutation) and phase not in {"phase0_bootstrap", "phaseA_policy_freeze"}:
                current_hashes = compute_hash_map(policy_paths)
                if current_hashes != policy_hash_baseline:
                    raise RuntimeError("policy mutated mid-cycle while allow_policy_mutation_mid_cycle=false")

            if phase == "phase0_bootstrap":
                details = phase_phase0(repo, phase_dir)
                if issues := collect_nonzero_returncodes(details):
                    raise RuntimeError("phase0 command failures: " + "; ".join(issues))
                build_manifest(
                    repo, cycle_id, phase, "dev", phase_dir,
                    [
                        repo / "bench/prompt_eval/config/dev.promptfoo.yaml",
                        repo / "bench/prompt_eval/config/providers.v1.json",
                    ],
                    [repo / "bench/prompt_eval/datasets/dev/cases.jsonl"],
                    [],
                    judge_prompt=repo / DEFAULT_JUDGE_PROMPT,
                    judge_model=providers["judge_primary"]["model"],
                    draft_model=providers["drafting"]["model"],
                )
            elif phase == "phaseA_policy_freeze":
                details = phase_phaseA(repo, phase_dir)
                if details.get("errors"):
                    raise RuntimeError("policy freeze validation failed: " + "; ".join(details["errors"]))
                build_manifest(
                    repo,
                    cycle_id,
                    phase,
                    "dev",
                    phase_dir,
                    [
                        repo / "bench/prompt_eval/config/gate_manifest.v1.json",
                        repo / "bench/prompt_eval/config/providers.v1.json",
                    ],
                    [repo / "bench/prompt_eval/datasets/dev/cases.jsonl"],
                    [],
                    judge_prompt=repo / DEFAULT_JUDGE_PROMPT,
                    judge_model=providers["judge_primary"]["model"],
                    draft_model=providers["drafting"]["model"],
                )
                (phase_dir / "policy_lock.json").write_text(
                    json.dumps({"policy_hashes": policy_hash_baseline}, indent=2) + "\n",
                    encoding="utf-8",
                )
            elif phase == "phaseB_judge_reliability":
                details = phase_phaseB(
                    repo=repo,
                    phase_dir=phase_dir,
                    provider_contract=provider_contract,
                    max_cases=args.max_cases,
                    timeout=args.timeout,
                    judge_repeats=judge_repeats,
                    simulate_no_provider=args.simulate_no_provider,
                    use_cache=not args.no_judge_cache,
                )
                if issues := collect_nonzero_returncodes(details):
                    raise RuntimeError("phaseB command failures: " + "; ".join(issues))
                cal_summary_path = pathlib.Path(details["calibration_summary"])
                sym_summary_path = pathlib.Path(details["symmetry_summary"])
                build_manifest(
                    repo,
                    cycle_id,
                    phase,
                    "calibration",
                    phase_dir,
                    [
                        repo / "bench/prompt_eval/config/gate_manifest.v1.json",
                        repo / "bench/prompt_eval/config/providers.v1.json",
                    ],
                    [
                        repo / "bench/prompt_eval/datasets/calibration/judge_pairs.jsonl",
                        repo / "bench/prompt_eval/datasets/calibration/judge_triads.jsonl",
                        repo / "bench/prompt_eval/datasets/calibration/shadow_spotcheck_pairs.jsonl",
                        repo / "bench/prompt_eval/datasets/calibration/gold_anchor_pairs.jsonl",
                    ],
                    [],
                    judge_prompt=details.get("selected_judge_prompt") or (repo / DEFAULT_JUDGE_PROMPT),
                    judge_model=providers["judge_primary"]["model"],
                    draft_model=providers["drafting"]["model"],
                )
            elif phase == "phaseC_candidate_generation":
                details = phase_phaseC(repo, phase_dir)
                if details.get("missing_prompts"):
                    raise RuntimeError("candidate lint failed: " + "; ".join(details["missing_prompts"]))
                build_manifest(
                    repo, cycle_id, phase, "dev", phase_dir,
                    [
                        repo / "bench/prompt_eval/config/candidate_registry.v1.json",
                        repo / "bench/prompt_eval/config/providers.v1.json",
                    ],
                    [repo / "bench/prompt_eval/datasets/dev/cases.jsonl"],
                    [],
                    judge_prompt=repo / DEFAULT_JUDGE_PROMPT,
                    judge_model=providers["judge_primary"]["model"],
                    draft_model=providers["drafting"]["model"],
                )
            elif phase == "phaseD_dev":
                if args.skip_promptfoo:
                    pf = {
                        "name": "promptfoo_eval",
                        "returncode": 0,
                        "elapsed_seconds": 0.0,
                        "skipped": True,
                        "reason": "skip_promptfoo_flag",
                    }
                else:
                    pf = maybe_promptfoo_eval(
                        repo,
                        phase_dir,
                        "bench/prompt_eval/config/dev.promptfoo.yaml",
                        "dev",
                        args.simulate_no_provider,
                    )
                details = {"promptfoo": pf}
                ensure_promptfoo_phase_ok(pf, "phaseD")
                details["codex_eval"] = phase_eval_split(
                    repo,
                    phase_dir,
                    provider_contract,
                    "dev",
                    "bench/prompt_eval/datasets/dev/pilot_cases.jsonl",
                    args.timeout,
                    args.max_cases,
                    args.pairwise_top_k,
                    pairwise_repeats,
                    args.simulate_no_provider,
                )
                if issues := collect_nonzero_returncodes(details):
                    raise RuntimeError("phaseD command failures: " + "; ".join(issues))
                d_identity = extract_eval_identity(pathlib.Path(details["codex_eval"]["summary"]))
                build_manifest(
                    repo, cycle_id, phase, "dev", phase_dir,
                    [
                        repo / "bench/prompt_eval/config/dev.promptfoo.yaml",
                        repo / "bench/prompt_eval/config/providers.v1.json",
                    ],
                    [
                        repo / "bench/prompt_eval/datasets/dev/cases.jsonl",
                        repo / "bench/prompt_eval/datasets/dev/pilot_cases.jsonl",
                    ],
                    [],
                    judge_prompt=d_identity.get("judge_prompt") or (repo / DEFAULT_JUDGE_PROMPT),
                    judge_model=d_identity.get("judge_model") or providers["judge_primary"]["model"],
                    draft_model=d_identity.get("draft_model") or providers["drafting"]["model"],
                )
            elif phase == "phaseE_adversarial":
                if args.skip_promptfoo:
                    pf = {
                        "name": "promptfoo_eval",
                        "returncode": 0,
                        "elapsed_seconds": 0.0,
                        "skipped": True,
                        "reason": "skip_promptfoo_flag",
                    }
                else:
                    pf = maybe_promptfoo_eval(
                        repo,
                        phase_dir,
                        "bench/prompt_eval/config/adversarial.promptfoo.yaml",
                        "adversarial",
                        args.simulate_no_provider,
                    )
                details = {"promptfoo": pf}
                ensure_promptfoo_phase_ok(pf, "phaseE")
                details["codex_eval"] = phase_eval_split(
                    repo,
                    phase_dir,
                    provider_contract,
                    "adversarial",
                    "bench/prompt_eval/datasets/adversarial/pilot_cases.jsonl",
                    args.timeout,
                    args.max_cases,
                    args.pairwise_top_k,
                    pairwise_repeats,
                    args.simulate_no_provider,
                )
                if issues := collect_nonzero_returncodes(details):
                    raise RuntimeError("phaseE command failures: " + "; ".join(issues))
                e_identity = extract_eval_identity(pathlib.Path(details["codex_eval"]["summary"]))
                build_manifest(
                    repo, cycle_id, phase, "adversarial", phase_dir,
                    [
                        repo / "bench/prompt_eval/config/adversarial.promptfoo.yaml",
                        repo / "bench/prompt_eval/config/providers.v1.json",
                    ],
                    [
                        repo / "bench/prompt_eval/datasets/adversarial/cases.jsonl",
                        repo / "bench/prompt_eval/datasets/adversarial/pilot_cases.jsonl",
                    ],
                    [],
                    judge_prompt=e_identity.get("judge_prompt") or (repo / DEFAULT_JUDGE_PROMPT),
                    judge_model=e_identity.get("judge_model") or providers["judge_primary"]["model"],
                    draft_model=e_identity.get("draft_model") or providers["drafting"]["model"],
                )
            elif phase == "phaseF_holdout":
                if args.allow_holdout:
                    os.environ["PROMPT_EVAL_ALLOW_HOLDOUT"] = "1"
                look_counter_path = phase_dir / "holdout_look_counter.json"
                existing_looks = 0
                if look_counter_path.exists():
                    try:
                        counter_payload = json.loads(look_counter_path.read_text(encoding="utf-8"))
                        existing_looks = int(counter_payload.get("looks", 0) or 0)
                    except Exception:
                        raise RuntimeError("invalid holdout look counter payload")
                if existing_looks >= holdout_looks_max:
                    raise RuntimeError(
                        f"holdout look budget exceeded: existing={existing_looks} max={holdout_looks_max}"
                    )
                current_looks = existing_looks + 1
                look_counter_path.write_text(
                    json.dumps(
                        {
                            "phase": phase,
                            "cycle_id": cycle_id,
                            "looks": current_looks,
                            "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                        },
                        indent=2,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                (phase_dir / "holdout_attempt.marker").write_text(
                    json.dumps(
                        {
                            "phase": phase,
                            "cycle_id": cycle_id,
                            "look_number": current_looks,
                            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                        },
                        indent=2,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                iso = run_cmd([
                    "python3", "bench/prompt_eval/tools/enforce_holdout_isolation.py",
                    "--phase", "phaseF_holdout",
                    "--config", "bench/prompt_eval/config/holdout.promptfoo.yaml",
                ], repo, phase_dir, "enforce_holdout_isolation")
                if iso.get("returncode", 0) != 0:
                    raise RuntimeError(f"phaseF holdout isolation failed: rc={iso.get('returncode')}")
                if args.skip_promptfoo:
                    pf = {
                        "name": "promptfoo_eval",
                        "returncode": 0,
                        "elapsed_seconds": 0.0,
                        "skipped": True,
                        "reason": "skip_promptfoo_flag",
                    }
                else:
                    pf = maybe_promptfoo_eval(
                        repo,
                        phase_dir,
                        "bench/prompt_eval/config/holdout.promptfoo.yaml",
                        "holdout",
                        args.simulate_no_provider,
                    )
                details = {"isolation": iso, "promptfoo": pf}
                ensure_promptfoo_phase_ok(pf, "phaseF")
                details["codex_eval"] = phase_eval_split(
                    repo,
                    phase_dir,
                    provider_contract,
                    "holdout",
                    "bench/prompt_eval/datasets/holdout/pilot_cases.jsonl",
                    args.timeout,
                    args.max_cases,
                    args.pairwise_top_k,
                    pairwise_repeats,
                    args.simulate_no_provider,
                )
                if issues := collect_nonzero_returncodes(details):
                    raise RuntimeError("phaseF command failures: " + "; ".join(issues))
                holdout_summary_path = pathlib.Path(details["codex_eval"]["summary"])
                f_identity = extract_eval_identity(holdout_summary_path)
                build_manifest(
                    repo, cycle_id, phase, "holdout", phase_dir,
                    [
                        repo / "bench/prompt_eval/config/holdout.promptfoo.yaml",
                        repo / "bench/prompt_eval/config/providers.v1.json",
                    ],
                    [
                        repo / "bench/prompt_eval/datasets/holdout/cases.jsonl",
                        repo / "bench/prompt_eval/datasets/holdout/pilot_cases.jsonl",
                    ],
                    [],
                    judge_prompt=f_identity.get("judge_prompt") or (repo / DEFAULT_JUDGE_PROMPT),
                    judge_model=f_identity.get("judge_model") or providers["judge_primary"]["model"],
                    draft_model=f_identity.get("draft_model") or providers["drafting"]["model"],
                )
            elif phase == "phaseG_promotion":
                if cal_summary_path is None:
                    cal_summary_path = (reports_root / "phaseB_judge_reliability" / "judge_calibration" / "summary.json")
                if sym_summary_path is None:
                    sym_summary_path = (reports_root / "phaseB_judge_reliability" / "judge_symmetry" / "summary.json")
                if holdout_summary_path is None:
                    holdout_summary_path = (reports_root / "phaseF_holdout" / "holdout_eval" / "summary.json")
                judge_audit_path: pathlib.Path | None = None
                if args.judge_audit_path:
                    judge_audit_path = pathlib.Path(args.judge_audit_path).resolve()
                else:
                    auto_judge_audit = reports_root / "phaseB_judge_reliability" / "judge_audit.json"
                    if auto_judge_audit.exists():
                        judge_audit_path = auto_judge_audit
                if args.strict_promotion and judge_audit_path is None:
                    raise RuntimeError(
                        "strict promotion requires judge_audit artifact "
                        "(pass --judge-audit-path or generate reports/<cycle>/phaseB_judge_reliability/judge_audit.json)"
                    )
                armj_calibration_path: pathlib.Path | None = None
                armj_invariance_path: pathlib.Path | None = None
                armo_summary_path: pathlib.Path | None = None
                if args.armj_calibration_summary_path:
                    armj_calibration_path = pathlib.Path(args.armj_calibration_summary_path).resolve()
                if args.armj_invariance_summary_path:
                    armj_invariance_path = pathlib.Path(args.armj_invariance_summary_path).resolve()
                if args.armo_summary_path:
                    armo_summary_path = pathlib.Path(args.armo_summary_path).resolve()
                if args.strict_promotion and (
                    armj_calibration_path is None or armj_invariance_path is None or armo_summary_path is None
                ):
                    raise RuntimeError(
                        "strict promotion requires Arm J + Arm O artifacts "
                        "(pass --armj-calibration-summary-path, --armj-invariance-summary-path, --armo-summary-path)"
                    )
                details = phase_phaseG(
                    repo,
                    phase_dir,
                    cal_summary_path,
                    sym_summary_path,
                    holdout_summary_path,
                    args.strict_promotion,
                    judge_audit=judge_audit_path,
                    armj_calibration_summary=armj_calibration_path,
                    armj_invariance_summary=armj_invariance_path,
                    armo_summary=armo_summary_path,
                )
                if issues := collect_nonzero_returncodes(details):
                    raise RuntimeError("phaseG command failures: " + "; ".join(issues))
                g_identity = extract_eval_identity(holdout_summary_path)
                build_manifest(
                    repo, cycle_id, phase, "holdout", phase_dir,
                    [
                        repo / "bench/prompt_eval/config/gate_manifest.v1.json",
                        repo / "bench/prompt_eval/config/providers.v1.json",
                    ],
                    [holdout_summary_path],
                    [],
                    judge_prompt=g_identity.get("judge_prompt") or (repo / DEFAULT_JUDGE_PROMPT),
                    judge_model=g_identity.get("judge_model") or providers["judge_primary"]["model"],
                    draft_model=g_identity.get("draft_model") or providers["drafting"]["model"],
                )
            else:
                raise RuntimeError(f"Unknown phase: {phase}")
        except Exception as e:
            status = "error"
            error = str(e)
            details.setdefault("errors", [])
            if isinstance(details["errors"], list):
                details["errors"].append(error)
        # Always account usage and enforce budgets, even when a phase errors.
        if isinstance(details, dict):
            codex_eval = details.get("codex_eval")
            if isinstance(codex_eval, dict):
                summary_path = codex_eval.get("summary")
                if isinstance(summary_path, str) and summary_path:
                    usage = extract_usage_totals_from_summary(pathlib.Path(summary_path))
                    add_usage_to_cycle(cycle_usage, usage_meta, usage)
            promptfoo = details.get("promptfoo")
            if isinstance(promptfoo, dict) and not promptfoo.get("simulated"):
                promptfoo_results_path = phase_dir / "promptfoo_results.json"
                usage = extract_usage_totals_from_promptfoo_results(promptfoo_results_path)
                add_usage_to_cycle(cycle_usage, usage_meta, usage)
                if usage:
                    details["promptfoo_usage"] = usage
            for key in ("calibration_summary", "symmetry_summary", "judge_audit_path"):
                p = details.get(key)
                if isinstance(p, str) and p:
                    if key == "calibration_summary" and bool(details.get("calibration_cache_hit")):
                        continue
                    if key == "symmetry_summary" and bool(details.get("symmetry_cache_hit")):
                        continue
                    usage = extract_usage_totals_from_summary(pathlib.Path(p))
                    add_usage_to_cycle(cycle_usage, usage_meta, usage)

        cycle_elapsed_minutes = (time.time() - cycle_start) / 60.0
        max_wall_minutes = float(budget_caps.get("cycle_max_wall_clock_minutes", 0) or 0)
        max_tokens = float(budget_caps.get("cycle_max_tokens", 0) or 0)
        max_cost = float(budget_caps.get("cycle_max_cost_usd", 0) or 0)
        warning_ratio = float(budget_caps.get("warning_ratio", 0.8) or 0.8)
        budget_warnings: list[str] = []
        if max_wall_minutes > 0 and cycle_elapsed_minutes > (max_wall_minutes * warning_ratio):
            budget_warnings.append(
                f"BUDGET_WARNING:wall_clock_minutes={cycle_elapsed_minutes:.2f}/{max_wall_minutes:.2f}"
            )
        if max_tokens > 0 and cycle_usage["total_tokens"] > (max_tokens * warning_ratio):
            budget_warnings.append(
                f"BUDGET_WARNING:total_tokens={cycle_usage['total_tokens']:.0f}/{max_tokens:.0f}"
            )
        if max_cost > 0 and cycle_usage["cost_usd"] > (max_cost * warning_ratio):
            budget_warnings.append(
                f"BUDGET_WARNING:cost_usd={cycle_usage['cost_usd']:.4f}/{max_cost:.4f}"
            )
        if max_cost > 0 and cycle_usage["total_tokens"] > 0 and usage_meta["cost_observed_count"] == 0:
            budget_warnings.append("BUDGET_WARNING:cost_telemetry_missing_for_token_usage")
        if budget_warnings and isinstance(details, dict):
            details.setdefault("warnings", [])
            if isinstance(details["warnings"], list):
                details["warnings"].extend(budget_warnings)

        budget_error: str | None = None
        if max_wall_minutes > 0 and cycle_elapsed_minutes > max_wall_minutes:
            budget_error = (
                f"budget cap exceeded: wall_clock_minutes={cycle_elapsed_minutes:.2f} max={max_wall_minutes:.2f}"
            )
        elif max_tokens > 0 and cycle_usage["total_tokens"] > max_tokens:
            budget_error = (
                f"budget cap exceeded: total_tokens={cycle_usage['total_tokens']:.0f} max={max_tokens:.0f}"
            )
        elif max_cost > 0 and cycle_usage["cost_usd"] > max_cost:
            budget_error = (
                f"budget cap exceeded: cost_usd={cycle_usage['cost_usd']:.4f} max={max_cost:.4f}"
            )
        if budget_error:
            if status == "ok":
                status = "error"
                error = budget_error
            else:
                error = f"{error}; {budget_error}" if error else budget_error
            details.setdefault("errors", [])
            if isinstance(details["errors"], list):
                details["errors"].append(budget_error)

        elapsed = round(time.time() - t0, 3)
        timing = {"phase": phase, "elapsed_seconds": elapsed, "status": status, "error": error}
        (phase_dir / "timing.json").write_text(json.dumps(timing, indent=2) + "\n", encoding="utf-8")
        (phase_dir / "summary.json").write_text(json.dumps(details, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

        # Self-review for each phase
        run_cmd([
            "python3", "bench/prompt_eval/tools/self_review.py",
            "--report-dir", str(phase_dir),
            "--out", str(phase_dir / "self_review.json"),
        ], repo, phase_dir, "self_review")

        phase_results[phase] = {
            "status": status,
            "error": error,
            "elapsed_seconds": elapsed,
        }
        if status == "error" and args.phase == "all" and not args.continue_on_error:
            break

    overall_ok = all(v["status"] == "ok" for v in phase_results.values())
    final = {
        "ok": overall_ok,
        "cycle_id": cycle_id,
        "reports_root": str(reports_root),
        "phase_results": phase_results,
        "budget_usage": {
            "total_tokens": round(cycle_usage["total_tokens"], 2),
            "cost_usd": round(cycle_usage["cost_usd"], 6),
            "cost_observed_count": int(usage_meta["cost_observed_count"]),
            "missing_cost_count": int(usage_meta["missing_cost_count"]),
            "elapsed_minutes": round((time.time() - cycle_start) / 60.0, 3),
        },
    }
    (reports_root / "cycle_summary.json").write_text(json.dumps(final, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    try:
        perf_proc = subprocess.run(
            [
                "python3",
                "bench/prompt_eval/tools/performance_review.py",
                "--reports-root",
                str(reports_root),
                "--out",
                str(reports_root / "cycle_performance_review.json"),
            ],
            cwd=str(repo),
            text=True,
            capture_output=True,
            timeout=600,
        )
        perf_stdout = perf_proc.stdout or ""
        perf_stderr = perf_proc.stderr or ""
        perf_returncode = perf_proc.returncode
    except subprocess.TimeoutExpired as exc:
        perf_stdout = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
        perf_stderr = ((exc.stderr or "") if isinstance(exc.stderr, str) else "") + "\n[timeout] performance review exceeded 600s\n"
        perf_returncode = 124
    (reports_root / "cycle_performance_review.stdout.log").write_text(perf_stdout, encoding="utf-8")
    (reports_root / "cycle_performance_review.stderr.log").write_text(perf_stderr, encoding="utf-8")

    if perf_returncode == 0 and (reports_root / "cycle_performance_review.json").exists():
        final["performance_review"] = str(reports_root / "cycle_performance_review.json")
        (reports_root / "cycle_summary.json").write_text(json.dumps(final, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(json.dumps(final, indent=2, ensure_ascii=False))
    return 0 if overall_ok else 4


if __name__ == "__main__":
    raise SystemExit(main())
