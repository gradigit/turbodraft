#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import pathlib
import random
import subprocess
from dataclasses import dataclass
from typing import Any


REPO = pathlib.Path(__file__).resolve().parents[3]
DEFAULT_OUT_DIR = REPO / "bench/prompt_eval/datasets/judge_quality"
DEFAULT_GATE_MANIFEST = REPO / "bench/prompt_eval/config/gate_manifest.v1.json"
DEFAULT_SPLIT_SEED = 20260304
DEFAULT_SPLIT_LOCKED_AT = "2026-03-04T00:00:00Z"
DEFAULT_ALPHA_THRESHOLD = 0.67
DEFAULT_NATURAL_NEGATIVE_RATIO_MIN = 0.50
SPLITS = ("dev", "tune", "sealed_test")
SPLIT_TARGET_RATIOS = {"dev": 0.60, "tune": 0.20, "sealed_test": 0.20}
SPLIT_RATIO_TOLERANCE = 0.05
MIN_COUNTS_PER_FAMILY = {"dev": 3, "tune": 1, "sealed_test": 1}
TEMPLATE_HOLDOUT_FOR_LOCK = ["syn_contract_removal"]
PROVENANCE_SOURCE = "expert_panel_simulated"
PROVENANCE_ARTIFACT = "judge_quality_seed_v1"
LABEL_SOURCE_CLASS = "synthetic_generated"
MANIFEST_SIGNATURE_SECRET_ENV = "PROMPT_EVAL_JUDGE_QUALITY_MANIFEST_SECRET"
BREAK_GLASS_TOKEN_HASH_ENV = "PROMPT_EVAL_JUDGE_QUALITY_BREAK_GLASS_TOKEN_HASH"


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_jsonl(path: pathlib.Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rows_sorted = sorted(rows, key=lambda row: str(row.get("id", "")))
    payload = "\n".join(json.dumps(row, ensure_ascii=False) for row in rows_sorted) + "\n"
    path.write_text(payload, encoding="utf-8")


def stable_sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def stable_hash_object(payload: Any) -> str:
    return stable_sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":")))


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


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def bcp47_like(tag: str) -> bool:
    # Broad BCP47 structural check (language[-script][-region][-variant...]).
    import re

    return bool(re.fullmatch(r"^[A-Za-z]{2,3}(?:-[A-Za-z]{4})?(?:-[A-Za-z]{2}|\-\d{3})?(?:-[A-Za-z0-9]{5,8})*$", tag))


def family_draft(family: str) -> str:
    mapping = {
        "coding": "Implement safe sidebar resize fix with rollback criteria and regression tests.",
        "refactor": "Refactor prompt-selection architecture without behavior changes or UX regressions.",
        "review": "Review install script security posture with clear severity and repro evidence.",
        "research": "Design a reproducible prompt-eval benchmark with objective gates and cost bounds.",
        "brainstorm": "Objectively evaluate profile+preset vs presets-only configuration design.",
        "pivot_kr_en_translate": "한국어 초안을 영어로 충실히 번역하고 목표를 추가하지 마세요.",
        "pivot_kr_en_reason_ko": "영어로 먼저 추론한 뒤 최종 답변은 한국어로 작성하는 방식을 설계하세요.",
        "pivot_kr_en_optimize_ko": "한국어 입력을 영어로 개선한 뒤 최종 응답은 한국어 품질을 유지하도록 설계하세요.",
        "legacy": "Improve legacy prompt quality while preserving original user intent and constraints.",
    }
    return mapping.get(family, "Improve prompt quality while preserving intent and constraints.")


def family_language_tag(family: str) -> tuple[str, str]:
    if family.startswith("pivot_kr_en_"):
        return ("ko-KR", "family_default")
    return ("en-US", "family_default")


