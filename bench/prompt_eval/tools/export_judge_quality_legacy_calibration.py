#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import pathlib
from collections import defaultdict
from typing import Any


REPO = pathlib.Path(__file__).resolve().parents[3]
DEFAULT_JUDGE_QUALITY_DIR = REPO / "bench/prompt_eval/datasets/judge_quality"
DEFAULT_OUT_DIR = REPO / "bench/prompt_eval/datasets/calibration/legacy_from_judge_quality"
MANIFEST_NAME = "split_manifest.v1.json"
SEALED_SPLIT = "sealed_test"
BREAK_GLASS_TOKEN_HASH_ALGO = "sha256"
BREAK_GLASS_TOKEN_HASH_ENV = "PROMPT_EVAL_JUDGE_QUALITY_BREAK_GLASS_TOKEN_HASH"
MANIFEST_SIGNATURE_SECRET_ENV = "PROMPT_EVAL_JUDGE_QUALITY_MANIFEST_SECRET"


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_jsonl(path: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return rows


def write_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_jsonl(path: pathlib.Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rows_sorted = sorted(rows, key=lambda row: str(row.get("id", "")))
    path.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows_sorted) + "\n", encoding="utf-8")


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def stable_sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def stable_hash_object(payload: Any) -> str:
    data = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def canonical_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(rows, key=lambda row: str(row.get("id", "")))


def rows_digest(rows: list[dict[str, Any]]) -> str:
    return stable_hash_object(canonical_rows(rows))


def build_detached_manifest_payload(
    *,
    manifest_core: dict[str, Any],
    gold_rows: list[dict[str, Any]],
    perturb_rows: list[dict[str, Any]],
    pair_rows: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "dataset_family": str(manifest_core.get("dataset_family", "")),
        "split_seed": manifest_core.get("split_seed"),
        "split_locked_at": manifest_core.get("split_locked_at"),
        "manifest_core_sha256": stable_hash_object(manifest_core),
        "files": {
            "gold_prompts.jsonl": rows_digest(gold_rows),
            "perturbations.jsonl": rows_digest(perturb_rows),
            "pairwise_labels.jsonl": rows_digest(pair_rows),
        },
    }


def sign_manifest_payload(secret: str, payload: dict[str, Any]) -> str:
    message = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return hmac.new(secret.encode("utf-8"), message, hashlib.sha256).hexdigest()


def require_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    governance = manifest.get("governance")
    if not isinstance(governance, dict):
        raise RuntimeError("split manifest missing governance block")
    if "sealed_open_count" not in governance:
        raise RuntimeError("split manifest governance missing sealed_open_count")
    return governance


def verify_manifest_signature(
    *,
    manifest: dict[str, Any],
    gold_rows: list[dict[str, Any]],
    perturb_rows: list[dict[str, Any]],
    pair_rows: list[dict[str, Any]],
) -> None:
    integrity = manifest.get("integrity")
    signature_block = (
        integrity.get("detached_manifest_signature") if isinstance(integrity, dict) else None
    )
    if not isinstance(signature_block, dict):
        raise RuntimeError("split manifest missing integrity.detached_manifest_signature")

    if not bool(signature_block.get("required", True)):
        raise RuntimeError("detached manifest signature must be required=true for export")

    signing_secret = os.getenv(MANIFEST_SIGNATURE_SECRET_ENV, "").strip()
    if not signing_secret:
        raise RuntimeError(
            "detached manifest signature verification requires signing secret "
            f"(export {MANIFEST_SIGNATURE_SECRET_ENV})"
        )

    signature = signature_block.get("signature")
    if not isinstance(signature, str) or not signature.strip():
        raise RuntimeError("detached manifest signature is missing")

    manifest_core = dict(manifest)
    manifest_core.pop("integrity", None)
    payload = build_detached_manifest_payload(
        manifest_core=manifest_core,
        gold_rows=gold_rows,
        perturb_rows=perturb_rows,
        pair_rows=pair_rows,
    )
    payload_hash = signature_block.get("payload_sha256")
    expected_payload_hash = stable_hash_object(payload)
    if payload_hash != expected_payload_hash:
        raise RuntimeError("detached manifest payload hash mismatch")

    expected_signature = sign_manifest_payload(signing_secret, payload)
    if not hmac.compare_digest(expected_signature, signature.strip()):
        raise RuntimeError("detached manifest signature invalid")


