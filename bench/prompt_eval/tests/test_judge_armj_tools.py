import json
import os
import pathlib
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[3]
MANIFEST_SIGNATURE_SECRET_ENV = "PROMPT_EVAL_JUDGE_QUALITY_MANIFEST_SECRET"


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.setdefault(MANIFEST_SIGNATURE_SECRET_ENV, "test-signing-secret")
    env.pop("OPENAI_API_KEY", None)
    env.pop("ANTHROPIC_API_KEY", None)
    return subprocess.run(cmd, cwd=str(REPO), text=True, capture_output=True, env=env)


class JudgeArmJToolTests(unittest.TestCase):
    def test_armj_calibration_simulated_pass(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            out_dir = pathlib.Path(td) / "cal"
            p = run(
                [
                    "python3",
                    "bench/prompt_eval/tools/run_judge_quality_calibration.py",
                    "--simulate-no-provider",
                    "--max-pairs",
                    "60",
                    "--reruns",
                    "3",
                    "--min-pairwise-labels",
                    "20",
                    "--out-dir",
                    str(out_dir),
                ]
            )
            self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            summary = json.loads((out_dir / "summary.json").read_text(encoding="utf-8"))
            self.assertTrue(summary["ok"])
            self.assertTrue(summary["checks"]["sample_floor"])
            self.assertEqual(summary["provider"]["runner"], "simulated")
            # Backward-compatible required keys remain present.
            self.assertIn("aggregate", summary)
            self.assertIn("per_run", summary)
            self.assertIn("usage_totals", summary)
            self.assertIn("reason_codes", summary)
            # Additive observability block is available and shaped.
            self.assertIn("confidence_calibration", summary)
            conf = summary["confidence_calibration"]
            self.assertIn("bins", conf)
            self.assertEqual(len(conf["bins"]), 10)
            self.assertGreaterEqual(conf["abs_gap_max"], 0.0)
            self.assertGreaterEqual(conf["abs_gap_weighted"], 0.0)

    def test_armj_calibration_sample_floor_fail(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            out_dir = pathlib.Path(td) / "cal_fail"
            p = run(
                [
                    "python3",
                    "bench/prompt_eval/tools/run_judge_quality_calibration.py",
                    "--simulate-no-provider",
                    "--max-pairs",
                    "30",
                    "--reruns",
                    "2",
                    "--min-pairwise-labels",
                    "1000",
                    "--out-dir",
                    str(out_dir),
                ]
            )
            self.assertNotEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            summary = json.loads((out_dir / "summary.json").read_text(encoding="utf-8"))
            self.assertFalse(summary["ok"])
            self.assertIn("CHECK_FAILED:insufficient_sample_size", summary["reason_codes"])

    def test_armj_calibration_sealed_requires_reason(self) -> None:
        p = run(
            [
                "python3",
                "bench/prompt_eval/tools/run_judge_quality_calibration.py",
                "--simulate-no-provider",
                "--splits",
                "sealed_test",
                "--open-sealed-test",
            ]
        )
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("open-sealed-test-reason", p.stderr + p.stdout)

    def test_armj_invariance_simulated_pass(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            out_dir = pathlib.Path(td) / "inv"
            p = run(
                [
                    "python3",
                    "bench/prompt_eval/tools/run_judge_invariance_suite.py",
                    "--simulate-no-provider",
                    "--max-pairs",
                    "40",
                    "--reruns",
                    "3",
                    "--out-dir",
                    str(out_dir),
                ]
            )
            self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            summary = json.loads((out_dir / "summary.json").read_text(encoding="utf-8"))
            self.assertTrue(summary["ok"])
            self.assertTrue(summary["checks"]["order_swap_flip_rate"])
            self.assertTrue(summary["checks"]["attack_success_rate"])

    def test_armj_invariance_threshold_fail(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            out_dir = pathlib.Path(td) / "inv_fail"
            p = run(
                [
                    "python3",
                    "bench/prompt_eval/tools/run_judge_invariance_suite.py",
                    "--simulate-no-provider",
                    "--max-pairs",
                    "20",
                    "--reruns",
                    "2",
                    "--family-source-bias-delta-max",
                    "-0.1",
                    "--out-dir",
                    str(out_dir),
                ]
            )
            self.assertNotEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            summary = json.loads((out_dir / "summary.json").read_text(encoding="utf-8"))
            self.assertFalse(summary["ok"])
            self.assertIn("CHECK_FAILED:family_source_bias_delta", summary["reason_codes"])

    def test_armo_and_meta_agreement_simulated(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            td_path = pathlib.Path(td)
            summary_path = td_path / "judge_like_summary.json"
            summary_payload = {
                "inference_regime": "frequentist_holm_one_sided",
                "baseline_variant": "overlay_baseline",
                "results": {
                    "overlay_baseline": {"n": 300},
                    "overlay_contract_selfcheck": {
                        "pairwise_vs_baseline": {
                            "n": 300,
                            "wins": 190,
                            "losses": 70,
                            "ties": 40,
                            "non_tie_n": 260,
                            "win_rate": 0.73,
                        }
                    },
                    "overlay_precision_guard": {
                        "pairwise_vs_baseline": {
                            "n": 300,
                            "wins": 150,
                            "losses": 100,
                            "ties": 50,
                            "non_tie_n": 250,
                            "win_rate": 0.60,
                        }
                    },
                },
                "family_results": {
                    "coding": {"best_pairwise_vs_baseline": {"wins": 40, "losses": 20, "non_tie_n": 60}},
                    "refactor": {"best_pairwise_vs_baseline": {"wins": 40, "losses": 20, "non_tie_n": 60}},
                    "review": {"best_pairwise_vs_baseline": {"wins": 40, "losses": 20, "non_tie_n": 60}},
                },
            }
            summary_path.write_text(json.dumps(summary_payload) + "\n", encoding="utf-8")
            armo_out = td_path / "armo.json"
            p1 = run(
                [
                    "python3",
                    "bench/prompt_eval/tools/run_outcome_lite_eval.py",
                    "--phase-summaries",
                    str(summary_path),
                    "--require-per-family-min",
                    "0",
                    "--out",
                    str(armo_out),
                    "--simulate-no-provider",
                ]
            )
            self.assertEqual(p1.returncode, 0, msg=p1.stderr + "\n" + p1.stdout)
            armo = json.loads(armo_out.read_text(encoding="utf-8"))
            self.assertTrue(armo["ok"])
            self.assertGreaterEqual(len(armo["ranked_candidates"]), 2)

            meta_out = td_path / "meta.json"
            p2 = run(
                [
                    "python3",
                    "bench/prompt_eval/tools/run_judge_outcome_meta_agreement.py",
                    "--judge-summary",
                    str(summary_path),
                    "--outcome-summary",
                    str(armo_out),
                    "--out",
                    str(meta_out),
                ]
            )
            self.assertEqual(p2.returncode, 0, msg=p2.stderr + "\n" + p2.stdout)
            meta = json.loads(meta_out.read_text(encoding="utf-8"))
            self.assertTrue(meta["ok"])
            self.assertGreaterEqual(meta["shared_variant_count"], 2)


if __name__ == "__main__":
    unittest.main()
