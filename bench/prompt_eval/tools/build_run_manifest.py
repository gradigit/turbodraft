#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
from typing import Any


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser(description="Build run manifest artifact")
    ap.add_argument("--phase", required=True)
    ap.add_argument("--cycle-id", default="")
    ap.add_argument("--dataset-split", required=True)
    ap.add_argument("--gate-manifest", default="bench/prompt_eval/config/gate_manifest.v1.json")
    ap.add_argument("--judge-prompt", default="bench/prompt_eval/prompts/judge_pairwise_v3.md")
    ap.add_argument("--judge-model", default="gpt-5.4")
    ap.add_argument("--draft-model", default="gpt-5.4-spark")
    ap.add_argument("--dataset-path", action="append", default=[])
    ap.add_argument("--config-path", action="append", default=[])
    ap.add_argument("--reason-code", action="append", default=[])
    ap.add_argument("--notes", default="")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    now = dt.datetime.now(dt.timezone.utc).isoformat()
    cycle_id = args.cycle_id or f"cycle-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}"

    gate_path = pathlib.Path(args.gate_manifest).resolve()
    judge_prompt_path = pathlib.Path(args.judge_prompt).resolve()
    dataset_paths = [pathlib.Path(p).resolve() for p in args.dataset_path]
    config_paths = [pathlib.Path(p).resolve() for p in args.config_path]

    errors: list[str] = []
    if not gate_path.exists():
        errors.append(f"missing gate manifest: {gate_path}")
    if not judge_prompt_path.exists():
        errors.append(f"missing judge prompt: {judge_prompt_path}")
    for p in dataset_paths:
        if not p.exists():
            errors.append(f"missing dataset path: {p}")
    for p in config_paths:
        if not p.exists():
            errors.append(f"missing config path: {p}")
    if errors:
        print(json.dumps({"ok": False, "errors": errors}, ensure_ascii=False, indent=2))
        return 2

    dataset_hashes = {str(p): sha256_file(p) for p in dataset_paths}
    config_hashes = {str(p): sha256_file(p) for p in config_paths}

    manifest: dict[str, Any] = {
        "cycle_id": cycle_id,
        "phase": args.phase,
        "created_at": now,
        "policy_version": "v1",
        "gate_manifest_path": str(gate_path),
        "gate_manifest_sha256": sha256_file(gate_path),
        "judge_prompt_path": str(judge_prompt_path),
        "judge_prompt_sha256": sha256_file(judge_prompt_path),
        "judge_model": args.judge_model,
        "draft_model": args.draft_model,
        "dataset_split": args.dataset_split,
        "dataset_paths": [str(p) for p in dataset_paths],
        "dataset_hashes": dataset_hashes,
        "config_paths": [str(p) for p in config_paths],
        "config_hashes": config_hashes,
        "sequential_mode": os.environ.get("PROMPT_EVAL_SEQUENTIAL_MODE", "0") == "1",
        "reason_codes": args.reason_code,
    }
    if args.notes:
        manifest["notes"] = args.notes

    out_path = pathlib.Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(json.dumps({"ok": True, "out": str(out_path), "manifest": manifest}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