def trusted_break_glass_hash(governance: dict[str, Any]) -> str | None:
    env_hash = os.getenv(BREAK_GLASS_TOKEN_HASH_ENV, "").strip().lower()
    if env_hash:
        return env_hash
    manifest_hash = governance.get("trusted_break_glass_token_hash")
    if isinstance(manifest_hash, str):
        manifest_hash = manifest_hash.strip().lower()
        if manifest_hash:
            return manifest_hash
    return None


def is_adjudicated_row(row: dict[str, Any], *, expected_item_type: str) -> bool:
    return row.get("item_type") == expected_item_type and row.get("adjudication_status") == "adjudicated"


def export_rows(
    gold_rows: list[dict[str, Any]],
    perturb_rows: list[dict[str, Any]],
    allowed_splits: set[str],
) -> dict[str, list[dict[str, Any]]]:
    gold_by_id: dict[str, dict[str, Any]] = {}
    for row in gold_rows:
        if is_adjudicated_row(row, expected_item_type="gold") and row.get("split") in allowed_splits:
            gold_by_id[str(row["id"])] = row

    perturb_by_parent: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in perturb_rows:
        parent = row.get("parent_prompt_id")
        if (
            is_adjudicated_row(row, expected_item_type="perturbation")
            and isinstance(parent, str)
            and row.get("split") in allowed_splits
        ):
            perturb_by_parent[parent].append(row)

    judge_pairs: list[dict[str, Any]] = []
    judge_triads: list[dict[str, Any]] = []
    shadow_pairs: list[dict[str, Any]] = []
    gold_anchor_pairs: list[dict[str, Any]] = []

    for gold_id in sorted(gold_by_id):
        gold = gold_by_id[gold_id]
        family = str(gold.get("preset_family", ""))
        draft_prompt = str(gold.get("prompt_text", ""))
        perturbations = sorted(
            perturb_by_parent.get(gold_id, []),
            key=lambda row: (float(row.get("absolute_score_0_100") or 0.0), str(row.get("id", ""))),
            reverse=True,
        )
        if not perturbations:
            continue

        strongest = perturbations[0]
        weakest = perturbations[-1]

        # Legacy judge pairs: include A-win, B-win, Tie for calibration diversity.
        judge_pairs.append(
            {
                "id": f"{gold_id}_legacy_a_win",
                "preset": family,
                "draft_prompt": draft_prompt,
                "candidate_a": draft_prompt,
                "candidate_b": str(weakest.get("prompt_text", "")),
                "expected_winner": "A",
            }
        )
        judge_pairs.append(
            {
                "id": f"{gold_id}_legacy_b_win",
                "preset": family,
                "draft_prompt": draft_prompt,
                "candidate_a": str(weakest.get("prompt_text", "")),
                "candidate_b": draft_prompt,
                "expected_winner": "B",
            }
        )
        judge_pairs.append(
            {
                "id": f"{gold_id}_legacy_tie",
                "preset": family,
                "draft_prompt": draft_prompt,
                "candidate_a": draft_prompt,
                "candidate_b": draft_prompt,
                "expected_winner": "Tie",
            }
        )

        # Shadow spotcheck pairs: clear winners, no labels.
        shadow_pairs.append(
            {
                "id": f"{gold_id}_legacy_shadow_01",
                "preset": family,
                "draft_prompt": draft_prompt,
                "candidate_a": draft_prompt,
                "candidate_b": str(weakest.get("prompt_text", "")),
            }
        )
        shadow_pairs.append(
            {
                "id": f"{gold_id}_legacy_shadow_02",
                "preset": family,
                "draft_prompt": draft_prompt,
                "candidate_a": str(strongest.get("prompt_text", "")),
                "candidate_b": str(weakest.get("prompt_text", "")),
            }
        )

        # Gold anchors: strongest hard-negative (if present), else weakest perturbation.
        hard_negatives = [row for row in perturbations if bool(row.get("hard_negative"))]
        anchor_candidate = hard_negatives[0] if hard_negatives else weakest
        gold_anchor_pairs.append(
            {
                "id": f"{gold_id}_legacy_gold_anchor_01",
                "preset": family,
                "draft_prompt": draft_prompt,
                "candidate_a": draft_prompt,
                "candidate_b": str(anchor_candidate.get("prompt_text", "")),
                "expected_winner": "A",
            }
        )

        # Triad: A (gold) > B (best perturbation) > C (worst perturbation)
        judge_triads.append(
            {
                "id": f"{gold_id}_legacy_triad",
                "preset": family,
                "draft_prompt": draft_prompt,
                "candidate_a": draft_prompt,
                "candidate_b": str(strongest.get("prompt_text", "")),
                "candidate_c": str(weakest.get("prompt_text", "")),
                "expected_order": "A>B>C",
            }
        )

    return {
        "judge_pairs": judge_pairs,
        "judge_triads": judge_triads,
        "shadow_spotcheck_pairs": shadow_pairs,
        "gold_anchor_pairs": gold_anchor_pairs,
    }


