#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
from datetime import datetime
from typing import Any

_ALLOWED_PHASES = {
    "phase0_bootstrap",
    "phaseA_policy_freeze",
    "phaseB_judge_reliability",
    "phaseC_candidate_generation",
    "phaseD_dev",
    "phaseE_adversarial",
    "phaseF_holdout",
    "phaseG_promotion",
}
_ALLOWED_SPLITS = {"calibration", "dev", "adversarial", "holdout"}
_SHA256 = re.compile(r"^[a-f0-9]{64}$")


def _is_nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _valid_iso_datetime(value: str) -> bool:
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return True
    except ValueError:
        return False


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def validate_manifest(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []

    def require_str(key: str) -> str:
        value = data.get(key)
        if not _is_nonempty_string(value):
            errors.append(f"{key}: must be non-empty string")
            return ""
        return str(value)

    cycle_id = require_str("cycle_id")
    if cycle_id and cycle_id.strip() != cycle_id:
        errors.append("cycle_id: must not have leading/trailing spaces")

    phase = require_str("phase")
    if phase and phase not in _ALLOWED_PHASES:
        errors.append(f"phase: invalid value {phase!r}")

    created_at = require_str("created_at")
    if created_at and not _valid_iso_datetime(created_at):
        errors.append("created_at: must be ISO-8601 datetime")

    policy_version = require_str("policy_version")
    if policy_version and policy_version != "v1":
        errors.append("policy_version: must equal 'v1'")

    gate_manifest_path = require_str("gate_manifest_path")
    gate_manifest_path_obj: pathlib.Path | None = None
    if gate_manifest_path:
        gate_manifest_path_obj = pathlib.Path(gate_manifest_path)
        if not gate_manifest_path_obj.is_absolute():
            errors.append("gate_manifest_path: must be absolute path")
        elif not gate_manifest_path_obj.exists():
            errors.append("gate_manifest_path: path does not exist")

    gate_sha = require_str("gate_manifest_sha256")
    if gate_sha and not _SHA256.match(gate_sha):
        errors.append("gate_manifest_sha256: must be 64 lowercase hex chars")
    if gate_manifest_path_obj and gate_manifest_path_obj.exists() and gate_sha and _SHA256.match(gate_sha):
        actual_gate_sha = sha256_file(gate_manifest_path_obj)
        if actual_gate_sha != gate_sha:
            errors.append("gate_manifest_sha256: does not match file content")

    judge_prompt_path = require_str("judge_prompt_path")
    judge_prompt_path_obj: pathlib.Path | None = None
    if judge_prompt_path:
        judge_prompt_path_obj = pathlib.Path(judge_prompt_path)
        if not judge_prompt_path_obj.is_absolute():
            errors.append("judge_prompt_path: must be absolute path")
        elif not judge_prompt_path_obj.exists():
            errors.append("judge_prompt_path: path does not exist")
    judge_prompt_sha = require_str("judge_prompt_sha256")
    if judge_prompt_sha and not _SHA256.match(judge_prompt_sha):
        errors.append("judge_prompt_sha256: must be 64 lowercase hex chars")
    if judge_prompt_path_obj and judge_prompt_path_obj.exists() and judge_prompt_sha and _SHA256.match(judge_prompt_sha):
        actual_judge_sha = sha256_file(judge_prompt_path_obj)
        if actual_judge_sha != judge_prompt_sha:
            errors.append("judge_prompt_sha256: does not match file content")

    require_str("judge_model")
    require_str("draft_model")

    dataset_split = require_str("dataset_split")
    if dataset_split and dataset_split not in _ALLOWED_SPLITS:
        errors.append(f"dataset_split: invalid value {dataset_split!r}")

    dataset_paths = data.get("dataset_paths")
    if not isinstance(dataset_paths, list) or len(dataset_paths) == 0:
        errors.append("dataset_paths: must be non-empty array")
    else:
        for i, item in enumerate(dataset_paths):
            if not _is_nonempty_string(item):
                errors.append(f"dataset_paths[{i}]: must be non-empty string")
            else:
                p = pathlib.Path(str(item))
                if not p.is_absolute():
                    errors.append(f"dataset_paths[{i}]: must be absolute path")
                elif not p.exists():
                    errors.append(f"dataset_paths[{i}]: path does not exist")

    dataset_hashes = data.get("dataset_hashes")
    if not isinstance(dataset_hashes, dict) or len(dataset_hashes) == 0:
        errors.append("dataset_hashes: must be non-empty object")
    else:
        for k, v in dataset_hashes.items():
            if not _is_nonempty_string(k):
                errors.append("dataset_hashes key: must be non-empty string")
            if not (_is_nonempty_string(v) and _SHA256.match(str(v))):
                errors.append(f"dataset_hashes[{k!r}]: must be 64 lowercase hex chars")

    config_paths = data.get("config_paths")
    if not isinstance(config_paths, list) or len(config_paths) == 0:
        errors.append("config_paths: must be non-empty array")
    else:
        for i, item in enumerate(config_paths):
            if not _is_nonempty_string(item):
                errors.append(f"config_paths[{i}]: must be non-empty string")
            else:
                p = pathlib.Path(str(item))
                if not p.is_absolute():
                    errors.append(f"config_paths[{i}]: must be absolute path")
                elif not p.exists():
                    errors.append(f"config_paths[{i}]: path does not exist")

    config_hashes = data.get("config_hashes")
    if not isinstance(config_hashes, dict) or len(config_hashes) == 0:
        errors.append("config_hashes: must be non-empty object")
    else:
        for k, v in config_hashes.items():
            if not _is_nonempty_string(k):
                errors.append("config_hashes key: must be non-empty string")
            if not (_is_nonempty_string(v) and _SHA256.match(str(v))):
                errors.append(f"config_hashes[{k!r}]: must be 64 lowercase hex chars")

    if isinstance(dataset_paths, list) and isinstance(dataset_hashes, dict):
        expected = {str(pathlib.Path(str(p)).resolve()) for p in dataset_paths if _is_nonempty_string(p)}
        actual_map = {
            str(pathlib.Path(k).resolve()): str(v)
            for k, v in dataset_hashes.items()
            if _is_nonempty_string(k) and _is_nonempty_string(v)
        }
        actual = set(actual_map.keys())
        if expected != actual:
            missing_hashes = sorted(expected - actual)
            extra_hashes = sorted(actual - expected)
            if missing_hashes:
                errors.append("dataset_hashes missing entries for: " + ", ".join(missing_hashes))
            if extra_hashes:
                errors.append("dataset_hashes has unexpected entries: " + ", ".join(extra_hashes))
        for abs_path in sorted(expected & actual):
            path_obj = pathlib.Path(abs_path)
            if path_obj.exists():
                actual_sha = sha256_file(path_obj)
                recorded_sha = actual_map.get(abs_path, "")
                if actual_sha != recorded_sha:
                    errors.append(f"dataset_hashes mismatch for: {abs_path}")

    if isinstance(config_paths, list) and isinstance(config_hashes, dict):
        expected = {str(pathlib.Path(str(p)).resolve()) for p in config_paths if _is_nonempty_string(p)}
        actual_map = {
            str(pathlib.Path(k).resolve()): str(v)
            for k, v in config_hashes.items()
            if _is_nonempty_string(k) and _is_nonempty_string(v)
        }
        actual = set(actual_map.keys())
        if expected != actual:
            missing_hashes = sorted(expected - actual)
            extra_hashes = sorted(actual - expected)
            if missing_hashes:
                errors.append("config_hashes missing entries for: " + ", ".join(missing_hashes))
            if extra_hashes:
                errors.append("config_hashes has unexpected entries: " + ", ".join(extra_hashes))
        for abs_path in sorted(expected & actual):
            path_obj = pathlib.Path(abs_path)
            if path_obj.exists():
                actual_sha = sha256_file(path_obj)
                recorded_sha = actual_map.get(abs_path, "")
                if actual_sha != recorded_sha:
                    errors.append(f"config_hashes mismatch for: {abs_path}")

    sequential_mode = data.get("sequential_mode")
    if not isinstance(sequential_mode, bool):
        errors.append("sequential_mode: must be boolean")

    reason_codes = data.get("reason_codes")
    if not isinstance(reason_codes, list):
        errors.append("reason_codes: must be array")
    else:
        for i, rc in enumerate(reason_codes):
            if not _is_nonempty_string(rc):
                errors.append(f"reason_codes[{i}]: must be non-empty string")

    notes = data.get("notes")
    if notes is not None and not isinstance(notes, str):
        errors.append("notes: must be string when present")

    extra = sorted(set(data.keys()) - {
        "cycle_id",
        "phase",
        "created_at",
        "policy_version",
        "gate_manifest_path",
        "gate_manifest_sha256",
        "judge_prompt_path",
        "judge_prompt_sha256",
        "judge_model",
        "draft_model",
        "dataset_split",
        "dataset_paths",
        "dataset_hashes",
        "config_paths",
        "config_hashes",
        "sequential_mode",
        "reason_codes",
        "notes",
    })
    if extra:
        errors.append("unexpected properties: " + ", ".join(extra))

    return errors


def main() -> int:
    ap = argparse.ArgumentParser(description="Validate run_manifest.json against required contract")
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--schema", default="bench/prompt_eval/config/run_manifest.schema.json")
    args = ap.parse_args()

    manifest_path = pathlib.Path(args.manifest).resolve()
    schema_path = pathlib.Path(args.schema).resolve()
    if not schema_path.exists():
        print(json.dumps({"ok": False, "errors": [f"schema missing: {schema_path}"]}, indent=2))
        return 2
    try:
        schema_data = json.loads(schema_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(json.dumps({"ok": False, "errors": [f"schema parse failed: {schema_path}: {exc}"]}, indent=2))
        return 2

    if not manifest_path.exists():
        print(json.dumps({"ok": False, "errors": [f"manifest missing: {manifest_path}"]}, indent=2))
        return 2

    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    errors = validate_manifest(data)
    required_keys = schema_data.get("required") if isinstance(schema_data, dict) else []
    if not isinstance(required_keys, list):
        required_keys = []
    for key in required_keys:
        if key not in data:
            errors.append(f"missing required key from schema: {key}")
    properties = schema_data.get("properties") if isinstance(schema_data, dict) else {}
    if isinstance(properties, dict) and schema_data.get("additionalProperties") is False:
        extra = sorted(set(data.keys()) - set(properties.keys()))
        if extra:
            errors.append("schema additionalProperties=false violation: " + ", ".join(extra))

    out = {
        "ok": len(errors) == 0,
        "manifest": str(manifest_path),
        "schema": str(schema_path),
        "errors": errors,
    }
    print(json.dumps(out, indent=2, ensure_ascii=False))
    return 0 if out["ok"] else 3


if __name__ == "__main__":
    raise SystemExit(main())
