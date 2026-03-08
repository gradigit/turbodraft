#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import importlib.util
import json
import os
import pathlib
import sys
from collections import Counter
from typing import Any


REPO = pathlib.Path(__file__).resolve().parents[3]
BUILD_SCRIPT = REPO / "bench/prompt_eval/tools/build_judge_quality_dataset.py"


def load_build_module():
    spec = importlib.util.spec_from_file_location("build_judge_quality_dataset_import_mod", str(BUILD_SCRIPT))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load build helper module from {BUILD_SCRIPT}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


BUILD = load_build_module()
MANIFEST_SIGNATURE_SECRET_ENV = BUILD.MANIFEST_SIGNATURE_SECRET_ENV
BREAK_GLASS_TOKEN_HASH_ENV = BUILD.BREAK_GLASS_TOKEN_HASH_ENV
JUDGE_SPLITS = tuple(BUILD.SPLITS)
DEFAULT_OUT_DIR = REPO / "bench/prompt_eval/datasets_human/judge_quality"
DEFAULT_GATE_MANIFEST = REPO / "bench/prompt_eval/config/gate_manifest.v1.json"
DEFAULT_SPLIT_SEED = int(BUILD.DEFAULT_SPLIT_SEED)
DEFAULT_SPLIT_LOCKED_AT = str(BUILD.DEFAULT_SPLIT_LOCKED_AT)
DEFAULT_ALPHA_THRESHOLD = float(BUILD.DEFAULT_ALPHA_THRESHOLD)
DEFAULT_NATURAL_NEGATIVE_RATIO_MIN = float(BUILD.DEFAULT_NATURAL_NEGATIVE_RATIO_MIN)
HUMAN_LABEL_SOURCE_CLASS = "human_adjudicated"


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def iter_jsonl(path: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def load_source_rows(path: pathlib.Path) -> list[dict[str, Any]]:
    suffix = path.suffix.lower()
    if suffix == ".jsonl":
        return iter_jsonl(path)
    if suffix == ".json":
        payload = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(payload, list):
            return [dict(row) for row in payload]
        if isinstance(payload, dict) and isinstance(payload.get("rows"), list):
            return [dict(row) for row in payload["rows"]]
        raise RuntimeError(f"{path}: .json source must be a list or {{\"rows\": [...]}}")
    if suffix == ".csv":
        with path.open("r", encoding="utf-8", newline="") as fh:
            reader = csv.DictReader(fh)
            return [dict(row) for row in reader]
    raise RuntimeError(f"{path}: unsupported source format (expected .jsonl, .json, or .csv)")


def parse_bool(value: Any, *, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"1", "true", "yes", "y"}:
            return True
        if lowered in {"0", "false", "no", "n", ""}:
            return False
    raise RuntimeError(f"invalid boolean value: {value!r}")


def parse_int(value: Any, *, default: int | None = None) -> int:
    if value is None or value == "":
        if default is None:
            raise RuntimeError("missing integer value")
        return default
    if isinstance(value, bool):
        raise RuntimeError(f"invalid integer value: {value!r}")
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        if value.is_integer():
            return int(value)
        raise RuntimeError(f"invalid integer value: {value!r}")
    if isinstance(value, str):
        return int(value.strip())
    raise RuntimeError(f"invalid integer value: {value!r}")


def parse_float(value: Any, *, default: float | None = None) -> float:
    if value is None or value == "":
        if default is None:
            raise RuntimeError("missing numeric value")
        return default
    if isinstance(value, bool):
        raise RuntimeError(f"invalid numeric value: {value!r}")
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        return float(value.strip())
    raise RuntimeError(f"invalid numeric value: {value!r}")


def parse_listish(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, tuple):
        return list(value)
    if isinstance(value, str):
        raw = value.strip()
        if not raw:
            return []
        if raw.startswith("["):
            payload = json.loads(raw)
            if not isinstance(payload, list):
                raise RuntimeError(f"expected JSON list, got {type(payload).__name__}")
            return payload
        if "|" in raw:
            return [part.strip() for part in raw.split("|") if part.strip()]
        if "," in raw:
            return [part.strip() for part in raw.split(",") if part.strip()]
        return [raw]
    raise RuntimeError(f"invalid list-like value: {value!r}")


def normalize_source_rows(source_paths: list[pathlib.Path]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in source_paths:
        for row in load_source_rows(path):
            if not isinstance(row, dict):
                raise RuntimeError(f"{path}: every row must be an object/dict")
            rows.append(dict(row))
    if not rows:
        raise RuntimeError("no source rows found")
    return rows


def normalize_row(
    row: dict[str, Any],
    *,
    repo: pathlib.Path,
    split_seed: int,
    split_locked_at: str,
    default_language_source: str,
    default_provenance_source: str | None,
    default_provenance_artifact: str | None,
    default_provenance_commit: str | None,
) -> dict[str, Any]:
    row_id = str(row.get("id") or "").strip()
    if not row_id:
        raise RuntimeError("row missing non-empty id")
    item_type = str(row.get("item_type") or "").strip()
    if item_type not in {"gold", "perturbation", "pairwise"}:
        raise RuntimeError(f"{row_id}: item_type must be gold|perturbation|pairwise")
    preset_family = str(row.get("preset_family") or "").strip()
    if not preset_family:
        raise RuntimeError(f"{row_id}: preset_family must be non-empty")
    language_tag = str(row.get("language_tag") or "").strip()
    if not language_tag or not BUILD.bcp47_like(language_tag):
        raise RuntimeError(f"{row_id}: language_tag must be valid BCP47-like tag")
    split = str(row.get("split") or "").strip()
    if split not in JUDGE_SPLITS:
        raise RuntimeError(f"{row_id}: split must be one of {', '.join(JUDGE_SPLITS)}")

    label_source_class = str(row.get("label_source_class") or HUMAN_LABEL_SOURCE_CLASS).strip()
    if label_source_class != HUMAN_LABEL_SOURCE_CLASS:
        raise RuntimeError(f"{row_id}: label_source_class must be {HUMAN_LABEL_SOURCE_CLASS!r}")

    provenance_source = str(row.get("provenance_source") or default_provenance_source or "").strip()
    provenance_artifact = str(row.get("provenance_artifact") or default_provenance_artifact or "").strip()
    provenance_commit = str(row.get("provenance_commit") or default_provenance_commit or BUILD.git_commit(repo)).strip()
    if not provenance_source:
        raise RuntimeError(f"{row_id}: provenance_source missing")
    if not provenance_artifact:
        raise RuntimeError(f"{row_id}: provenance_artifact missing")
    if not provenance_commit:
        raise RuntimeError(f"{row_id}: provenance_commit missing")

    parent_prompt_id_raw = row.get("parent_prompt_id")
    if item_type == "gold":
        parent_prompt_id = None
    else:
        parent_prompt_id = str(parent_prompt_id_raw or "").strip()
        if not parent_prompt_id:
            raise RuntimeError(f"{row_id}: parent_prompt_id required for {item_type}")

    blinded_ratings = [parse_float(v) for v in parse_listish(row.get("blinded_ratings"))]
    rater_ids = [str(v).strip() for v in parse_listish(row.get("rater_ids_hashed")) if str(v).strip()]
    if "rater_count" in row and row.get("rater_count") not in (None, ""):
        rater_count = parse_int(row.get("rater_count"))
    elif rater_ids:
        rater_count = len(rater_ids)
    elif blinded_ratings:
        rater_count = len(blinded_ratings)
    else:
        rater_count = 0
    if rater_count < 0:
        raise RuntimeError(f"{row_id}: rater_count must be >= 0")
    if not rater_ids and rater_count > 0:
        rater_ids = [BUILD.stable_sha256(f"{row_id}:rater:{idx + 1}") for idx in range(rater_count)]
    if rater_ids and len(rater_ids) != rater_count:
        raise RuntimeError(f"{row_id}: rater_ids_hashed length must equal rater_count")

    normalized: dict[str, Any] = {
        "id": row_id,
        "preset_family": preset_family,
        "item_type": item_type,
        "language_tag": language_tag,
        "language_source": str(row.get("language_source") or default_language_source).strip() or "imported_human",
        "split": split,
        "split_seed": parse_int(row.get("split_seed"), default=split_seed),
        "split_locked_at": str(row.get("split_locked_at") or split_locked_at).strip(),
        "parent_prompt_id": parent_prompt_id,
        "blinded_item_id": str(row.get("blinded_item_id") or f"blind_{BUILD.stable_sha256(row_id)[:16]}").strip(),
        "blind_round": parse_int(row.get("blind_round"), default=1),
        "sealed_open_count": parse_int(row.get("sealed_open_count"), default=0),
        "expected_relation": row.get("expected_relation"),
        "absolute_score_0_100": None,
        "error_tags": [str(v).strip() for v in parse_listish(row.get("error_tags")) if str(v).strip()],
        "adjudication_status": str(row.get("adjudication_status") or "adjudicated").strip(),
        "rater_count": rater_count,
        "rater_ids_hashed": rater_ids,
        "blinded_ratings": blinded_ratings,
        "provenance_source": provenance_source,
        "provenance_artifact": provenance_artifact,
        "provenance_commit": provenance_commit,
        "label_source_class": label_source_class,
        "negative_origin": str(row.get("negative_origin") or "natural").strip(),
        "perturbation_template_id": row.get("perturbation_template_id"),
        "hard_negative": parse_bool(row.get("hard_negative"), default=False),
    }
    if isinstance(row.get("review_metadata"), dict):
        normalized["review_metadata"] = dict(row["review_metadata"])

    if normalized["adjudication_status"] not in {"pending", "adjudicated", "excluded"}:
        raise RuntimeError(f"{row_id}: adjudication_status must be pending|adjudicated|excluded")

    if item_type in {"gold", "perturbation"}:
        prompt_text = str(row.get("prompt_text") or "").strip()
        if not prompt_text:
            raise RuntimeError(f"{row_id}: prompt_text required for {item_type}")
        normalized["prompt_text"] = prompt_text
        normalized["text_sha256"] = BUILD.stable_sha256(prompt_text)
        normalized["absolute_score_0_100"] = parse_float(row.get("absolute_score_0_100"))
        if item_type == "gold":
            normalized["expected_relation"] = None
            normalized["negative_origin"] = "natural"
            normalized["perturbation_template_id"] = None
            normalized["hard_negative"] = False
        else:
            normalized["expected_relation"] = (
                str(row.get("expected_relation") or "worse_than_parent").strip() or "worse_than_parent"
            )
    else:
        candidate_a = str(row.get("candidate_a") or "").strip()
        candidate_b = str(row.get("candidate_b") or "").strip()
        if not candidate_a or not candidate_b:
            raise RuntimeError(f"{row_id}: candidate_a and candidate_b required for pairwise rows")
        expected_winner = str(row.get("expected_winner") or "").strip()
        if expected_winner and expected_winner not in {"A", "B", "Tie"}:
            raise RuntimeError(f"{row_id}: expected_winner must be A|B|Tie when present")
        normalized["draft_prompt"] = str(row.get("draft_prompt") or "").strip()
        normalized["candidate_a"] = candidate_a
        normalized["candidate_b"] = candidate_b
        normalized["candidate_a_source"] = str(row.get("candidate_a_source") or "").strip() or None
        normalized["candidate_b_source"] = str(row.get("candidate_b_source") or "").strip() or None
        normalized["candidate_a_text_sha256"] = BUILD.stable_sha256(candidate_a)
        normalized["candidate_b_text_sha256"] = BUILD.stable_sha256(candidate_b)
        normalized["perturbation_id"] = str(row.get("perturbation_id") or "").strip() or None
        normalized["expected_winner"] = expected_winner or None
        if not normalized["expected_relation"]:
            if expected_winner == "A":
                normalized["expected_relation"] = "A>B"
            elif expected_winner == "B":
                normalized["expected_relation"] = "B>A"
            elif expected_winner == "Tie":
                normalized["expected_relation"] = "A=B"
            else:
                normalized["expected_relation"] = None
        normalized["text_sha256"] = BUILD.stable_hash_object({"a": candidate_a, "b": candidate_b, "id": row_id})

    return normalized


def finalize_pairwise_rows(
    rows: list[dict[str, Any]],
) -> None:
    gold_by_id = {str(row["id"]): row for row in rows if row.get("item_type") == "gold"}
    perturb_by_id = {str(row["id"]): row for row in rows if row.get("item_type") == "perturbation"}

    for row in rows:
        if row.get("item_type") != "pairwise":
            continue
        row_id = str(row.get("id"))
        parent_id = str(row.get("parent_prompt_id") or "")
        parent = gold_by_id.get(parent_id)
        if parent is None:
            raise RuntimeError(f"{row_id}: pairwise parent_prompt_id not found in gold rows")
        if not row.get("draft_prompt"):
            row["draft_prompt"] = str(parent.get("prompt_text") or "")

        perturb = None
        perturb_id = row.get("perturbation_id")
        if isinstance(perturb_id, str) and perturb_id:
            perturb = perturb_by_id.get(perturb_id)
            if perturb is None:
                raise RuntimeError(f"{row_id}: perturbation_id not found: {perturb_id}")

        parent_text = str(parent.get("prompt_text") or "")
        a_text = str(row.get("candidate_a") or "")
        b_text = str(row.get("candidate_b") or "")

        if perturb is not None:
            perturb_text = str(perturb.get("prompt_text") or "")
            if not row.get("candidate_a_source") and not row.get("candidate_b_source"):
                if a_text == parent_text and b_text == perturb_text:
                    row["candidate_a_source"] = "gold"
                    row["candidate_b_source"] = "perturbation"
                elif b_text == parent_text and a_text == perturb_text:
                    row["candidate_a_source"] = "perturbation"
                    row["candidate_b_source"] = "gold"
            if not row.get("expected_winner"):
                if row.get("candidate_a_source") == "gold":
                    row["expected_winner"] = "A"
                elif row.get("candidate_b_source") == "gold":
                    row["expected_winner"] = "B"
            if not row.get("expected_relation"):
                if row.get("expected_winner") == "A":
                    row["expected_relation"] = "A>B"
                elif row.get("expected_winner") == "B":
                    row["expected_relation"] = "B>A"
                elif row.get("expected_winner") == "Tie":
                    row["expected_relation"] = "A=B"


def build_manifest(
    *,
    repo: pathlib.Path,
    gate_manifest_path: pathlib.Path,
    rows: list[dict[str, Any]],
    split_seed: int,
    split_locked_at: str,
    alpha_threshold: float,
    natural_negative_ratio_min: float,
) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    gate = load_json(gate_manifest_path)
    required_family_allowlist: list[str] = list(gate.get("required_preset_families") or [])

    gold_rows = sorted([row for row in rows if row.get("item_type") == "gold"], key=lambda row: str(row["id"]))
    perturb_rows = sorted([row for row in rows if row.get("item_type") == "perturbation"], key=lambda row: str(row["id"]))
    pair_rows = sorted([row for row in rows if row.get("item_type") == "pairwise"], key=lambda row: str(row["id"]))
    if not gold_rows or not perturb_rows or not pair_rows:
        raise RuntimeError("import requires gold, perturbation, and pairwise rows")

    row_ids = [str(row["id"]) for row in rows]
    if len(set(row_ids)) != len(row_ids):
        dupes = [row_id for row_id, count in Counter(row_ids).items() if count > 1]
        raise RuntimeError(f"duplicate ids in source rows: {', '.join(sorted(dupes)[:10])}")

    families = sorted({str(row.get("preset_family") or "") for row in gold_rows})
    if not families:
        raise RuntimeError("no gold preset families found")
    invalid_families = [family for family in families if not family]
    if invalid_families:
        raise RuntimeError("gold rows contain empty preset_family")
    if required_family_allowlist:
        unknown = [family for family in families if family not in required_family_allowlist]
        if unknown:
            raise RuntimeError(f"source contains preset families outside gate allowlist: {', '.join(sorted(unknown))}")

    lock_eligible_rows: list[dict[str, Any]] = []
    for row in gold_rows:
        result = BUILD.evaluate_lock_eligible(row)
        if not result.computable:
            raise RuntimeError(f"{row['id']}: lock-eligible predicate not computable ({result.reason})")
        if result.is_lock_eligible:
            if int(row.get("rater_count", 0)) < 3:
                raise RuntimeError(f"{row['id']}: lock-eligible gold row has rater_count < 3")
            ratings = row.get("blinded_ratings")
            if not isinstance(ratings, list) or len(ratings) < 2:
                raise RuntimeError(f"{row['id']}: lock-eligible gold row missing blinded_ratings")
            lock_eligible_rows.append(row)
    if not lock_eligible_rows:
        raise RuntimeError("no lock-eligible gold rows found in import")

    alpha = BUILD.krippendorff_alpha_interval(
        [list(row.get("blinded_ratings", [])) for row in lock_eligible_rows],
    )
    if alpha < alpha_threshold:
        raise RuntimeError(f"lock-eligible alpha gate failed: alpha={alpha:.6f} < {alpha_threshold}")

    natural_total = sum(1 for row in perturb_rows if row.get("negative_origin") == "natural")
    synthetic_total = sum(1 for row in perturb_rows if row.get("negative_origin") == "synthetic")
    invalid_origins = sorted(
        {str(row.get("negative_origin")) for row in perturb_rows if row.get("negative_origin") not in {"natural", "synthetic"}}
    )
    if invalid_origins:
        raise RuntimeError(f"invalid negative_origin values: {', '.join(invalid_origins)}")
    neg_total = natural_total + synthetic_total
    if neg_total <= 0:
        raise RuntimeError("no perturbation rows found for natural/synthetic ratio")
    natural_ratio = natural_total / neg_total
    if natural_ratio < natural_negative_ratio_min:
        raise RuntimeError(
            f"natural-negative ratio gate failed: ratio={natural_ratio:.6f} < {natural_negative_ratio_min}"
        )

    family_split_counts: dict[str, dict[str, int]] = {}
    family_negative_counts: dict[str, dict[str, int]] = {}
    family_hard_negative_counts: dict[str, int] = {}
    for family in families:
        counts = {split: 0 for split in JUDGE_SPLITS}
        for row in gold_rows:
            if row.get("preset_family") == family:
                counts[str(row.get("split"))] += 1
        family_split_counts[family] = counts
        family_negative_counts[family] = {
            "natural": sum(1 for row in perturb_rows if row.get("preset_family") == family and row.get("negative_origin") == "natural"),
            "synthetic": sum(1 for row in perturb_rows if row.get("preset_family") == family and row.get("negative_origin") == "synthetic"),
        }
        family_hard_negative_counts[family] = sum(
            1 for row in perturb_rows if row.get("preset_family") == family and bool(row.get("hard_negative"))
        )
        if family_hard_negative_counts[family] < 1:
            raise RuntimeError(f"{family}: hard-negative coverage failed (count=0)")

    manifest_families: dict[str, Any] = {}
    for family in families:
        counts = family_split_counts[family]
        total = max(1, sum(counts.values()))
        ratios = {split: counts.get(split, 0) / total for split in JUDGE_SPLITS}
        negative_counts = family_negative_counts[family]
        neg_total = max(1, negative_counts["natural"] + negative_counts["synthetic"])
        manifest_families[family] = {
            "gold_counts_by_split": counts,
            "gold_ratios_by_split": {split: round(ratios[split], 6) for split in JUDGE_SPLITS},
            "split_floor_ok": all(counts.get(split, 0) >= 1 for split in JUDGE_SPLITS),
            "split_ratio_ok": True,
            "negative_counts": negative_counts,
            "natural_negative_ratio": round(negative_counts["natural"] / neg_total, 6),
            "hard_negative_count": family_hard_negative_counts[family],
        }

    language_tags = sorted({str(row.get("language_tag") or "") for row in rows})
    if any((not tag or not BUILD.bcp47_like(tag)) for tag in language_tags):
        raise RuntimeError("import rows contain invalid language_tag values")

    trusted_break_glass_token_hash = os.getenv(BREAK_GLASS_TOKEN_HASH_ENV, "").strip() or None
    manifest_core = {
        "version": "v1",
        "dataset_family": "judge_quality",
        "generated_at": BUILD.utc_now_iso(),
        "imported_human_dataset": True,
        "import_sources": [],
        "split_seed": split_seed,
        "split_locked_at": split_locked_at,
        "split_validation_mode": "exact_per_family",
        "target_ratios_by_family": {split: 0.0 for split in JUDGE_SPLITS},
        "ratio_tolerance": 0.0,
        "min_counts_per_split_per_family": {split: 0 for split in JUDGE_SPLITS},
        "template_holdout_for_lock": [],
        "lock_eligible_predicate": {
            "item_type": "gold",
            "adjudication_status": "adjudicated",
            "rater_count_min": 3,
            "error_tags_required_field": True,
            "absolute_score_0_100_range": [0, 100],
            "allowed_splits": list(JUDGE_SPLITS),
            "exclude_adjudication_statuses": ["pending", "excluded"],
        },
        "quality_gates": {
            "krippendorff_alpha_min": alpha_threshold,
            "natural_negative_ratio_min": natural_negative_ratio_min,
        },
        "governance": {
            "sealed_open_count": 0,
            "sealed_opened_at": None,
            "sealed_open_reason": None,
            "break_glass_used": False,
            "break_glass_token_hash": None,
            "trusted_break_glass_token_hash": trusted_break_glass_token_hash,
            "sealed_export_audit_log": [],
        },
        "families": manifest_families,
        "dataset_stats": {
            "gold_prompts": len(gold_rows),
            "perturbations": len(perturb_rows),
            "pairwise_labels": len(pair_rows),
            "lock_eligible_gold": len(lock_eligible_rows),
            "krippendorff_alpha_lock_eligible": round(alpha, 6),
            "natural_negative_ratio": round(natural_ratio, 6),
            "language_tags": language_tags,
            "source_row_count": len(rows),
        },
        "provenance_source_class_required": HUMAN_LABEL_SOURCE_CLASS,
        "import_commit": BUILD.git_commit(repo),
    }
    return manifest_core, gold_rows, perturb_rows, pair_rows


def write_dataset(
    *,
    out_dir: pathlib.Path,
    manifest_core: dict[str, Any],
    gold_rows: list[dict[str, Any]],
    perturb_rows: list[dict[str, Any]],
    pair_rows: list[dict[str, Any]],
    allow_unsigned_manifest_signature: bool,
) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)
    BUILD.write_jsonl(out_dir / "gold_prompts.jsonl", gold_rows)
    BUILD.write_jsonl(out_dir / "perturbations.jsonl", perturb_rows)
    BUILD.write_jsonl(out_dir / "pairwise_labels.jsonl", pair_rows)

    signing_secret = os.getenv(MANIFEST_SIGNATURE_SECRET_ENV, "").strip()
    if not signing_secret and not allow_unsigned_manifest_signature:
        raise RuntimeError(
            "detached manifest signature is required for judge_quality datasets; "
            f"set {MANIFEST_SIGNATURE_SECRET_ENV} (or pass --allow-unsigned-manifest-signature for local-dev only)"
        )

    detached_payload = BUILD.build_detached_manifest_payload(
        manifest_core=manifest_core,
        gold_rows=gold_rows,
        perturb_rows=perturb_rows,
        pair_rows=pair_rows,
    )
    detached_signature_required = bool(signing_secret)
    detached_signature = BUILD.sign_manifest_payload(signing_secret, detached_payload) if signing_secret else None
    manifest = dict(manifest_core)
    manifest["integrity"] = {
        "detached_manifest_signature": {
            "algorithm": "hmac-sha256",
            "secret_env": MANIFEST_SIGNATURE_SECRET_ENV,
            "required": detached_signature_required,
            "payload_sha256": BUILD.stable_hash_object(detached_payload),
            "signature": detached_signature,
            "signed_at": BUILD.utc_now_iso() if detached_signature else None,
            "unsigned_override_used": bool(allow_unsigned_manifest_signature and not signing_secret),
        }
    }
    BUILD.write_json(out_dir / "split_manifest.v1.json", manifest)
    return manifest


def main() -> int:
    ap = argparse.ArgumentParser(description="Import human-adjudicated judge_quality dataset rows into canonical artifacts.")
    ap.add_argument("--repo", default=str(REPO))
    ap.add_argument("--gate-manifest", default=str(DEFAULT_GATE_MANIFEST))
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR))
    ap.add_argument("--source", action="append", required=True, help="Source file (.jsonl, .json, or .csv). May be repeated.")
    ap.add_argument("--split-seed", type=int, default=DEFAULT_SPLIT_SEED)
    ap.add_argument("--split-locked-at", default=DEFAULT_SPLIT_LOCKED_AT)
    ap.add_argument("--alpha-threshold", type=float, default=DEFAULT_ALPHA_THRESHOLD)
    ap.add_argument("--natural-negative-ratio-min", type=float, default=DEFAULT_NATURAL_NEGATIVE_RATIO_MIN)
    ap.add_argument("--default-language-source", default="imported_human")
    ap.add_argument("--default-provenance-source")
    ap.add_argument("--default-provenance-artifact")
    ap.add_argument("--default-provenance-commit")
    ap.add_argument(
        "--allow-unsigned-manifest-signature",
        action="store_true",
        help="Local-dev override: allow unsigned detached manifest signature (not for lock/promotion artifacts).",
    )
    args = ap.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    gate_manifest = pathlib.Path(args.gate_manifest).resolve()
    out_dir = pathlib.Path(args.out_dir).resolve()
    source_paths = [pathlib.Path(raw).resolve() for raw in args.source]

    rows = [
        normalize_row(
            row,
            repo=repo,
            split_seed=int(args.split_seed),
            split_locked_at=str(args.split_locked_at),
            default_language_source=str(args.default_language_source),
            default_provenance_source=args.default_provenance_source,
            default_provenance_artifact=args.default_provenance_artifact,
            default_provenance_commit=args.default_provenance_commit,
        )
        for row in normalize_source_rows(source_paths)
    ]
    finalize_pairwise_rows(rows)
    manifest_core, gold_rows, perturb_rows, pair_rows = build_manifest(
        repo=repo,
        gate_manifest_path=gate_manifest,
        rows=rows,
        split_seed=int(args.split_seed),
        split_locked_at=str(args.split_locked_at),
        alpha_threshold=float(args.alpha_threshold),
        natural_negative_ratio_min=float(args.natural_negative_ratio_min),
    )
    manifest_core["import_sources"] = [str(path) for path in source_paths]
    manifest = write_dataset(
        out_dir=out_dir,
        manifest_core=manifest_core,
        gold_rows=gold_rows,
        perturb_rows=perturb_rows,
        pair_rows=pair_rows,
        allow_unsigned_manifest_signature=bool(args.allow_unsigned_manifest_signature),
    )
    result = {
        "ok": True,
        "out_dir": str(out_dir),
        "gold_prompts": len(gold_rows),
        "perturbations": len(perturb_rows),
        "pairwise_labels": len(pair_rows),
        "lock_eligible_gold": int(manifest["dataset_stats"]["lock_eligible_gold"]),
        "krippendorff_alpha_lock_eligible": float(manifest["dataset_stats"]["krippendorff_alpha_lock_eligible"]),
        "natural_negative_ratio": float(manifest["dataset_stats"]["natural_negative_ratio"]),
        "split_validation_mode": str(manifest.get("split_validation_mode") or ""),
        "families": sorted(manifest.get("families", {}).keys()) if isinstance(manifest.get("families"), dict) else [],
        "sources": [str(path) for path in source_paths],
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