def update_manifest_audit(
    *,
    manifest_path: pathlib.Path,
    manifest: dict[str, Any],
    reason: str,
    break_glass_token: str | None,
    allowed_splits: set[str],
    gold_rows: list[dict[str, Any]],
    perturb_rows: list[dict[str, Any]],
    pair_rows: list[dict[str, Any]],
) -> None:
    governance = require_manifest(manifest)
    opened_at = utc_now_iso()
    governance["sealed_open_count"] = int(governance.get("sealed_open_count", 0)) + 1
    governance["sealed_opened_at"] = opened_at
    governance["sealed_open_reason"] = reason
    governance["break_glass_used"] = bool(break_glass_token)
    if break_glass_token:
        governance["break_glass_token_hash"] = stable_sha256(break_glass_token)

    audit_log = governance.get("sealed_export_audit_log")
    if not isinstance(audit_log, list):
        audit_log = []
        governance["sealed_export_audit_log"] = audit_log

    audit_log.append(
        {
            "opened_at": opened_at,
            "reason": reason,
            "break_glass_used": bool(break_glass_token),
            "break_glass_token_hash_algo": BREAK_GLASS_TOKEN_HASH_ALGO if break_glass_token else None,
            "break_glass_token_hash": stable_sha256(break_glass_token) if break_glass_token else None,
            "allowed_splits": sorted(allowed_splits),
        }
    )

    # Re-sign detached manifest integrity after governance mutation.
    signature_block = (
        manifest.get("integrity", {}).get("detached_manifest_signature")
        if isinstance(manifest.get("integrity"), dict)
        else None
    )
    if not isinstance(signature_block, dict):
        raise RuntimeError("split manifest missing integrity.detached_manifest_signature for re-sign")
    if not bool(signature_block.get("required", True)):
        raise RuntimeError("detached manifest signature must be required=true for re-sign")

    signing_secret = os.getenv(MANIFEST_SIGNATURE_SECRET_ENV, "").strip()
    if not signing_secret:
        raise RuntimeError(
            "re-sign requires detached manifest signing secret "
            f"(export {MANIFEST_SIGNATURE_SECRET_ENV})"
        )

    manifest_core = dict(manifest)
    manifest_core.pop("integrity", None)
    payload = build_detached_manifest_payload(
        manifest_core=manifest_core,
        gold_rows=gold_rows,
        perturb_rows=perturb_rows,
        pair_rows=pair_rows,
    )
    signature_block["payload_sha256"] = stable_hash_object(payload)
    signature_block["signature"] = sign_manifest_payload(signing_secret, payload)
    signature_block["signed_at"] = opened_at

    write_json(manifest_path, manifest)