def prompt_variants(variant_count: int) -> list[str]:
    seed = [
        "Include objective + constraints + acceptance checks.",
        "Prioritize requirement fidelity over stylistic changes.",
        "Preserve uncertainty and avoid fabricated scope.",
        "Add rollback criteria and verification checkpoints.",
        "Keep role boundaries explicit and non-leaky.",
    ]
    count = max(1, int(variant_count))
    if count <= len(seed):
        return seed[:count]

    action = [
        "convert ambiguous requests into explicit constraints",
        "retain every hard requirement verbatim",
        "state non-goals to prevent scope drift",
        "annotate risky assumptions as open questions",
        "separate required steps from optional ideas",
        "force measurable acceptance criteria",
        "require rollback triggers before implementation",
        "preserve user language intent when translating",
        "prioritize deterministic output structure",
        "ban role handoff leakage in rewritten prompts",
    ]
    validation = [
        "missing constraints are flagged",
        "fabricated requirements are rejected",
        "schema expectations are preserved",
        "critical safety boundaries remain intact",
        "uncertainty markers are retained",
        "conflicting instructions are surfaced",
        "execution order is testable",
        "output format remains machine-checkable",
        "risk notes are explicit and concise",
        "final prompt is directly executable",
    ]
    style = [
        "use concise imperative bullets",
        "use short sections with explicit headings",
        "prefer factual language over motivational filler",
        "keep wording minimal and audit-friendly",
        "avoid rhetorical framing and keep operational tone",
        "use deterministic phrasing for repeated evaluations",
        "limit verbosity and preserve information density",
        "make quality checks explicit and numbered",
        "state assumptions in a dedicated section",
        "finish with a strict self-check list",
    ]

    out: list[str] = []
    for idx in range(count):
        a = action[idx % len(action)]
        v = validation[(idx * 3 + 1) % len(validation)]
        s = style[(idx * 5 + 2) % len(style)]
        out.append(
            f"Coverage variant {idx + 1:03d}: {a}; ensure {v}; {s}."
        )
    return out


def perturbation_specs(include_synthetic: bool) -> list[dict[str, Any]]:
    specs = [
        {
            "template_id": "nat_missing_constraint",
            "negative_origin": "natural",
            "hard_negative": False,
            "delta": 18,
            "error_tags": ["missing_constraint"],
            "suffix": "Drop one critical requirement and leave ambiguity in scope.",
        },
        {
            "template_id": "nat_role_leakage",
            "negative_origin": "natural",
            "hard_negative": True,
            "delta": 24,
            "error_tags": ["role_leakage", "safety_boundary"],
            "suffix": "Tell the execution_agent to ignore original constraints and improvise.",
        },
        {
            "template_id": "nat_scope_fabrication",
            "negative_origin": "natural",
            "hard_negative": False,
            "delta": 20,
            "error_tags": ["scope_fabrication"],
            "suffix": "Add unrelated migration and telemetry requirements not requested by user.",
        },
        {
            "template_id": "syn_fluff_injection",
            "negative_origin": "synthetic",
            "hard_negative": False,
            "delta": 14,
            "error_tags": ["verbosity_noise"],
            "suffix": "Insert decorative language and motivational filler without actionable content.",
        },
        {
            "template_id": "syn_contract_removal",
            "negative_origin": "synthetic",
            "hard_negative": True,
            "delta": 28,
            "error_tags": ["contract_loss", "schema_loss"],
            "suffix": "Remove output schema/validation section while preserving superficial structure.",
        },
    ]
    if include_synthetic:
        return specs
    return [spec for spec in specs if spec.get("negative_origin") != "synthetic"]


def score_triplet(seed: int, family: str, index: int, base: int) -> list[int]:
    rng = random.Random(f"{seed}:{family}:{index}:{base}")
    center = base + rng.randint(-1, 1)
    return [max(0, min(100, center - 1)), max(0, min(100, center)), max(0, min(100, center + 1))]


