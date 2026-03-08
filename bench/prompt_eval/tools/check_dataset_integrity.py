#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import pathlib
import re
from itertools import combinations
from typing import Any

from build_judge_quality_dataset import evaluate_lock_eligible, krippendorff_alpha_interval

SPLITS = ["calibration", "dev", "adversarial", "holdout"]
JUDGE_QUALITY_FILES = [
    "gold_prompts.jsonl",
    "perturbations.jsonl",
    "pairwise_labels.jsonl",
    "split_manifest.v1.json",
]
JUDGE_SPLITS = {"dev", "tune", "sealed_test"}
ADJUDICATION_STATUSES = {"pending", "adjudicated", "excluded"}
MANIFEST_SIGNATURE_SECRET_ENV = "PROMPT_EVAL_JUDGE_QUALITY_MANIFEST_SECRET"


def load_jsonl(path: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))
    return rows


def norm_text(s: str) -> str:
    s = s.lower()
    s = re.sub(r"\s+", " ", s)
    return s.strip()


def char_ngrams(s: str, n: int = 5) -> set[str]:
    if len(s) < n:
        return {s}
    return {s[i:i+n] for i in range(len(s) - n + 1)}


def jaccard(a: set[str], b: set[str]) -> float:
    if not a and not b:
        return 1.0
    return len(a & b) / max(1, len(a | b))


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


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
    data = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return hmac.new(secret.encode("utf-8"), data, hashlib.sha256).hexdigest()


def bcp47_like(tag: str) -> bool:
    return bool(re.fullmatch(r"^[A-Za-z]{2,3}(?:-[A-Za-z]{4})?(?:-[A-Za-z]{2}|\-\d{3})?(?:-[A-Za-z0-9]{5,8})*$", tag))