def main() -> int:
    parser = argparse.ArgumentParser(description="Export judge_quality datasets into legacy calibration files.")
    parser.add_argument("--repo", default=str(REPO))
    parser.add_argument("--judge-quality-dir", default=str(DEFAULT_JUDGE_QUALITY_DIR))
    parser.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR))
    parser.add_argument("--open-sealed-test", action="store_true")
    parser.add_argument("--open-sealed-test-reason", default="")
    parser.add_argument("--break-glass-token", default="")
    args = parser.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    judge_quality_dir = pathlib.Path(args.judge_quality_dir).resolve()
    out_dir = pathlib.Path(args.out_dir).resolve()

    manifest_path = judge_quality_dir / MANIFEST_NAME
    manifest = load_json(manifest_path)
    gold = load_jsonl(judge_quality_dir / "gold_prompts.jsonl")
    perturb = load_jsonl(judge_quality_dir / "perturbations.jsonl")
    pair_rows = load_jsonl(judge_quality_dir / "pairwise_labels.jsonl")
    verify_manifest_signature(
        manifest=manifest,
        gold_rows=gold,
        perturb_rows=perturb,
        pair_rows=pair_rows,
    )
    governance = require_manifest(manifest)
    sealed_open_count = int(governance.get("sealed_open_count", 0))

    if not args.open_sealed_test:
        if sealed_open_count > 0:
            raise RuntimeError(
                "default export is fail-closed after sealed set has been opened (sealed_open_count > 0); "
                "provide explicit break-glass sealed export arguments if needed"
            )
        allowed_splits = {"dev", "tune"}
    else:
        reason = args.open_sealed_test_reason.strip()
        if not reason:
            raise RuntimeError("--open-sealed-test requires --open-sealed-test-reason")
        break_glass_token = args.break_glass_token.strip() or None
        if sealed_open_count > 0 and not break_glass_token:
            raise RuntimeError(
                "sealed_open_count > 0 requires break-glass token for repeated sealed export "
                "(--break-glass-token <token>)"
            )
        if sealed_open_count > 0:
            trusted_hash = trusted_break_glass_hash(governance)
            if not trusted_hash:
                raise RuntimeError(
                    "sealed_open_count > 0 requires trusted break-glass token hash "
                    f"(set {BREAK_GLASS_TOKEN_HASH_ENV} or governance.trusted_break_glass_token_hash)"
                )
            provided_hash = stable_sha256(break_glass_token or "")
            if not hmac.compare_digest(provided_hash, trusted_hash):
                raise RuntimeError("invalid break-glass token for repeated sealed export")
        allowed_splits = {"dev", "tune", SEALED_SPLIT}

    exported = export_rows(gold, perturb, allowed_splits=allowed_splits)
    if not exported["judge_pairs"]:
        raise RuntimeError("no legacy judge_pairs rows generated (check input data and split filters)")

    out_dir.mkdir(parents=True, exist_ok=True)
    write_jsonl(out_dir / "judge_pairs.jsonl", exported["judge_pairs"])
    write_jsonl(out_dir / "judge_triads.jsonl", exported["judge_triads"])
    write_jsonl(out_dir / "shadow_spotcheck_pairs.jsonl", exported["shadow_spotcheck_pairs"])
    write_jsonl(out_dir / "gold_anchor_pairs.jsonl", exported["gold_anchor_pairs"])

    metadata = {
        "ok": True,
        "generated_at": utc_now_iso(),
        "source_dataset_dir": str(judge_quality_dir),
        "output_dir": str(out_dir),
        "included_splits": sorted(allowed_splits),
        "counts": {name: len(rows) for name, rows in exported.items()},
        "open_sealed_test": bool(args.open_sealed_test),
    }
    write_json(out_dir / "export_manifest.v1.json", metadata)

    if args.open_sealed_test:
        update_manifest_audit(
            manifest_path=manifest_path,
            manifest=manifest,
            reason=args.open_sealed_test_reason.strip(),
            break_glass_token=(args.break_glass_token.strip() or None),
            allowed_splits=allowed_splits,
            gold_rows=gold,
            perturb_rows=perturb,
            pair_rows=pair_rows,
        )

    print(json.dumps(metadata, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