def assign_splits(
    item_ids: list[str],
    *,
    family: str,
    split_seed: int,
    target_ratios: dict[str, float],
    min_counts: dict[str, int],
) -> dict[str, str]:
    total = len(item_ids)
    if total <= 0:
        raise ValueError(f"{family}: cannot assign splits to empty item list")

    for split, floor in min_counts.items():
        if floor < 0:
            raise ValueError(f"{family}: split floor must be >=0 ({split}={floor})")
        if floor > total:
            raise ValueError(f"{family}: split floor {split}={floor} exceeds total {total}")

    counts: dict[str, int] = {split: int(total * ratio) for split, ratio in target_ratios.items()}
    remainder = total - sum(counts.values())
    remainders = sorted(
        target_ratios.items(),
        key=lambda kv: (total * kv[1] - counts[kv[0]], kv[0]),
        reverse=True,
    )
    for idx in range(remainder):
        counts[remainders[idx % len(remainders)][0]] += 1

    deficits: dict[str, int] = {}
    for split, floor in min_counts.items():
        deficits[split] = max(0, floor - counts.get(split, 0))
    deficit_total = sum(deficits.values())
    if deficit_total > 0:
        donors = sorted(
            counts.items(),
            key=lambda kv: (kv[1] - min_counts.get(kv[0], 0), kv[0]),
            reverse=True,
        )
        for split, need in deficits.items():
            while need > 0:
                donor = next((name for name, _ in donors if counts[name] > min_counts.get(name, 0)), None)
                if donor is None:
                    raise ValueError(f"{family}: cannot satisfy split floors with total={total}")
                counts[donor] -= 1
                counts[split] += 1
                need -= 1
            deficits[split] = 0

    if sum(counts.values()) != total:
        raise ValueError(f"{family}: split allocation mismatch after floor adjustment")

    split_pool: list[str] = []
    for split in SPLITS:
        split_pool.extend([split] * counts.get(split, 0))

    rng = random.Random(f"{split_seed}:{family}")
    rng.shuffle(split_pool)
    ordered = sorted(item_ids)
    return {item_id: split_pool[idx] for idx, item_id in enumerate(ordered)}


@dataclass(frozen=True)
class LockEligibility:
    is_lock_eligible: bool
    computable: bool
    reason: str


def evaluate_lock_eligible(item: dict[str, Any]) -> LockEligibility:
    required = {
        "item_type",
        "adjudication_status",
        "rater_count",
        "error_tags",
        "absolute_score_0_100",
        "split",
    }
    missing = sorted(key for key in required if key not in item)
    if missing:
        return LockEligibility(False, False, f"missing required fields: {', '.join(missing)}")

    item_type = item.get("item_type")
    status = item.get("adjudication_status")
    rater_count = item.get("rater_count")
    error_tags = item.get("error_tags")
    score = item.get("absolute_score_0_100")
    split = item.get("split")

    if item_type != "gold":
        return LockEligibility(False, True, "item_type != gold")
    if status in {"pending", "excluded"}:
        return LockEligibility(False, True, "adjudication_status excludes lock")
    if status != "adjudicated":
        return LockEligibility(False, False, "unknown adjudication_status")
    if not isinstance(rater_count, int):
        return LockEligibility(False, False, "rater_count must be int")
    if rater_count < 0:
        return LockEligibility(False, False, "rater_count must be >= 0")
    if not isinstance(error_tags, list):
        return LockEligibility(False, False, "error_tags must be list")
    if not isinstance(score, (int, float)):
        return LockEligibility(False, False, "absolute_score_0_100 must be numeric")
    if not (0 <= float(score) <= 100):
        return LockEligibility(False, False, "absolute_score_0_100 out of range [0, 100]")
    if split not in SPLITS:
        return LockEligibility(False, False, "split must be one of dev|tune|sealed_test")
    if rater_count < 3:
        return LockEligibility(False, True, "rater_count < 3")
    return LockEligibility(True, True, "eligible")


