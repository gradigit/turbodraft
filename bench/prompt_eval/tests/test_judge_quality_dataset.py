from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
import hashlib


REPO = pathlib.Path(__file__).resolve().parents[3]
BUILD_SCRIPT = REPO / "bench/prompt_eval/tools/build_judge_quality_dataset.py"
IMPORT_SCRIPT = REPO / "bench/prompt_eval/tools/import_human_judge_quality_dataset.py"
EXPORT_SCRIPT = REPO / "bench/prompt_eval/tools/export_judge_quality_legacy_calibration.py"
INTEGRITY_SCRIPT = REPO / "bench/prompt_eval/tools/check_dataset_integrity.py"
JUDGE_AUDIT_SCRIPT = REPO / "bench/prompt_eval/tools/generate_judge_audit.py"
MANIFEST_SIGNATURE_SECRET_ENV = "PROMPT_EVAL_JUDGE_QUALITY_MANIFEST_SECRET"
BREAK_GLASS_TOKEN_HASH_ENV = "PROMPT_EVAL_JUDGE_QUALITY_BREAK_GLASS_TOKEN_HASH"
TEST_SIGN_SECRET = "test-signing-secret"


def run(
    cmd: list[str],
    cwd: pathlib.Path = REPO,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.pop("OPENAI_API_KEY", None)
    env.pop("ANTHROPIC_API_KEY", None)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(cmd, cwd=str(cwd), text=True, capture_output=True, env=env)


def load_module(path: pathlib.Path, name: str):
    spec = importlib.util.spec_from_file_location(name, str(path))
    assert spec is not None
    assert spec.loader is not None
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    sys.modules[spec.name] = mod  # type: ignore[index]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def load_jsonl(path: pathlib.Path) -> list[dict]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return rows


def write_jsonl(path: pathlib.Path, rows: list[dict]) -> None:
    path.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows) + "\n", encoding="utf-8")