def validate_judge_quality(
    root: pathlib.Path,
    *,
    near_duplicate_threshold: float,
    fail_on_near_duplicate: bool,
    strict_pairwise_linkage: bool,
    allow_unsigned_manifest_signature: bool,
    errors: list[str],
    warnings: list[str],
) -> dict[str, Any]:
    jq_dir = root / "judge_quality"
    result: dict[str, Any] = {"present": jq_dir.exists()}
    if not jq_dir.exists():
        warnings.append("judge_quality dataset directory not found; skipping judge_quality checks")
        return result

    missing = [name for name in JUDGE_QUALITY_FILES if not (jq_dir / name).exists()]
    if missing:
        for name in missing:
            errors.append(f"judge_quality: missing required file {name}")
        return result

    gold_rows = load_jsonl(jq_dir / "gold_prompts.jsonl")
    perturb_rows = load_jsonl(jq_dir / "perturbations.jsonl")
    pair_rows = load_jsonl(jq_dir / "pairwise_labels.jsonl")
    manifest = load_json(jq_dir / "split_manifest.v1.json")
    all_rows = gold_rows + perturb_rows + pair_rows

    manifest_core = dict(manifest)
    manifest_core.pop("integrity", None)
    signature_block = (
        manifest.get("integrity", {}).get("detached_manifest_signature")
        if isinstance(manifest.get("integrity"), dict)
        else None
    )
    if not isinstance(signature_block, dict):
        if allow_unsigned_manifest_signature:
            warnings.append("judge_quality: detached manifest signature missing (allowed by override)")
        else:
            errors.append("judge_quality: split_manifest missing integrity.detached_manifest_signature")
    else:
        detached_payload = build_detached_manifest_payload(
            manifest_core=manifest_core,
            gold_rows=gold_rows,
            perturb_rows=perturb_rows,
            pair_rows=pair_rows,
        )
        expected_payload_hash = stable_hash_object(detached_payload)
        payload_hash = signature_block.get("payload_sha256")
        if payload_hash != expected_payload_hash:
            errors.append("judge_quality: detached manifest payload hash mismatch")

        declared_required = bool(signature_block.get("required", True))
        signature = signature_block.get("signature")
        signature_present = isinstance(signature, str) and bool(signature.strip())
        signing_secret = os.getenv(MANIFEST_SIGNATURE_SECRET_ENV, "").strip()
        if not declared_required and not allow_unsigned_manifest_signature:
            errors.append("judge_quality: detached manifest signature must be required=true for lock artifacts")

        # Security policy: treat detached signature as required unless explicit local override is set.
        required = True
        if required:
            if not signature_present:
                if allow_unsigned_manifest_signature:
                    warnings.append("judge_quality: signature required but missing (allowed by override)")
                else:
                    errors.append("judge_quality: detached manifest signature required but missing")
            elif not signing_secret:
                if allow_unsigned_manifest_signature:
                    warnings.append("judge_quality: signature required but secret not set (allowed by override)")
                else:
                    errors.append(
                        "judge_quality: detached signature secret not set "
                        f"(export {MANIFEST_SIGNATURE_SECRET_ENV})"
                    )
            else:
                expected_signature = sign_manifest_payload(signing_secret, detached_payload)
                if not hmac.compare_digest(expected_signature, str(signature).strip()):
                    if allow_unsigned_manifest_signature:
                        warnings.append("judge_quality: detached manifest signature invalid (allowed by override)")
                    else:
                        errors.append("judge_quality: detached manifest signature invalid")
        elif signature_present and signing_secret:
            expected_signature = sign_manifest_payload(signing_secret, detached_payload)
            if not hmac.compare_digest(expected_signature, str(signature).strip()):
                errors.append("judge_quality: detached manifest signature invalid")

    required_fields = {
        "id",
        "preset_family",
        "item_type",
        "language_tag",
        "language_source",
        "split",
        "split_seed",
        "split_locked_at",
        "parent_prompt_id",
        "blinded_item_id",
        "blind_round",
        "sealed_open_count",
        "expected_relation",
        "absolute_score_0_100",
        "error_tags",
        "adjudication_status",
        "rater_count",
        "rater_ids_hashed",
        "provenance_source",
        "provenance_artifact",
        "provenance_commit",
        "negative_origin",
        "perturbation_template_id",
        "hard_negative",
        "text_sha256",
    }

    gold_by_id = {str(row.get("id")): row for row in gold_rows}
    perturb_by_id = {str(row.get("id")): row for row in perturb_rows}
    ids_seen: set[str] = set()
    for row in all_rows:
        row_id = str(row.get("id", ""))
        if not row_id:
            errors.append("judge_quality: row missing non-empty id")
            continue
        if row_id in ids_seen:
            errors.append(f"judge_quality: duplicate id {row_id}")
        ids_seen.add(row_id)

        missing_fields = sorted(key for key in required_fields if key not in row)
        if missing_fields:
            errors.append(f"judge_quality:{row_id}: missing required fields {', '.join(missing_fields)}")
            continue

        item_type = row.get("item_type")
        if item_type not in {"gold", "perturbation", "pairwise"}:
            errors.append(f"judge_quality:{row_id}: invalid item_type {item_type!r}")
        split = row.get("split")
        if split not in JUDGE_SPLITS:
            errors.append(f"judge_quality:{row_id}: invalid split {split!r}")
        language_tag = row.get("language_tag")
        if not isinstance(language_tag, str) or not bcp47_like(language_tag):
            errors.append(f"judge_quality:{row_id}: invalid language_tag {language_tag!r}")
        if row.get("adjudication_status") not in ADJUDICATION_STATUSES:
            errors.append(
                f"judge_quality:{row_id}: adjudication_status must be pending|adjudicated|excluded"
            )
        provenance_source = row.get("provenance_source")
        provenance_artifact = row.get("provenance_artifact")
        provenance_commit = row.get("provenance_commit")
        if not isinstance(provenance_source, str) or not provenance_source.strip():
            errors.append(f"judge_quality:{row_id}: provenance_source must be non-empty string")
        if not isinstance(provenance_artifact, str) or not provenance_artifact.strip():
            errors.append(f"judge_quality:{row_id}: provenance_artifact must be non-empty string")
        if not isinstance(provenance_commit, str) or not provenance_commit.strip():
            errors.append(f"judge_quality:{row_id}: provenance_commit must be non-empty string")
        else:
            commit = provenance_commit.strip()
            if commit != "unknown" and not re.fullmatch(r"[0-9a-f]{7,64}", commit):
                errors.append(f"judge_quality:{row_id}: provenance_commit must be git SHA-like or 'unknown'")
        label_source_class = row.get("label_source_class")
        if label_source_class is not None and label_source_class not in {
            "synthetic_generated",
            "human_adjudicated",
        }:
            errors.append(
                f"judge_quality:{row_id}: label_source_class must be synthetic_generated|human_adjudicated when present"
            )
        if not isinstance(row.get("error_tags"), list):
            errors.append(f"judge_quality:{row_id}: error_tags must be a list")
        if not isinstance(row.get("rater_count"), int):
            errors.append(f"judge_quality:{row_id}: rater_count must be int")
        elif row.get("rater_count", 0) < 0:
            errors.append(f"judge_quality:{row_id}: rater_count must be >= 0")
        rater_ids = row.get("rater_ids_hashed")
        if not isinstance(rater_ids, list):
            errors.append(f"judge_quality:{row_id}: rater_ids_hashed must be list")
        elif isinstance(row.get("rater_count"), int) and len(rater_ids) != int(row["rater_count"]):
            errors.append(f"judge_quality:{row_id}: rater_ids_hashed length != rater_count")
        if not isinstance(row.get("sealed_open_count"), int) or int(row["sealed_open_count"]) < 0:
            errors.append(f"judge_quality:{row_id}: sealed_open_count must be non-negative integer")

        if item_type in {"gold", "perturbation"}:
            score = row.get("absolute_score_0_100")
            if not isinstance(score, (int, float)) or not (0 <= float(score) <= 100):
                errors.append(f"judge_quality:{row_id}: absolute_score_0_100 must be numeric in [0,100]")
            prompt_text = row.get("prompt_text")
            if not isinstance(prompt_text, str) or not prompt_text:
                errors.append(f"judge_quality:{row_id}: prompt_text missing/invalid")
            else:
                expected_hash = hashlib.sha256(prompt_text.encode("utf-8")).hexdigest()
                if expected_hash != row.get("text_sha256"):
                    errors.append(f"judge_quality:{row_id}: text_sha256 mismatch")
        elif item_type == "pairwise":
            expected_hash = stable_hash_object(
                {"a": row.get("candidate_a", ""), "b": row.get("candidate_b", ""), "id": row_id}
            )
            if expected_hash != row.get("text_sha256"):
                errors.append(f"judge_quality:{row_id}: pairwise text_sha256 mismatch")
            a_hash = row.get("candidate_a_text_sha256")
            b_hash = row.get("candidate_b_text_sha256")
            if a_hash is not None:
                if a_hash != hashlib.sha256(str(row.get("candidate_a", "")).encode("utf-8")).hexdigest():
                    errors.append(f"judge_quality:{row_id}: candidate_a_text_sha256 mismatch")
            if b_hash is not None:
                if b_hash != hashlib.sha256(str(row.get("candidate_b", "")).encode("utf-8")).hexdigest():
                    errors.append(f"judge_quality:{row_id}: candidate_b_text_sha256 mismatch")
            a_src = row.get("candidate_a_source")
            b_src = row.get("candidate_b_source")
            if (a_src is not None or b_src is not None) and (
                a_src not in {"gold", "perturbation"} or b_src not in {"gold", "perturbation"} or a_src == b_src
            ):
                errors.append(
                    f"judge_quality:{row_id}: candidate_*_source must be complementary gold/perturbation when present"
                )
            perturbation_id = row.get("perturbation_id")
            if perturbation_id is not None:
                if not isinstance(perturbation_id, str) or not perturbation_id:
                    errors.append(f"judge_quality:{row_id}: perturbation_id must be non-empty string when present")
                else:
                    perturb = perturb_by_id.get(perturbation_id)
                    parent = gold_by_id.get(str(row.get("parent_prompt_id") or ""))
                    if perturb is None:
                        errors.append(f"judge_quality:{row_id}: perturbation_id not found in perturbations set")
                    elif strict_pairwise_linkage and parent is not None:
                        pa = str(row.get("candidate_a") or "")
                        pb = str(row.get("candidate_b") or "")
                        parent_text = str(parent.get("prompt_text") or "")
                        perturb_text = str(perturb.get("prompt_text") or "")
                        if {pa, pb} != {parent_text, perturb_text}:
                            errors.append(f"judge_quality:{row_id}: candidates do not match parent+perturbation texts")
                        expected_winner = str(row.get("expected_winner") or "")
                        if a_src == "gold" and expected_winner != "A":
                            errors.append(f"judge_quality:{row_id}: expected_winner must be A when candidate_a_source=gold")
                        if b_src == "gold" and expected_winner != "B":
                            errors.append(f"judge_quality:{row_id}: expected_winner must be B when candidate_b_source=gold")

    # Parent-child split inheritance.
    for row in perturb_rows + pair_rows:
        row_id = str(row.get("id", ""))
        parent_id = row.get("parent_prompt_id")
        if not isinstance(parent_id, str):
            errors.append(f"judge_quality:{row_id}: parent_prompt_id must be a string")
            continue
        parent = gold_by_id.get(parent_id)
        if parent is None:
            errors.append(f"judge_quality:{row_id}: parent_prompt_id not found in gold set: {parent_id}")
            continue
        if row.get("split") != parent.get("split"):
            errors.append(
                f"judge_quality:{row_id}: split inheritance violated (child={row.get('split')} parent={parent.get('split')})"
            )

    # Lock-eligible predicate + rater gate + alpha.
    lock_eligible: list[dict[str, Any]] = []
    for row in gold_rows:
        row_id = str(row.get("id", ""))
        eval_result = evaluate_lock_eligible(row)
        if not eval_result.computable:
            errors.append(f"judge_quality:{row_id}: lock-eligible predicate not computable ({eval_result.reason})")
            continue
        if eval_result.is_lock_eligible:
            if int(row.get("rater_count", 0)) < 3:
                errors.append(f"judge_quality:{row_id}: lock-eligible row has rater_count < 3")
            lock_eligible.append(row)

    alpha = 0.0
    if lock_eligible:
        units: list[list[float]] = []
        for row in lock_eligible:
            ratings = row.get("blinded_ratings")
            if not isinstance(ratings, list) or len(ratings) < 2:
                errors.append(f"judge_quality:{row.get('id')}: lock-eligible row missing blinded_ratings")
                continue
            units.append([float(v) for v in ratings if isinstance(v, (int, float))])
        if units:
            alpha = krippendorff_alpha_interval(units)
        quality_gates = manifest.get("quality_gates") if isinstance(manifest.get("quality_gates"), dict) else {}
        alpha_floor = float(quality_gates.get("krippendorff_alpha_min", 0.67))
        if alpha < alpha_floor:
            errors.append(f"judge_quality: alpha gate failed ({alpha:.6f} < {alpha_floor})")
    else:
        errors.append("judge_quality: no lock-eligible gold rows")

    # Natural-vs-synthetic ratio + hard-negative coverage.
    natural = 0
    synthetic = 0
    hard_negative_by_family: dict[str, int] = {}
    for row in perturb_rows:
        row_id = str(row.get("id", ""))
        family = str(row.get("preset_family", ""))
        origin = row.get("negative_origin")
        if origin == "natural":
            natural += 1
        elif origin == "synthetic":
            synthetic += 1
        else:
            errors.append(f"judge_quality:{row_id}: negative_origin must be natural|synthetic")
        if bool(row.get("hard_negative")):
            hard_negative_by_family[family] = hard_negative_by_family.get(family, 0) + 1
    neg_total = natural + synthetic
    natural_ratio = (natural / neg_total) if neg_total > 0 else 0.0
    quality_gates = manifest.get("quality_gates") if isinstance(manifest.get("quality_gates"), dict) else {}
    natural_floor = float(quality_gates.get("natural_negative_ratio_min", 0.5))
    if natural_ratio < natural_floor:
        errors.append(f"judge_quality: natural-negative ratio failed ({natural_ratio:.6f} < {natural_floor})")
    for family in sorted({str(row.get("preset_family", "")) for row in gold_rows}):
        if hard_negative_by_family.get(family, 0) < 1:
            errors.append(f"judge_quality:{family}: missing hard-negative coverage")

    observed_families = sorted({str(row.get("preset_family", "")) for row in gold_rows})
    families_block = manifest.get("families")
    if not isinstance(families_block, dict):
        errors.append("judge_quality: split_manifest missing families map")
        manifest_families: list[str] = []
    else:
        manifest_families = sorted(str(name) for name in families_block.keys())
    if observed_families != manifest_families:
        errors.append(
            "judge_quality: family set mismatch "
            f"(observed={observed_families}, manifest={manifest_families})"
        )

    # Family-stratified split validation.
    split_validation_mode = str(manifest.get("split_validation_mode") or "ratio_floor")
    target_ratios = manifest.get("target_ratios_by_family") or {"dev": 0.6, "tune": 0.2, "sealed_test": 0.2}
    ratio_tolerance = float(manifest.get("ratio_tolerance", 0.05))
    min_counts = manifest.get("min_counts_per_split_per_family") or {"dev": 1, "tune": 1, "sealed_test": 1}
    counts_by_family: dict[str, dict[str, int]] = {}
    for row in gold_rows:
        family = str(row.get("preset_family", ""))
        split = str(row.get("split", ""))
        counts = counts_by_family.setdefault(family, {"dev": 0, "tune": 0, "sealed_test": 0})
        if split in counts:
            counts[split] += 1

    for family, counts in sorted(counts_by_family.items()):
        total = sum(counts.values())
        if total <= 0:
            errors.append(f"judge_quality:{family}: no gold rows")
            continue
        if split_validation_mode == "exact_per_family":
            family_manifest = families_block.get(family) if isinstance(families_block, dict) else None
            expected_counts = (
                family_manifest.get("gold_counts_by_split")
                if isinstance(family_manifest, dict)
                else None
            )
            if not isinstance(expected_counts, dict):
                errors.append(f"judge_quality:{family}: exact_per_family requires families.{family}.gold_counts_by_split")
                continue
            for split in JUDGE_SPLITS:
                expected = int(expected_counts.get(split, 0))
                observed = int(counts.get(split, 0))
                if observed != expected:
                    errors.append(
                        f"judge_quality:{family}: split exact-count mismatch for {split} "
                        f"(obs={observed}, expected={expected})"
                    )
        else:
            for split in JUDGE_SPLITS:
                floor = int(min_counts.get(split, 0))
                if counts.get(split, 0) < floor:
                    errors.append(
                        f"judge_quality:{family}: split floor fail for {split} "
                        f"({counts.get(split, 0)} < {floor})"
                    )
                target = float(target_ratios.get(split, 0.0))
                observed = counts.get(split, 0) / total
                if abs(observed - target) > ratio_tolerance:
                    errors.append(
                        f"judge_quality:{family}: split ratio out of bounds for {split} "
                        f"(obs={observed:.6f}, target={target:.6f}, tol={ratio_tolerance:.6f})"
                    )

    governance = manifest.get("governance")
    if not isinstance(governance, dict):
        errors.append("judge_quality: split_manifest missing governance")
    else:
        if not isinstance(governance.get("sealed_open_count"), int):
            errors.append("judge_quality: governance.sealed_open_count must be integer")

    # Near-duplicate prompt text across judge_quality split boundaries.
    jq_entries: list[tuple[str, str, str]] = []
    for row in gold_rows + perturb_rows:
        split = row.get("split")
        row_id = row.get("id")
        prompt_text = row.get("prompt_text")
        if isinstance(split, str) and isinstance(row_id, str) and isinstance(prompt_text, str):
            jq_entries.append((split, row_id, norm_text(prompt_text)))
    for (s1, id1, t1), (s2, id2, t2) in combinations(jq_entries, 2):
        if s1 == s2:
            continue
        if s1 not in JUDGE_SPLITS or s2 not in JUDGE_SPLITS:
            continue
        if not t1 or not t2:
            continue
        sim = jaccard(char_ngrams(t1), char_ngrams(t2))
        if sim >= near_duplicate_threshold:
            message = (
                "judge_quality: near-duplicate prompt_text across splits: "
                f"{s1}:{id1} vs {s2}:{id2} (jaccard={sim:.3f})"
            )
            if fail_on_near_duplicate:
                errors.append(message)
            else:
                warnings.append(message)

    result.update(
        {
            "gold_prompts": len(gold_rows),
            "perturbations": len(perturb_rows),
            "pairwise_labels": len(pair_rows),
            "lock_eligible_gold": len(lock_eligible),
            "krippendorff_alpha_lock_eligible": round(alpha, 6),
            "natural_negative_ratio": round(natural_ratio, 6),
            "language_tags": sorted({str(row.get("language_tag", "")) for row in all_rows}),
            "counts_by_family_gold": counts_by_family,
        }
    )
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description="Check dataset split integrity and leakage")
    ap.add_argument("--datasets-root", default="bench/prompt_eval/datasets")
    ap.add_argument("--near-duplicate-threshold", type=float, default=0.92)
    ap.add_argument(
        "--allow-unsigned-manifest-signature",
        action="store_true",
        help="Local-dev override: allow missing/invalid required detached manifest signature checks.",
    )
    ap.add_argument(
        "--fail-on-near-duplicate",
        action="store_true",
        help="Treat cross-split near-duplicate prompt_text hits as errors (fail-closed).",
    )
    ap.add_argument(
        "--strict-pairwise-linkage",
        action="store_true",
        help="Enforce pairwise candidate text linkage against parent+perturbation rows when perturbation_id is present.",
    )
    args = ap.parse_args()

    root = pathlib.Path(args.datasets_root).resolve()

    by_split: dict[str, list[dict[str, Any]]] = {}
    for split in SPLITS:
        split_dir = root / split
        rows: list[dict[str, Any]] = []
        if split_dir.exists():
            # Enforce canonical split inputs to avoid duplicate-id noise from
            # auxiliary benchmark files (e.g. pilot_cases.jsonl).
            canonical_files: list[pathlib.Path] = []
            if split == "calibration":
                calibration_globs = [
                    "judge_pairs*.jsonl",
                    "shadow_spotcheck_pairs*.jsonl",
                    "gold_anchor_pairs*.jsonl",
                    "judge_triads*.jsonl",
                ]
                seen: set[pathlib.Path] = set()
                for pattern in calibration_globs:
                    for file in sorted(split_dir.glob(pattern)):
                        if "_balanced" in file.stem:
                            continue
                        if file not in seen:
                            canonical_files.append(file)
                            seen.add(file)
                if not canonical_files:
                    canonical_files = sorted(split_dir.glob("*.jsonl"))
            else:
                candidate = split_dir / "cases.jsonl"
                if candidate.exists():
                    canonical_files = [candidate]
                else:
                    canonical_files = sorted(split_dir.glob("*.jsonl"))

            for file in canonical_files:
                rows.extend(load_jsonl(file))
        by_split[split] = rows

    errors: list[str] = []
    warnings: list[str] = []

    # Missing IDs or duplicate IDs within split
    id_index_global: dict[str, str] = {}
    for split, rows in by_split.items():
        local_seen: set[str] = set()
        for row in rows:
            rid = row.get("id")
            if not isinstance(rid, str) or not rid:
                errors.append(f"{split}: row missing non-empty 'id'")
                continue
            if rid in local_seen:
                errors.append(f"{split}: duplicate id in same split: {rid}")
            local_seen.add(rid)
            if rid in id_index_global and id_index_global[rid] != split:
                errors.append(f"cross-split duplicate id '{rid}' in {id_index_global[rid]} and {split}")
            else:
                id_index_global[rid] = split

    # Near-duplicate prompt text across split boundaries
    entries: list[tuple[str, str, str]] = []  # (split,id,norm_prompt)
    for split, rows in by_split.items():
        for row in rows:
            rid = row.get("id")
            txt = row.get("draft_prompt")
            if isinstance(rid, str) and isinstance(txt, str):
                entries.append((split, rid, norm_text(txt)))

    for (s1, id1, t1), (s2, id2, t2) in combinations(entries, 2):
        if s1 == s2:
            continue
        if not t1 or not t2:
            continue
        sim = jaccard(char_ngrams(t1), char_ngrams(t2))
        if sim >= args.near_duplicate_threshold:
            warnings.append(f"near-duplicate text across splits: {s1}:{id1} vs {s2}:{id2} (jaccard={sim:.3f})")

    counts = {k: len(v) for k, v in by_split.items()}
    judge_quality = validate_judge_quality(
        root,
        near_duplicate_threshold=args.near_duplicate_threshold,
        fail_on_near_duplicate=bool(args.fail_on_near_duplicate),
        strict_pairwise_linkage=bool(args.strict_pairwise_linkage),
        allow_unsigned_manifest_signature=bool(args.allow_unsigned_manifest_signature),
        errors=errors,
        warnings=warnings,
    )
    out = {
        "ok": len(errors) == 0,
        "counts_by_split": counts,
        "judge_quality": judge_quality,
        "error_count": len(errors),
        "warning_count": len(warnings),
        "errors": errors,
        "warnings": warnings,
    }
    print(json.dumps(out, indent=2, ensure_ascii=False))
    return 0 if not errors else 2


if __name__ == "__main__":
    raise SystemExit(main())