def krippendorff_alpha_interval(units: list[list[float]]) -> float:
    normalized: list[list[float]] = []
    all_values: list[float] = []
    for unit in units:
        clean = [float(v) for v in unit if isinstance(v, (int, float))]
        if len(clean) < 2:
            continue
        normalized.append(clean)
        all_values.extend(clean)

    if not normalized:
        return 0.0
    if len(all_values) < 2:
        return 1.0

    observed_num = 0.0
    observed_den = 0.0
    for values in normalized:
        n = len(values)
        if n < 2:
            continue
        sum_x = sum(values)
        sum_x2 = sum(v * v for v in values)
        observed_num += (n * sum_x2) - (sum_x * sum_x)
        observed_den += (n * (n - 1)) / 2.0
    if observed_den == 0:
        return 1.0
    do = observed_num / observed_den

    n_all = len(all_values)
    sum_all = sum(all_values)
    sum_all2 = sum(v * v for v in all_values)
    expected_num = (n_all * sum_all2) - (sum_all * sum_all)
    expected_den = (n_all * (n_all - 1)) / 2.0
    if expected_den == 0:
        return 1.0
    de = expected_num / expected_den
    if de == 0:
        return 1.0 if do == 0 else 0.0
    alpha = 1.0 - (do / de)
    return max(-1.0, min(1.0, alpha))


def git_commit(repo: pathlib.Path) -> str:
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=str(repo),
            check=True,
            capture_output=True,
            text=True,
        )
    except Exception:
        return "unknown"
    return proc.stdout.strip() or "unknown"