class JudgeQualityDatasetTests(unittest.TestCase):
    def test_human_importer_builds_canonical_dataset_and_passes_integrity(self):
        with tempfile.TemporaryDirectory() as td:
            td_path = pathlib.Path(td)
            source_path = td_path / "human_rows.jsonl"
            out_root = td_path / "datasets"
            out_dir = out_root / "judge_quality"
            rows = [
                {
                    "id": "human_gold_dev",
                    "preset_family": "coding",
                    "item_type": "gold",
                    "language_tag": "en-US",
                    "split": "dev",
                    "prompt_text": "Implement sidebar resizing with explicit rollback checks and unit coverage.",
                    "absolute_score_0_100": 92,
                    "error_tags": [],
                    "adjudication_status": "adjudicated",
                    "rater_count": 3,
                    "blinded_ratings": [92, 92, 92],
                    "provenance_source": "human_panel_batch_01",
                    "provenance_artifact": "judge_quality_round_01",
                },
                {
                    "id": "human_perturb_dev",
                    "preset_family": "coding",
                    "item_type": "perturbation",
                    "language_tag": "en-US",
                    "split": "dev",
                    "parent_prompt_id": "human_gold_dev",
                    "prompt_text": "Implement sidebar resizing and maybe do other UI improvements if useful.",
                    "absolute_score_0_100": 58,
                    "error_tags": ["missing_constraint", "scope_fabrication"],
                    "adjudication_status": "adjudicated",
                    "rater_count": 3,
                    "blinded_ratings": [57, 58, 59],
                    "provenance_source": "human_panel_batch_01",
                    "provenance_artifact": "judge_quality_round_01",
                    "negative_origin": "natural",
                    "hard_negative": True,
                },
                {
                    "id": "human_pair_dev",
                    "preset_family": "coding",
                    "item_type": "pairwise",
                    "language_tag": "en-US",
                    "split": "dev",
                    "parent_prompt_id": "human_gold_dev",
                    "perturbation_id": "human_perturb_dev",
                    "candidate_a": "Implement sidebar resizing with explicit rollback checks and unit coverage.",
                    "candidate_b": "Implement sidebar resizing and maybe do other UI improvements if useful.",
                    "adjudication_status": "adjudicated",
                    "rater_count": 3,
                    "rater_ids_hashed": ["r1", "r2", "r3"],
                    "provenance_source": "human_panel_batch_01",
                    "provenance_artifact": "judge_quality_round_01",
                    "negative_origin": "natural",
                    "hard_negative": True,
                },
                {
                    "id": "human_gold_tune",
                    "preset_family": "coding",
                    "item_type": "gold",
                    "language_tag": "en-US",
                    "split": "tune",
                    "prompt_text": "Refactor prompt selection without behavior drift and document the compatibility rules.",
                    "absolute_score_0_100": 90,
                    "error_tags": [],
                    "adjudication_status": "adjudicated",
                    "rater_count": 3,
                    "blinded_ratings": [90, 90, 90],
                    "provenance_source": "human_panel_batch_01",
                    "provenance_artifact": "judge_quality_round_01",
                },
                {
                    "id": "human_perturb_tune",
                    "preset_family": "coding",
                    "item_type": "perturbation",
                    "language_tag": "en-US",
                    "split": "tune",
                    "parent_prompt_id": "human_gold_tune",
                    "prompt_text": "Refactor prompt selection and add style polish wherever it feels right.",
                    "absolute_score_0_100": 60,
                    "error_tags": ["missing_constraint"],
                    "adjudication_status": "adjudicated",
                    "rater_count": 3,
                    "blinded_ratings": [59, 60, 61],
                    "provenance_source": "human_panel_batch_01",
                    "provenance_artifact": "judge_quality_round_01",
                    "negative_origin": "natural",
                    "hard_negative": True,
                },
                {
                    "id": "human_pair_tune",
                    "preset_family": "coding",
                    "item_type": "pairwise",
                    "language_tag": "en-US",
                    "split": "tune",
                    "parent_prompt_id": "human_gold_tune",
                    "perturbation_id": "human_perturb_tune",
                    "candidate_a": "Refactor prompt selection and add style polish wherever it feels right.",
                    "candidate_b": "Refactor prompt selection without behavior drift and document the compatibility rules.",
                    "adjudication_status": "adjudicated",
                    "rater_count": 3,
                    "rater_ids_hashed": ["r1", "r2", "r3"],
                    "provenance_source": "human_panel_batch_01",
                    "provenance_artifact": "judge_quality_round_01",
                    "negative_origin": "natural",
                    "hard_negative": True,
                },
                {
                    "id": "human_gold_sealed",
                    "preset_family": "coding",
                    "item_type": "gold",
                    "language_tag": "en-US",
                    "split": "sealed_test",
                    "prompt_text": "Review CI failure causes, state hard blockers, and propose the least risky fix path.",
                    "absolute_score_0_100": 91,
                    "error_tags": [],
                    "adjudication_status": "adjudicated",
                    "rater_count": 3,
                    "blinded_ratings": [91, 91, 91],
                    "provenance_source": "human_panel_batch_01",
                    "provenance_artifact": "judge_quality_round_01",
                },
                {
                    "id": "human_perturb_sealed",
                    "preset_family": "coding",
                    "item_type": "perturbation",
                    "language_tag": "en-US",
                    "split": "sealed_test",
                    "parent_prompt_id": "human_gold_sealed",
                    "prompt_text": "Review CI failures and suggest a fix quickly without slowing down on details.",
                    "absolute_score_0_100": 55,
                    "error_tags": ["missing_constraint", "verbosity_noise"],
                    "adjudication_status": "adjudicated",
                    "rater_count": 3,
                    "blinded_ratings": [54, 55, 56],
                    "provenance_source": "human_panel_batch_01",
                    "provenance_artifact": "judge_quality_round_01",
                    "negative_origin": "natural",
                    "hard_negative": True,
                },
                {
                    "id": "human_pair_sealed",
                    "preset_family": "coding",
                    "item_type": "pairwise",
                    "language_tag": "en-US",
                    "split": "sealed_test",
                    "parent_prompt_id": "human_gold_sealed",
                    "perturbation_id": "human_perturb_sealed",
                    "candidate_a": "Review CI failure causes, state hard blockers, and propose the least risky fix path.",
                    "candidate_b": "Review CI failures and suggest a fix quickly without slowing down on details.",
                    "adjudication_status": "adjudicated",
                    "rater_count": 3,
                    "rater_ids_hashed": ["r1", "r2", "r3"],
                    "provenance_source": "human_panel_batch_01",
                    "provenance_artifact": "judge_quality_round_01",
                    "negative_origin": "natural",
                    "hard_negative": True,
                },
            ]
            write_jsonl(source_path, rows)

            p_import = run(
                [
                    "python3",
                    str(IMPORT_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--source",
                    str(source_path),
                    "--out-dir",
                    str(out_dir),
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_import.returncode, 0, msg=p_import.stderr + "\n" + p_import.stdout)
            imported = json.loads(p_import.stdout)
            self.assertTrue(imported["ok"])
            self.assertEqual(imported["split_validation_mode"], "exact_per_family")

            manifest = json.loads((out_dir / "split_manifest.v1.json").read_text(encoding="utf-8"))
            self.assertTrue(manifest["imported_human_dataset"])
            self.assertEqual(manifest["split_validation_mode"], "exact_per_family")
            self.assertEqual(manifest["provenance_source_class_required"], "human_adjudicated")

            pair_rows = load_jsonl(out_dir / "pairwise_labels.jsonl")
            self.assertEqual(pair_rows[0]["candidate_a_source"], "gold")
            self.assertEqual(pair_rows[0]["candidate_b_source"], "perturbation")
            tune_pair = next(row for row in pair_rows if row["id"] == "human_pair_tune")
            self.assertEqual(tune_pair["candidate_a_source"], "perturbation")
            self.assertEqual(tune_pair["candidate_b_source"], "gold")
            self.assertEqual(tune_pair["expected_winner"], "B")
            self.assertTrue(tune_pair["draft_prompt"])

            p_integrity = run(
                [
                    "python3",
                    str(INTEGRITY_SCRIPT),
                    "--datasets-root",
                    str(out_root),
                    "--strict-pairwise-linkage",
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_integrity.returncode, 0, msg=p_integrity.stderr + "\n" + p_integrity.stdout)
            integrity = json.loads(p_integrity.stdout)
            self.assertTrue(integrity["ok"])

    def test_human_importer_rejects_non_human_label_source_class(self):
        with tempfile.TemporaryDirectory() as td:
            source_path = pathlib.Path(td) / "human_rows.jsonl"
            out_dir = pathlib.Path(td) / "judge_quality"
            rows = [
                {
                    "id": "bad_gold",
                    "preset_family": "coding",
                    "item_type": "gold",
                    "language_tag": "en-US",
                    "split": "dev",
                    "prompt_text": "Test prompt.",
                    "absolute_score_0_100": 90,
                    "error_tags": [],
                    "adjudication_status": "adjudicated",
                    "rater_count": 3,
                    "blinded_ratings": [89, 90, 91],
                    "provenance_source": "human_panel",
                    "provenance_artifact": "round_01",
                    "label_source_class": "synthetic_generated",
                }
            ]
            write_jsonl(source_path, rows)
            p_import = run(
                [
                    "python3",
                    str(IMPORT_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--source",
                    str(source_path),
                    "--out-dir",
                    str(out_dir),
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertNotEqual(p_import.returncode, 0)
            self.assertIn("label_source_class", p_import.stderr + p_import.stdout)

    def test_builder_generates_expected_artifacts(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = pathlib.Path(td) / "judge_quality"
            p = run(
                [
                    "python3",
                    str(BUILD_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--out-dir",
                    str(out_dir),
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            summary = json.loads(p.stdout)
            self.assertTrue(summary["ok"])
            self.assertGreater(summary["gold_prompts"], 0)
            self.assertGreaterEqual(summary["krippendorff_alpha_lock_eligible"], 0.67)

            required_files = [
                "gold_prompts.jsonl",
                "perturbations.jsonl",
                "pairwise_labels.jsonl",
                "split_manifest.v1.json",
            ]
            for name in required_files:
                self.assertTrue((out_dir / name).exists(), msg=f"missing {name}")

            manifest = json.loads((out_dir / "split_manifest.v1.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["version"], "v1")
            self.assertIn("lock_eligible_predicate", manifest)
            self.assertIn("quality_gates", manifest)
            self.assertGreaterEqual(
                float(manifest["dataset_stats"]["natural_negative_ratio"]),
                float(manifest["quality_gates"]["natural_negative_ratio_min"]),
            )

    def test_lock_eligible_predicate_is_deterministic(self):
        mod = load_module(BUILD_SCRIPT, "build_judge_quality_dataset_mod")

        base_row = {
            "item_type": "gold",
            "adjudication_status": "adjudicated",
            "rater_count": 3,
            "error_tags": [],
            "absolute_score_0_100": 88,
            "split": "dev",
        }
        first = mod.evaluate_lock_eligible(base_row)
        second = mod.evaluate_lock_eligible(base_row)
        self.assertEqual(first, second)
        self.assertTrue(first.computable)
        self.assertTrue(first.is_lock_eligible)

        missing_field = dict(base_row)
        missing_field.pop("error_tags")
        missing_result = mod.evaluate_lock_eligible(missing_field)
        self.assertFalse(missing_result.computable)
        self.assertIn("missing required fields", missing_result.reason)

        pending = dict(base_row)
        pending["adjudication_status"] = "pending"
        pending_result = mod.evaluate_lock_eligible(pending)
        self.assertTrue(pending_result.computable)
        self.assertFalse(pending_result.is_lock_eligible)

    def test_krippendorff_alpha_interval_matches_reference_formula(self):
        mod = load_module(BUILD_SCRIPT, "build_judge_quality_alpha_mod")

        def reference(units: list[list[float]]) -> float:
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
            observed_den = 0
            for values in normalized:
                for i in range(len(values)):
                    for j in range(i + 1, len(values)):
                        observed_num += (values[i] - values[j]) ** 2
                        observed_den += 1
            if observed_den == 0:
                return 1.0
            expected_num = 0.0
            expected_den = 0
            for i in range(len(all_values)):
                for j in range(i + 1, len(all_values)):
                    expected_num += (all_values[i] - all_values[j]) ** 2
                    expected_den += 1
            if expected_den == 0:
                return 1.0
            de = expected_num / expected_den
            if de == 0:
                return 1.0 if (observed_num / observed_den) == 0 else 0.0
            return max(-1.0, min(1.0, 1.0 - ((observed_num / observed_den) / de)))

        units = [
            [88, 89, 90],
            [70, 71, 72],
            [50, 52, 54],
            [10, 10, 10],
            [42],  # filtered
        ]
        self.assertAlmostEqual(mod.krippendorff_alpha_interval(units), reference(units), places=12)

    def test_integrity_checker_enforces_parent_split_inheritance(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td) / "datasets"
            jq_dir = root / "judge_quality"
            p_build = run(
                [
                    "python3",
                    str(BUILD_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--out-dir",
                    str(jq_dir),
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_build.returncode, 0, msg=p_build.stderr + "\n" + p_build.stdout)

            p_ok = run(
                [
                    "python3",
                    str(INTEGRITY_SCRIPT),
                    "--datasets-root",
                    str(root),
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_ok.returncode, 0, msg=p_ok.stderr + "\n" + p_ok.stdout)

            perturb_path = jq_dir / "perturbations.jsonl"
            perturb_rows = load_jsonl(perturb_path)
            self.assertGreater(len(perturb_rows), 0)
            perturb_rows[0]["split"] = "sealed_test" if perturb_rows[0]["split"] != "sealed_test" else "dev"
            perturb_path.write_text(
                "\n".join(json.dumps(row, ensure_ascii=False) for row in perturb_rows) + "\n",
                encoding="utf-8",
            )

            p_bad = run(
                [
                    "python3",
                    str(INTEGRITY_SCRIPT),
                    "--datasets-root",
                    str(root),
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertNotEqual(p_bad.returncode, 0)
            out = json.loads(p_bad.stdout)
            self.assertFalse(out["ok"])
            err_text = "\n".join(out.get("errors", []))
            self.assertIn("split inheritance violated", err_text)

    def test_integrity_checker_enforces_family_set_equality(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td) / "datasets"
            jq_dir = root / "judge_quality"
            p_build = run(
                ["python3", str(BUILD_SCRIPT), "--repo", str(REPO), "--out-dir", str(jq_dir)],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_build.returncode, 0, msg=p_build.stderr + "\n" + p_build.stdout)

            manifest_path = jq_dir / "split_manifest.v1.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            family_to_remove = sorted(manifest["families"].keys())[0]
            manifest["families"].pop(family_to_remove)
            manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

            p_bad = run(
                ["python3", str(INTEGRITY_SCRIPT), "--datasets-root", str(root)],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertNotEqual(p_bad.returncode, 0)
            out = json.loads(p_bad.stdout)
            self.assertIn("family set mismatch", "\n".join(out.get("errors", [])))

    def test_integrity_checker_detached_signature_and_opt_out(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td) / "datasets"
            jq_dir = root / "judge_quality"
            sign_secret = TEST_SIGN_SECRET
            p_build = run(
                ["python3", str(BUILD_SCRIPT), "--repo", str(REPO), "--out-dir", str(jq_dir)],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: sign_secret},
            )
            self.assertEqual(p_build.returncode, 0, msg=p_build.stderr + "\n" + p_build.stdout)

            p_ok = run(
                ["python3", str(INTEGRITY_SCRIPT), "--datasets-root", str(root)],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: sign_secret},
            )
            self.assertEqual(p_ok.returncode, 0, msg=p_ok.stderr + "\n" + p_ok.stdout)

            p_missing_secret = run(["python3", str(INTEGRITY_SCRIPT), "--datasets-root", str(root)])
            self.assertNotEqual(p_missing_secret.returncode, 0)
            missing_out = json.loads(p_missing_secret.stdout)
            self.assertIn("secret not set", "\n".join(missing_out.get("errors", [])))

            manifest_path = jq_dir / "split_manifest.v1.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["integrity"]["detached_manifest_signature"]["signature"] = "deadbeef"
            manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

            p_invalid = run(
                ["python3", str(INTEGRITY_SCRIPT), "--datasets-root", str(root)],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: sign_secret},
            )
            self.assertNotEqual(p_invalid.returncode, 0)
            invalid_out = json.loads(p_invalid.stdout)
            self.assertIn("signature invalid", "\n".join(invalid_out.get("errors", [])))

            p_override = run(
                [
                    "python3",
                    str(INTEGRITY_SCRIPT),
                    "--datasets-root",
                    str(root),
                    "--allow-unsigned-manifest-signature",
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: sign_secret},
            )
            self.assertEqual(p_override.returncode, 0, msg=p_override.stderr + "\n" + p_override.stdout)
            override_out = json.loads(p_override.stdout)
            self.assertTrue(any("allowed by override" in w for w in override_out.get("warnings", [])))

    def test_integrity_checker_judge_quality_near_duplicate_warning(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td) / "datasets"
            jq_dir = root / "judge_quality"
            p_build = run(["python3", str(BUILD_SCRIPT), "--repo", str(REPO), "--out-dir", str(jq_dir)])
            self.assertNotEqual(p_build.returncode, 0)
            p_build = run(
                [
                    "python3",
                    str(BUILD_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--out-dir",
                    str(jq_dir),
                    "--allow-unsigned-manifest-signature",
                ]
            )
            self.assertEqual(p_build.returncode, 0, msg=p_build.stderr + "\n" + p_build.stdout)

            gold_rows = load_jsonl(jq_dir / "gold_prompts.jsonl")
            by_split: dict[str, list[dict]] = {}
            for row in gold_rows:
                by_split.setdefault(str(row["split"]), []).append(row)
            self.assertIn("dev", by_split)
            self.assertIn("tune", by_split)
            by_split["tune"][0]["prompt_text"] = by_split["dev"][0]["prompt_text"]
            by_split["tune"][0]["text_sha256"] = hashlib.sha256(
                by_split["tune"][0]["prompt_text"].encode("utf-8")
            ).hexdigest()
            (jq_dir / "gold_prompts.jsonl").write_text(
                "\n".join(json.dumps(row, ensure_ascii=False) for row in gold_rows) + "\n",
                encoding="utf-8",
            )

            manifest_path = jq_dir / "split_manifest.v1.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            if isinstance(manifest.get("integrity"), dict) and isinstance(
                manifest["integrity"].get("detached_manifest_signature"), dict
            ):
                build_mod = load_module(BUILD_SCRIPT, "build_judge_quality_dataset_near_dup_mod")
                manifest_core = dict(manifest)
                manifest_core.pop("integrity", None)
                perturb_rows = load_jsonl(jq_dir / "perturbations.jsonl")
                pair_rows = load_jsonl(jq_dir / "pairwise_labels.jsonl")
                payload = build_mod.build_detached_manifest_payload(
                    manifest_core=manifest_core,
                    gold_rows=gold_rows,
                    perturb_rows=perturb_rows,
                    pair_rows=pair_rows,
                )
                detached = manifest["integrity"]["detached_manifest_signature"]
                detached["payload_sha256"] = build_mod.stable_hash_object(payload)
                detached["signature"] = None
                detached["required"] = False
                detached["signed_at"] = None
                manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

            p_warn = run(
                [
                    "python3",
                    str(INTEGRITY_SCRIPT),
                    "--datasets-root",
                    str(root),
                    "--near-duplicate-threshold",
                    "1.0",
                    "--allow-unsigned-manifest-signature",
                ]
            )
            self.assertEqual(p_warn.returncode, 0, msg=p_warn.stderr + "\n" + p_warn.stdout)
            out = json.loads(p_warn.stdout)
            self.assertTrue(
                any("judge_quality: near-duplicate prompt_text across splits" in w for w in out.get("warnings", []))
            )

    def test_exporter_sealed_controls_and_break_glass(self):
        with tempfile.TemporaryDirectory() as td:
            judge_quality_dir = pathlib.Path(td) / "judge_quality"
            trusted_token = "token-123"
            trusted_hash = hashlib.sha256(trusted_token.encode("utf-8")).hexdigest()
            p_build = run(
                [
                    "python3",
                    str(BUILD_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--out-dir",
                    str(judge_quality_dir),
                ],
                extra_env={
                    BREAK_GLASS_TOKEN_HASH_ENV: trusted_hash,
                    MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET,
                },
            )
            self.assertEqual(p_build.returncode, 0, msg=p_build.stderr + "\n" + p_build.stdout)

            export_default = pathlib.Path(td) / "legacy_default"
            p_default = run(
                [
                    "python3",
                    str(EXPORT_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--judge-quality-dir",
                    str(judge_quality_dir),
                    "--out-dir",
                    str(export_default),
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_default.returncode, 0, msg=p_default.stderr + "\n" + p_default.stdout)

            sealed_gold_ids = {
                row["id"]
                for row in load_jsonl(judge_quality_dir / "gold_prompts.jsonl")
                if row.get("split") == "sealed_test"
            }
            default_pairs = load_jsonl(export_default / "judge_pairs.jsonl")
            self.assertGreater(len(default_pairs), 0)
            for row in default_pairs:
                base_id = row["id"].split("_legacy_")[0]
                self.assertNotIn(base_id, sealed_gold_ids)

            export_open = pathlib.Path(td) / "legacy_open_once"
            p_open = run(
                [
                    "python3",
                    str(EXPORT_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--judge-quality-dir",
                    str(judge_quality_dir),
                    "--out-dir",
                    str(export_open),
                    "--open-sealed-test",
                    "--open-sealed-test-reason",
                    "initial lock audit",
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_open.returncode, 0, msg=p_open.stderr + "\n" + p_open.stdout)
            manifest_after_open = json.loads((judge_quality_dir / "split_manifest.v1.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest_after_open["governance"]["sealed_open_count"], 1)

            p_default_after_open = run(
                [
                    "python3",
                    str(EXPORT_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--judge-quality-dir",
                    str(judge_quality_dir),
                    "--out-dir",
                    str(pathlib.Path(td) / "legacy_default_after_open"),
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertNotEqual(p_default_after_open.returncode, 0)
            self.assertIn("fail-closed", p_default_after_open.stderr + p_default_after_open.stdout)

            p_second_open_without_token = run(
                [
                    "python3",
                    str(EXPORT_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--judge-quality-dir",
                    str(judge_quality_dir),
                    "--out-dir",
                    str(pathlib.Path(td) / "legacy_open_twice_no_token"),
                    "--open-sealed-test",
                    "--open-sealed-test-reason",
                    "repeat lock audit",
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertNotEqual(p_second_open_without_token.returncode, 0)
            self.assertIn("break-glass token", p_second_open_without_token.stderr + p_second_open_without_token.stdout)

            p_second_open_wrong_token = run(
                [
                    "python3",
                    str(EXPORT_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--judge-quality-dir",
                    str(judge_quality_dir),
                    "--out-dir",
                    str(pathlib.Path(td) / "legacy_open_twice_wrong_token"),
                    "--open-sealed-test",
                    "--open-sealed-test-reason",
                    "repeat lock audit with wrong token",
                    "--break-glass-token",
                    "wrong-token",
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertNotEqual(p_second_open_wrong_token.returncode, 0)
            self.assertIn("invalid break-glass token", p_second_open_wrong_token.stderr + p_second_open_wrong_token.stdout)

            export_break_glass = pathlib.Path(td) / "legacy_open_twice_with_token"
            p_break_glass = run(
                [
                    "python3",
                    str(EXPORT_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--judge-quality-dir",
                    str(judge_quality_dir),
                    "--out-dir",
                    str(export_break_glass),
                    "--open-sealed-test",
                    "--open-sealed-test-reason",
                    "repeat lock audit with emergency approval",
                    "--break-glass-token",
                    trusted_token,
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_break_glass.returncode, 0, msg=p_break_glass.stderr + "\n" + p_break_glass.stdout)
            manifest_after_break_glass = json.loads(
                (judge_quality_dir / "split_manifest.v1.json").read_text(encoding="utf-8")
            )
            self.assertEqual(manifest_after_break_glass["governance"]["sealed_open_count"], 2)
            self.assertTrue(manifest_after_break_glass["governance"]["break_glass_used"])
            self.assertTrue(manifest_after_break_glass["governance"]["break_glass_token_hash"])
            self.assertGreaterEqual(len(manifest_after_break_glass["governance"]["sealed_export_audit_log"]), 2)

            break_glass_pairs = load_jsonl(export_break_glass / "judge_pairs.jsonl")
            has_sealed = any(row["id"].split("_legacy_")[0] in sealed_gold_ids for row in break_glass_pairs)
            self.assertTrue(has_sealed, msg="sealed_test rows should be present in open-sealed export")

    def test_builder_export_parity_and_simulated_judge_audit_entrypoint(self):
        with tempfile.TemporaryDirectory() as td:
            judge_quality_dir = pathlib.Path(td) / "judge_quality"
            legacy_dir = pathlib.Path(td) / "legacy"
            p_build = run(
                [
                    "python3",
                    str(BUILD_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--out-dir",
                    str(judge_quality_dir),
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_build.returncode, 0, msg=p_build.stderr + "\n" + p_build.stdout)

            p_export = run(
                [
                    "python3",
                    str(EXPORT_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--judge-quality-dir",
                    str(judge_quality_dir),
                    "--out-dir",
                    str(legacy_dir),
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_export.returncode, 0, msg=p_export.stderr + "\n" + p_export.stdout)

            judge_pairs = load_jsonl(legacy_dir / "judge_pairs.jsonl")
            judge_triads = load_jsonl(legacy_dir / "judge_triads.jsonl")
            shadow_pairs = load_jsonl(legacy_dir / "shadow_spotcheck_pairs.jsonl")
            gold_pairs = load_jsonl(legacy_dir / "gold_anchor_pairs.jsonl")
            self.assertGreater(len(judge_pairs), 0)
            self.assertGreater(len(judge_triads), 0)
            self.assertGreater(len(shadow_pairs), 0)
            self.assertGreater(len(gold_pairs), 0)

            self.assertTrue({"id", "preset", "draft_prompt", "candidate_a", "candidate_b", "expected_winner"}.issubset(judge_pairs[0].keys()))
            self.assertTrue({"id", "preset", "draft_prompt", "candidate_a", "candidate_b", "candidate_c", "expected_order"}.issubset(judge_triads[0].keys()))
            self.assertTrue({"id", "preset", "draft_prompt", "candidate_a", "candidate_b"}.issubset(shadow_pairs[0].keys()))
            self.assertTrue({"id", "preset", "draft_prompt", "candidate_a", "candidate_b", "expected_winner"}.issubset(gold_pairs[0].keys()))

            audit_out = pathlib.Path(td) / "judge_audit_sim.json"
            p_audit = run(
                [
                    "python3",
                    str(JUDGE_AUDIT_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--triad-dataset",
                    str(legacy_dir / "judge_triads.jsonl"),
                    "--shadow-dataset",
                    str(legacy_dir / "shadow_spotcheck_pairs.jsonl"),
                    "--gold-dataset",
                    str(legacy_dir / "gold_anchor_pairs.jsonl"),
                    "--simulate-no-provider",
                    "--out",
                    str(audit_out),
                ]
            )
            self.assertEqual(p_audit.returncode, 0, msg=p_audit.stderr + "\n" + p_audit.stdout)
            self.assertTrue(audit_out.exists())
            audit_response = json.loads(p_audit.stdout)
            self.assertTrue(audit_response["ok"])
            self.assertTrue(audit_response["simulated"])

    def test_exporter_fails_on_manifest_tamper_before_governance_checks(self):
        with tempfile.TemporaryDirectory() as td:
            judge_quality_dir = pathlib.Path(td) / "judge_quality"
            legacy_dir = pathlib.Path(td) / "legacy"
            p_build = run(
                ["python3", str(BUILD_SCRIPT), "--repo", str(REPO), "--out-dir", str(judge_quality_dir)],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_build.returncode, 0, msg=p_build.stderr + "\n" + p_build.stdout)

            manifest_path = judge_quality_dir / "split_manifest.v1.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["governance"]["sealed_open_count"] = 99
            manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

            p_export = run(
                [
                    "python3",
                    str(EXPORT_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--judge-quality-dir",
                    str(judge_quality_dir),
                    "--out-dir",
                    str(legacy_dir),
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertNotEqual(p_export.returncode, 0)
            err_text = p_export.stderr + p_export.stdout
            self.assertTrue(
                ("detached manifest signature" in err_text) or ("detached manifest payload hash mismatch" in err_text)
            )

    def test_exporter_only_uses_adjudicated_gold_and_perturb_rows(self):
        with tempfile.TemporaryDirectory() as td:
            judge_quality_dir = pathlib.Path(td) / "judge_quality"
            legacy_dir = pathlib.Path(td) / "legacy"
            p_build = run(
                ["python3", str(BUILD_SCRIPT), "--repo", str(REPO), "--out-dir", str(judge_quality_dir)],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_build.returncode, 0, msg=p_build.stderr + "\n" + p_build.stdout)

            gold_rows = load_jsonl(judge_quality_dir / "gold_prompts.jsonl")
            perturb_rows = load_jsonl(judge_quality_dir / "perturbations.jsonl")
            excluded_gold_id = str(gold_rows[0]["id"])
            for row in gold_rows:
                if row["id"] == excluded_gold_id:
                    row["adjudication_status"] = "excluded"
            for row in perturb_rows:
                if row.get("parent_prompt_id") == excluded_gold_id:
                    row["adjudication_status"] = "excluded"
            (judge_quality_dir / "gold_prompts.jsonl").write_text(
                "\n".join(json.dumps(row, ensure_ascii=False) for row in gold_rows) + "\n",
                encoding="utf-8",
            )
            (judge_quality_dir / "perturbations.jsonl").write_text(
                "\n".join(json.dumps(row, ensure_ascii=False) for row in perturb_rows) + "\n",
                encoding="utf-8",
            )

            # Re-sign manifest after dataset mutation (simulates authorized update path).
            manifest_path = judge_quality_dir / "split_manifest.v1.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            build_mod = load_module(BUILD_SCRIPT, "build_judge_quality_dataset_resign_mod")
            manifest_core = dict(manifest)
            manifest_core.pop("integrity", None)
            pair_rows = load_jsonl(judge_quality_dir / "pairwise_labels.jsonl")
            payload = build_mod.build_detached_manifest_payload(
                manifest_core=manifest_core,
                gold_rows=gold_rows,
                perturb_rows=perturb_rows,
                pair_rows=pair_rows,
            )
            detached = manifest["integrity"]["detached_manifest_signature"]
            detached["payload_sha256"] = build_mod.stable_hash_object(payload)
            detached["signature"] = build_mod.sign_manifest_payload(TEST_SIGN_SECRET, payload)
            detached["required"] = True
            detached["signed_at"] = "2026-03-04T00:00:00Z"
            manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

            p_export = run(
                [
                    "python3",
                    str(EXPORT_SCRIPT),
                    "--repo",
                    str(REPO),
                    "--judge-quality-dir",
                    str(judge_quality_dir),
                    "--out-dir",
                    str(legacy_dir),
                ],
                extra_env={MANIFEST_SIGNATURE_SECRET_ENV: TEST_SIGN_SECRET},
            )
            self.assertEqual(p_export.returncode, 0, msg=p_export.stderr + "\n" + p_export.stdout)

            judge_pairs = load_jsonl(legacy_dir / "judge_pairs.jsonl")
            self.assertTrue(all(not row["id"].startswith(f"{excluded_gold_id}_legacy_") for row in judge_pairs))


if __name__ == "__main__":
    unittest.main()