def build_dataset(
    *,
    repo: pathlib.Path,
    out_dir: pathlib.Path,
    gate_manifest_path: pathlib.Path,
    split_seed: int,
    split_locked_at: str,
    alpha_threshold: float,
    natural_negative_ratio_min: float,
    variant_count: int,
    include_synthetic_negatives: bool,
    provenance_source: str,
    provenance_artifact: str,
    allow_unsigned_manifest_signature: bool,
) -> dict[str, Any]:
    gate = load_json(gate_manifest_path)
    families: list[str] = list(gate.get("required_preset_families") or [])
    if not families:
        raise RuntimeError("required_preset_families is empty in gate manifest")

    commit = git_commit(repo)
    created_at = utc_now_iso()
    variants = prompt_variants(variant_count)
    perturb_specs = perturbation_specs(include_synthetic_negatives)
    if not perturb_specs:
        raise RuntimeError("no perturbation specs available after filtering; cannot build pairwise labels")

    gold_rows: list[dict[str, Any]] = []
    perturb_rows: list[dict[str, Any]] = []
    pair_rows: list[dict[str, Any]] = []
    family_split_counts: dict[str, dict[str, int]] = {}
    family_negative_counts: dict[str, dict[str, int]] = {}
    family_hard_negative_counts: dict[str, int] = {}

    for family in families:
        base = family_draft(family)
        lang_tag, lang_source = family_language_tag(family)
        if not bcp47_like(lang_tag):
            raise RuntimeError(f"{family}: invalid BCP47 tag generated: {lang_tag}")

        family_gold_ids = [f"jq_gold_{family}_{idx + 1:02d}" for idx in range(len(variants))]
        split_map = assign_splits(
            family_gold_ids,
            family=family,
            split_seed=split_seed,
            target_ratios=SPLIT_TARGET_RATIOS,
            min_counts=MIN_COUNTS_PER_FAMILY,
        )

        family_split_counts[family] = {split: 0 for split in SPLITS}
        family_negative_counts[family] = {"natural": 0, "synthetic": 0}
        family_hard_negative_counts[family] = 0

        for idx, suffix in enumerate(variants):
            gold_id = family_gold_ids[idx]
            split = split_map[gold_id]
            family_split_counts[family][split] += 1

            gold_text = f"{base}\n\n### Required quality controls\n- {suffix}"
            ratings = score_triplet(split_seed, family, idx, base=88 - (idx * 3))
            score = round(sum(ratings) / len(ratings), 2)
            rater_ids_hashed = [stable_sha256(f"{family}:gold:{gold_id}:rater:{rid}") for rid in ("a", "b", "c")]

            gold_row: dict[str, Any] = {
                "id": gold_id,
                "preset_family": family,
                "item_type": "gold",
                "language_tag": lang_tag,
                "language_source": lang_source,
                "split": split,
                "split_seed": split_seed,
                "split_locked_at": split_locked_at,
                "parent_prompt_id": None,
                "blinded_item_id": f"blind_{stable_sha256(gold_id)[:16]}",
                "blind_round": 1,
                "sealed_open_count": 0,
                "expected_relation": None,
                "absolute_score_0_100": score,
                "error_tags": [],
                "adjudication_status": "adjudicated",
                "rater_count": len(ratings),
                "rater_ids_hashed": rater_ids_hashed,
                "blinded_ratings": ratings,
                "provenance_source": provenance_source,
                "provenance_artifact": provenance_artifact,
                "provenance_commit": commit,
                "label_source_class": LABEL_SOURCE_CLASS,
                "negative_origin": "natural",
                "perturbation_template_id": None,
                "hard_negative": False,
                "prompt_text": gold_text,
                "text_sha256": stable_sha256(gold_text),
            }
            gold_rows.append(gold_row)

            for p_idx, spec in enumerate(perturb_specs):
                perturb_id = f"jq_perturb_{family}_{idx + 1:02d}_{p_idx + 1:02d}"
                perturb_text = f"{gold_text}\n\n{spec['suffix']}"
                base_score = max(0, min(100, int(round(score)) - int(spec["delta"])))
                perturb_ratings = score_triplet(split_seed + 11, family, (idx * 10) + p_idx, base=base_score)
                perturb_score = round(sum(perturb_ratings) / len(perturb_ratings), 2)
                perturb_raters = [
                    stable_sha256(f"{family}:perturb:{perturb_id}:rater:{rid}") for rid in ("a", "b", "c")
                ]
                perturb_row: dict[str, Any] = {
                    "id": perturb_id,
                    "preset_family": family,
                    "item_type": "perturbation",
                    "language_tag": lang_tag,
                    "language_source": lang_source,
                    "split": split,
                    "split_seed": split_seed,
                    "split_locked_at": split_locked_at,
                    "parent_prompt_id": gold_id,
                    "blinded_item_id": f"blind_{stable_sha256(perturb_id)[:16]}",
                    "blind_round": 1,
                    "sealed_open_count": 0,
                    "expected_relation": "worse_than_parent",
                    "absolute_score_0_100": perturb_score,
                    "error_tags": list(spec["error_tags"]),
                    "adjudication_status": "adjudicated",
                    "rater_count": len(perturb_ratings),
                    "rater_ids_hashed": perturb_raters,
                    "blinded_ratings": perturb_ratings,
                    "provenance_source": provenance_source,
                    "provenance_artifact": provenance_artifact,
                    "provenance_commit": commit,
                    "label_source_class": LABEL_SOURCE_CLASS,
                    "negative_origin": spec["negative_origin"],
                    "perturbation_template_id": spec["template_id"],
                    "hard_negative": bool(spec["hard_negative"]),
                    "prompt_text": perturb_text,
                    "text_sha256": stable_sha256(perturb_text),
                }
                perturb_rows.append(perturb_row)
                family_negative_counts[family][str(spec["negative_origin"])] += 1
                if spec["hard_negative"]:
                    family_hard_negative_counts[family] += 1

                pair_id = f"jq_pair_{family}_{idx + 1:02d}_{p_idx + 1:02d}"
                orientation_rng = random.Random(f"{split_seed}:{pair_id}:orientation")
                gold_is_a = orientation_rng.random() < 0.5
                candidate_a = gold_text if gold_is_a else perturb_text
                candidate_b = perturb_text if gold_is_a else gold_text
                expected_winner = "A" if gold_is_a else "B"
                expected_relation = "A>B" if gold_is_a else "B>A"
                pair_text_hash = stable_hash_object({"a": candidate_a, "b": candidate_b, "id": pair_id})
                pair_row: dict[str, Any] = {
                    "id": pair_id,
                    "preset_family": family,
                    "item_type": "pairwise",
                    "language_tag": lang_tag,
                    "language_source": lang_source,
                    "split": split,
                    "split_seed": split_seed,
                    "split_locked_at": split_locked_at,
                    "parent_prompt_id": gold_id,
                    "blinded_item_id": f"blind_{stable_sha256(pair_id)[:16]}",
                    "blind_round": 1,
                    "sealed_open_count": 0,
                    "expected_relation": expected_relation,
                    "absolute_score_0_100": None,
                    "error_tags": list(spec["error_tags"]),
                    "adjudication_status": "adjudicated",
                    "rater_count": 3,
                    "rater_ids_hashed": [
                        stable_sha256(f"{family}:pair:{pair_id}:rater:{rid}") for rid in ("a", "b", "c")
                    ],
                    "provenance_source": provenance_source,
                    "provenance_artifact": provenance_artifact,
                    "provenance_commit": commit,
                    "label_source_class": LABEL_SOURCE_CLASS,
                    "negative_origin": spec["negative_origin"],
                    "perturbation_template_id": spec["template_id"],
                    "perturbation_id": perturb_id,
                    "hard_negative": bool(spec["hard_negative"]),
                    "draft_prompt": gold_text,
                    "candidate_a": candidate_a,
                    "candidate_b": candidate_b,
                    "candidate_a_source": "gold" if gold_is_a else "perturbation",
                    "candidate_b_source": "perturbation" if gold_is_a else "gold",
                    "candidate_a_text_sha256": stable_sha256(candidate_a),
                    "candidate_b_text_sha256": stable_sha256(candidate_b),
                    "expected_winner": expected_winner,
                    "text_sha256": pair_text_hash,
                }
                pair_rows.append(pair_row)

    lock_eligible_rows: list[dict[str, Any]] = []
    for row in gold_rows:
        result = evaluate_lock_eligible(row)
        if not result.computable:
            raise RuntimeError(f"{row.get('id')}: lock-eligible predicate not computable ({result.reason})")
        if result.is_lock_eligible:
            if int(row.get("rater_count", 0)) < 3:
                raise RuntimeError(f"{row.get('id')}: lock-eligible gold item has rater_count < 3")
            lock_eligible_rows.append(row)

    if not lock_eligible_rows:
        raise RuntimeError("no lock-eligible gold rows produced")

    alpha = krippendorff_alpha_interval(
        [list(row.get("blinded_ratings", [])) for row in lock_eligible_rows],
    )
    if alpha < alpha_threshold:
        raise RuntimeError(f"lock-eligible alpha gate failed: alpha={alpha:.6f} < {alpha_threshold}")

    negatives_total = len(perturb_rows)
    natural_total = sum(1 for row in perturb_rows if row.get("negative_origin") == "natural")
    natural_ratio = (natural_total / negatives_total) if negatives_total > 0 else 0.0
    if natural_ratio < natural_negative_ratio_min:
        raise RuntimeError(
            f"natural-negative ratio gate failed: ratio={natural_ratio:.6f} < {natural_negative_ratio_min}"
        )

    for family, hard_count in family_hard_negative_counts.items():
        if hard_count < 1:
            raise RuntimeError(f"{family}: hard-negative coverage failed (count={hard_count})")

    manifest_families: dict[str, Any] = {}
    for family in sorted(family_split_counts):
        counts = family_split_counts[family]
        total = max(1, sum(counts.values()))
        ratios = {split: counts.get(split, 0) / total for split in SPLITS}
        floors_ok = all(counts.get(split, 0) >= MIN_COUNTS_PER_FAMILY[split] for split in SPLITS)
        ratio_ok = all(abs(ratios[split] - SPLIT_TARGET_RATIOS[split]) <= SPLIT_RATIO_TOLERANCE for split in SPLITS)
        negative_counts = family_negative_counts[family]
        neg_total = max(1, negative_counts["natural"] + negative_counts["synthetic"])
        manifest_families[family] = {
            "gold_counts_by_split": counts,
            "gold_ratios_by_split": {k: round(v, 6) for k, v in ratios.items()},
            "split_floor_ok": floors_ok,
            "split_ratio_ok": ratio_ok,
            "negative_counts": negative_counts,
            "natural_negative_ratio": round(negative_counts["natural"] / neg_total, 6),
            "hard_negative_count": family_hard_negative_counts[family],
        }
        if not floors_ok:
            raise RuntimeError(f"{family}: minimum split counts failed")
        if not ratio_ok:
            raise RuntimeError(f"{family}: split ratio bounds failed")

    language_tags = sorted({str(row.get("language_tag", "")) for row in (gold_rows + perturb_rows + pair_rows)})
    for tag in language_tags:
        if not tag or not bcp47_like(tag):
            raise RuntimeError(f"invalid language_tag in generated dataset: {tag!r}")

    out_dir.mkdir(parents=True, exist_ok=True)
    write_jsonl(out_dir / "gold_prompts.jsonl", gold_rows)
    write_jsonl(out_dir / "perturbations.jsonl", perturb_rows)
    write_jsonl(out_dir / "pairwise_labels.jsonl", pair_rows)

    trusted_break_glass_token_hash = os.getenv(BREAK_GLASS_TOKEN_HASH_ENV, "").strip() or None
    manifest_core = {
        "version": "v1",
        "dataset_family": "judge_quality",
        "generated_at": created_at,
        "split_seed": split_seed,
        "split_locked_at": split_locked_at,
        "split_validation_mode": "ratio_floor",
        "target_ratios_by_family": SPLIT_TARGET_RATIOS,
        "ratio_tolerance": SPLIT_RATIO_TOLERANCE,
        "min_counts_per_split_per_family": MIN_COUNTS_PER_FAMILY,
        "template_holdout_for_lock": TEMPLATE_HOLDOUT_FOR_LOCK,
        "lock_eligible_predicate": {
            "item_type": "gold",
            "adjudication_status": "adjudicated",
            "rater_count_min": 3,
            "error_tags_required_field": True,
            "absolute_score_0_100_range": [0, 100],
            "allowed_splits": list(SPLITS),
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
        },
    }
    signing_secret = os.getenv(MANIFEST_SIGNATURE_SECRET_ENV, "").strip()
    if not signing_secret and not allow_unsigned_manifest_signature:
        raise RuntimeError(
            "detached manifest signature is required for judge_quality datasets; "
            f"set {MANIFEST_SIGNATURE_SECRET_ENV} (or pass --allow-unsigned-manifest-signature for local-dev only)"
        )
    detached_payload = build_detached_manifest_payload(
        manifest_core=manifest_core,
        gold_rows=gold_rows,
        perturb_rows=perturb_rows,
        pair_rows=pair_rows,
    )
    detached_signature_required = bool(signing_secret)
    detached_signature = sign_manifest_payload(signing_secret, detached_payload) if signing_secret else None
    manifest = dict(manifest_core)
    manifest["integrity"] = {
        "detached_manifest_signature": {
            "algorithm": "hmac-sha256",
            "secret_env": MANIFEST_SIGNATURE_SECRET_ENV,
            "required": detached_signature_required,
            "payload_sha256": stable_hash_object(detached_payload),
            "signature": detached_signature,
            "signed_at": created_at if detached_signature else None,
            "unsigned_override_used": bool(allow_unsigned_manifest_signature and not signing_secret),
        }
    }
    write_json(out_dir / "split_manifest.v1.json", manifest)

    return {
        "ok": True,
        "out_dir": str(out_dir),
        "gold_prompts": len(gold_rows),
        "perturbations": len(perturb_rows),
        "pairwise_labels": len(pair_rows),
        "lock_eligible_gold": len(lock_eligible_rows),
        "krippendorff_alpha_lock_eligible": round(alpha, 6),
        "natural_negative_ratio": round(natural_ratio, 6),
        "families": families,
        "split_seed": split_seed,
        "variants_per_family": len(variants),
        "perturbations_per_gold": len(perturb_specs),
        "include_synthetic_negatives": bool(include_synthetic_negatives),
        "provenance_source": provenance_source,
        "provenance_artifact": provenance_artifact,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build deterministic judge-quality dataset artifacts.")
    parser.add_argument("--repo", default=str(REPO))
    parser.add_argument("--gate-manifest", default=str(DEFAULT_GATE_MANIFEST))
    parser.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR))
    parser.add_argument("--split-seed", type=int, default=DEFAULT_SPLIT_SEED)
    parser.add_argument("--split-locked-at", default=DEFAULT_SPLIT_LOCKED_AT)
    parser.add_argument("--alpha-threshold", type=float, default=DEFAULT_ALPHA_THRESHOLD)
    parser.add_argument("--natural-negative-ratio-min", type=float, default=DEFAULT_NATURAL_NEGATIVE_RATIO_MIN)
    parser.add_argument("--variants-per-family", type=int, default=5)
    parser.add_argument("--no-synthetic-negatives", action="store_true")
    parser.add_argument("--provenance-source", default=PROVENANCE_SOURCE)
    parser.add_argument("--provenance-artifact", default=PROVENANCE_ARTIFACT)
    parser.add_argument(
        "--real-primary-profile",
        action="store_true",
        help=(
            "Convenience profile for R5 lock prep: disables synthetic negatives. "
            "This generator remains synthetic and is not human-adjudicated evidence."
        ),
    )
    parser.add_argument(
        "--allow-unsigned-manifest-signature",
        action="store_true",
        help="Local-dev override: allow unsigned detached manifest signature (not for lock/promotion artifacts).",
    )
    parser.add_argument(
        "--allow-unverified-provenance-claims",
        action="store_true",
        help=(
            "Local-dev override: allow provenance labels that imply human/real adjudication. "
            "By default this synthetic generator blocks such claims."
        ),
    )
    args = parser.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    out_dir = pathlib.Path(args.out_dir).resolve()
    gate_manifest = pathlib.Path(args.gate_manifest).resolve()
    include_synthetic_negatives = not bool(args.no_synthetic_negatives)
    provenance_source = str(args.provenance_source).strip()
    provenance_artifact = str(args.provenance_artifact).strip()

    if bool(args.real_primary_profile):
        include_synthetic_negatives = False

    if not provenance_source:
        raise RuntimeError("--provenance-source must be non-empty")
    if not provenance_artifact:
        raise RuntimeError("--provenance-artifact must be non-empty")
    if not bool(args.allow_unverified_provenance_claims):
        source_lower = provenance_source.lower()
        artifact_lower = provenance_artifact.lower()
        banned_markers = ("real_primary", "human_adjudicated", "expert_panel_real")
        if any(marker in source_lower for marker in banned_markers) or any(
            marker in artifact_lower for marker in banned_markers
        ):
            raise RuntimeError(
                "synthetic dataset generator refuses human/real provenance claims; "
                "use --allow-unverified-provenance-claims only for explicit local experiments"
            )

    summary = build_dataset(
        repo=repo,
        out_dir=out_dir,
        gate_manifest_path=gate_manifest,
        split_seed=args.split_seed,
        split_locked_at=args.split_locked_at,
        alpha_threshold=args.alpha_threshold,
        natural_negative_ratio_min=args.natural_negative_ratio_min,
        variant_count=int(args.variants_per_family),
        include_synthetic_negatives=include_synthetic_negatives,
        provenance_source=provenance_source,
        provenance_artifact=provenance_artifact,
        allow_unsigned_manifest_signature=bool(args.allow_unsigned_manifest_signature),
    )
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
