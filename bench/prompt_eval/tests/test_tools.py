import json
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
import uuid

REPO = pathlib.Path(__file__).resolve().parents[3]
MANIFEST_SIGNATURE_SECRET_ENV = "PROMPT_EVAL_JUDGE_QUALITY_MANIFEST_SECRET"


def run(cmd, cwd=REPO):
    env = os.environ.copy()
    # Keep simulation tests deterministic and prevent accidental provider calls/costs.
    env.pop("OPENAI_API_KEY", None)
    env.pop("ANTHROPIC_API_KEY", None)
    env.setdefault(MANIFEST_SIGNATURE_SECRET_ENV, "test-signing-secret")
    return subprocess.run(cmd, cwd=str(cwd), text=True, capture_output=True, env=env)


class PromptEvalToolTests(unittest.TestCase):
    def test_validate_gate_manifest(self):
        p = run(["python3", "bench/prompt_eval/tools/validate_gate_manifest.py"])
        self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
        data = json.loads(p.stdout)
        self.assertTrue(data["ok"])

    def test_validate_gate_manifest_rejects_invalid_version_and_bool_numeric(self):
        base = REPO / "bench/prompt_eval/config/gate_manifest.v1.json"
        data = json.loads(base.read_text())
        data["version"] = "v2"
        data["judge_thresholds"]["calibration_accuracy_min"] = True
        with tempfile.TemporaryDirectory() as td:
            path = pathlib.Path(td) / "bad_manifest.json"
            path.write_text(json.dumps(data), encoding="utf-8")
            p = run(["python3", "bench/prompt_eval/tools/validate_gate_manifest.py", "--manifest", str(path)])
            self.assertNotEqual(p.returncode, 0)
            out = json.loads(p.stdout)
            self.assertFalse(out["ok"])
            err_text = "\n".join(out.get("errors", []))
            self.assertIn("root.version: must equal 'v1'", err_text)
            self.assertIn("judge_thresholds.calibration_accuracy_min: must be number", err_text)

    def test_dataset_integrity(self):
        p = run(["python3", "bench/prompt_eval/tools/check_dataset_integrity.py"])
        self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
        data = json.loads(p.stdout)
        self.assertTrue(data["ok"])
        self.assertGreaterEqual(data["counts_by_split"]["dev"], 1)

    def test_assess_judge_lock_readiness_reports_no_lock(self):
        with tempfile.TemporaryDirectory() as td:
            out = pathlib.Path(td) / "lock_readiness.json"
            p = run(
                [
                    "python3",
                    "bench/prompt_eval/tools/assess_judge_lock_readiness.py",
                    "--out",
                    str(out),
                ]
            )
            self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            data = json.loads(out.read_text())
            self.assertEqual(data["decision"], "NO_LOCK")
            self.assertIn("CHECK_FAILED:armj_artifacts_present", data["reason_codes"])
            self.assertIn("CHECK_FAILED:armo_artifact_present", data["reason_codes"])

    def test_assess_judge_lock_readiness_fail_on_no_lock(self):
        with tempfile.TemporaryDirectory() as td:
            out = pathlib.Path(td) / "lock_readiness.json"
            p = run(
                [
                    "python3",
                    "bench/prompt_eval/tools/assess_judge_lock_readiness.py",
                    "--out",
                    str(out),
                    "--fail-on-no-lock",
                ]
            )
            self.assertNotEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            data = json.loads(out.read_text())
            self.assertEqual(data["decision"], "NO_LOCK")

    def test_validate_holistic_sources(self):
        p = run(["python3", "bench/prompt_eval/tools/validate_holistic_sources.py"])
        self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
        data = json.loads(p.stdout)
        self.assertTrue(data["ok"])
        self.assertGreaterEqual(data["provider_hits"]["openai"], 1)
        self.assertGreaterEqual(data["provider_hits"]["anthropic"], 1)
        self.assertGreaterEqual(data["provider_hits"]["google"], 1)
        self.assertGreaterEqual(data["provider_hits"]["promptfoo"], 1)

    def test_holdout_isolation_blocks_without_env(self):
        p = run([
            "python3",
            "bench/prompt_eval/tools/enforce_holdout_isolation.py",
            "--phase",
            "phaseF_holdout",
            "--config",
            "bench/prompt_eval/config/holdout.promptfoo.yaml",
        ])
        self.assertNotEqual(p.returncode, 0)

    def test_build_run_manifest(self):
        with tempfile.TemporaryDirectory() as td:
            out = pathlib.Path(td) / "manifest.json"
            p = run([
                "python3",
                "bench/prompt_eval/tools/build_run_manifest.py",
                "--phase",
                "phase0_bootstrap",
                "--dataset-split",
                "dev",
                "--dataset-path",
                "bench/prompt_eval/datasets/dev/cases.jsonl",
                "--config-path",
                "bench/prompt_eval/config/dev.promptfoo.yaml",
                "--out",
                str(out),
            ])
            self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            data = json.loads(out.read_text())
            self.assertEqual(data["phase"], "phase0_bootstrap")
            self.assertIn("gate_manifest_sha256", data)

    def test_build_run_manifest_custom_prompt_and_models(self):
        with tempfile.TemporaryDirectory() as td:
            out = pathlib.Path(td) / "manifest.json"
            judge_prompt = REPO / "bench/prompt_eval/prompts/judge_pairwise_v1.md"
            p = run([
                "python3",
                "bench/prompt_eval/tools/build_run_manifest.py",
                "--phase",
                "phaseB_judge_reliability",
                "--dataset-split",
                "calibration",
                "--dataset-path",
                "bench/prompt_eval/datasets/calibration/judge_pairs.jsonl",
                "--config-path",
                "bench/prompt_eval/config/gate_manifest.v1.json",
                "--judge-prompt",
                str(judge_prompt),
                "--judge-model",
                "judge-model-test",
                "--draft-model",
                "draft-model-test",
                "--out",
                str(out),
            ])
            self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            data = json.loads(out.read_text())
            self.assertEqual(pathlib.Path(data["judge_prompt_path"]), judge_prompt.resolve())
            self.assertEqual(data["judge_model"], "judge-model-test")
            self.assertEqual(data["draft_model"], "draft-model-test")

    def test_phase_orchestrator_smoke_phase0(self):
        cycle_id = f"test-cycle-phase0-{uuid.uuid4().hex[:8]}"
        p = run([
            "python3",
            "bench/prompt_eval/tools/phase_orchestrator.py",
            "--phase",
            "phase0_bootstrap",
            "--cycle-id",
            cycle_id,
            "--repo",
            ".",
        ])
        self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
        data = json.loads(p.stdout)
        self.assertTrue(data["ok"])
        self.assertIn("phase0_bootstrap", data["phase_results"])
        manifest = REPO / "bench/prompt_eval/reports" / cycle_id / "phase0_bootstrap" / "run_manifest.json"
        man_data = json.loads(manifest.read_text())
        self.assertEqual(man_data["cycle_id"], cycle_id)

    def test_phase_orchestrator_phaseb_simulated(self):
        cycle_id = f"test-cycle-phaseb-{uuid.uuid4().hex[:8]}"
        p = run([
            "python3",
            "bench/prompt_eval/tools/phase_orchestrator.py",
            "--phase",
            "phaseB_judge_reliability",
            "--cycle-id",
            cycle_id,
            "--repo",
            ".",
            "--simulate-no-provider",
            "--max-cases",
            "3",
        ])
        self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
        summary = REPO / "bench/prompt_eval/reports" / cycle_id / "phaseB_judge_reliability" / "summary.json"
        data = json.loads(summary.read_text())
        self.assertTrue(data["simulated"])

    def test_calibrate_judge_prefers_v2_on_tie(self):
        module_path = REPO / "bench/prompt_eval/calibrate_judge.py"
        spec = importlib.util.spec_from_file_location("calibrate_judge_mod_tie_break", str(module_path))
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(mod)  # type: ignore[union-attr]

        v1 = str((REPO / "bench/prompt_eval/prompts/judge_pairwise_v1.md").resolve())
        v2 = str((REPO / "bench/prompt_eval/prompts/judge_pairwise_v2.md").resolve())
        v3 = str((REPO / "bench/prompt_eval/prompts/judge_pairwise_v3.md").resolve())
        summaries = [
            {"prompt": v1, "accuracy": 1.0, "invalid_count": 0, "recall_Tie": 1.0},
            {"prompt": v2, "accuracy": 1.0, "invalid_count": 0, "recall_Tie": 1.0},
            {"prompt": v3, "accuracy": 1.0, "invalid_count": 0, "recall_Tie": 1.0},
        ]

        best = mod.select_recommended_prompt(
            summaries,
            preferred_prompt=(REPO / "bench/prompt_eval/prompts/judge_pairwise_v2.md"),
        )
        self.assertEqual(best["prompt"], v2)

    def test_phase_orchestrator_default_judge_prompt_is_v2(self):
        module_path = REPO / "bench/prompt_eval/tools/phase_orchestrator.py"
        sys.path.insert(0, str(module_path.parent))
        spec = importlib.util.spec_from_file_location("phase_orchestrator_mod_default_prompt", str(module_path))
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
        self.assertEqual(mod.DEFAULT_JUDGE_PROMPT, "bench/prompt_eval/prompts/judge_pairwise_v2.md")

    def test_phaseB_passes_max_pairs_to_calibrate_judge(self):
        module_path = REPO / "bench/prompt_eval/tools/phase_orchestrator.py"
        sys.path.insert(0, str(module_path.parent))
        spec = importlib.util.spec_from_file_location("phase_orchestrator_mod_phaseb_max_pairs", str(module_path))
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(mod)  # type: ignore[union-attr]

        provider_contract = {
            "providers": {
                "judge_primary": {
                    "model": "gpt-5.4",
                    "reasoning_effort": "xhigh",
                },
                "judge_shadow": {
                    "runner": "claude",
                    "model": "claude-opus-4-6",
                    "reasoning_effort": "high",
                },
            }
        }

        seen = {"calibrate_cmd": None}
        original_run_cmd = mod.run_cmd

        def fake_run_cmd(cmd, cwd, phase_dir, name, timeout_s=600):  # noqa: ANN001
            if name == "calibrate_judge":
                seen["calibrate_cmd"] = list(cmd)
                out_dir = pathlib.Path(cmd[cmd.index("--out-dir") + 1])
                out_dir.mkdir(parents=True, exist_ok=True)
                out_summary = out_dir / "summary.json"
                out_summary.write_text(
                    json.dumps(
                        {
                            "recommended_prompt": {
                                "prompt": str(REPO / "bench/prompt_eval/prompts/judge_pairwise_v2.md"),
                            }
                        }
                    )
                    + "\n",
                    encoding="utf-8",
                )
            elif name == "assess_judge_symmetry":
                out_dir = pathlib.Path(cmd[cmd.index("--out-dir") + 1])
                out_dir.mkdir(parents=True, exist_ok=True)
                (out_dir / "summary.json").write_text(
                    json.dumps(
                        {
                            "symmetry_rate": 1.0,
                            "forward_repeat_agreement": 1.0,
                            "reverse_repeat_agreement": 1.0,
                        }
                    )
                    + "\n",
                    encoding="utf-8",
                )
            elif name == "generate_judge_audit":
                out_path = pathlib.Path(cmd[cmd.index("--out") + 1])
                out_path.parent.mkdir(parents=True, exist_ok=True)
                out_path.write_text(json.dumps({"mode": "simulated"}) + "\n", encoding="utf-8")
            return {"name": name, "returncode": 0, "elapsed_seconds": 0.0}

        try:
            mod.run_cmd = fake_run_cmd
            with tempfile.TemporaryDirectory() as td:
                phase_dir = pathlib.Path(td) / "phaseB"
                phase_dir.mkdir(parents=True, exist_ok=True)
                result = mod.phase_phaseB(
                    repo=REPO,
                    phase_dir=phase_dir,
                    provider_contract=provider_contract,
                    max_cases=7,
                    timeout=30,
                    judge_repeats=5,
                    simulate_no_provider=False,
                    use_cache=False,
                )
        finally:
            mod.run_cmd = original_run_cmd

        self.assertEqual(result["calibration"]["returncode"], 0)
        self.assertIsNotNone(seen["calibrate_cmd"])
        self.assertIn("--max-pairs", seen["calibrate_cmd"])
        self.assertEqual(seen["calibrate_cmd"][seen["calibrate_cmd"].index("--max-pairs") + 1], "7")
        self.assertIn("--preferred-prompt", seen["calibrate_cmd"])
        self.assertEqual(
            pathlib.Path(seen["calibrate_cmd"][seen["calibrate_cmd"].index("--preferred-prompt") + 1]),
            (REPO / "bench/prompt_eval/prompts/judge_pairwise_v2.md").resolve(),
        )

    def test_phase_orchestrator_all_simulated_strict(self):
        cycle_id = f"test-cycle-all-{uuid.uuid4().hex[:8]}"
        p = run([
            "python3",
            "bench/prompt_eval/tools/phase_orchestrator.py",
            "--phase", "all",
            "--cycle-id", cycle_id,
            "--repo", ".",
            "--simulate-no-provider",
            "--allow-holdout",
            "--max-cases", "3",
            "--pairwise-top-k", "1",
        ])
        self.assertNotEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
        data = json.loads(p.stdout)
        self.assertFalse(data["ok"])
        self.assertEqual(data["phase_results"]["phaseG_promotion"]["status"], "error")

    def test_phase_orchestrator_all_simulated_non_strict(self):
        cycle_id = f"test-cycle-all-ns-{uuid.uuid4().hex[:8]}"
        p = run([
            "python3",
            "bench/prompt_eval/tools/phase_orchestrator.py",
            "--phase", "all",
            "--cycle-id", cycle_id,
            "--repo", ".",
            "--simulate-no-provider",
            "--allow-holdout",
            "--non-strict-promotion",
            "--max-cases", "3",
            "--pairwise-top-k", "1",
        ])
        self.assertNotEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
        data = json.loads(p.stdout)
        self.assertFalse(data["ok"])
        self.assertEqual(data["phase_results"]["phaseG_promotion"]["status"], "error")

    def test_phase_orchestrator_holdout_isolation_fail_fast(self):
        cycle_id = f"test-cycle-holdout-isolation-{uuid.uuid4().hex[:8]}"
        p = run([
            "python3",
            "bench/prompt_eval/tools/phase_orchestrator.py",
            "--phase",
            "phaseF_holdout",
            "--cycle-id",
            cycle_id,
            "--repo",
            ".",
            "--simulate-no-provider",
        ])
        self.assertNotEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
        data = json.loads(p.stdout)
        self.assertFalse(data["ok"])
        self.assertEqual(data["phase_results"]["phaseF_holdout"]["status"], "error")
        holdout_summary = REPO / "bench/prompt_eval/reports" / cycle_id / "phaseF_holdout" / "holdout_eval" / "summary.json"
        self.assertFalse(holdout_summary.exists())

    def test_phase_orchestrator_holdout_attempt_budget_blocks_rerun(self):
        cycle_id = f"test-cycle-holdout-budget-{uuid.uuid4().hex[:8]}"
        p1 = run([
            "python3",
            "bench/prompt_eval/tools/phase_orchestrator.py",
            "--phase",
            "phaseF_holdout",
            "--cycle-id",
            cycle_id,
            "--repo",
            ".",
            "--simulate-no-provider",
            "--allow-holdout",
        ])
        self.assertEqual(p1.returncode, 0, msg=p1.stderr + "\n" + p1.stdout)
        p2 = run([
            "python3",
            "bench/prompt_eval/tools/phase_orchestrator.py",
            "--phase",
            "phaseF_holdout",
            "--cycle-id",
            cycle_id,
            "--repo",
            ".",
            "--simulate-no-provider",
            "--allow-holdout",
        ])
        self.assertNotEqual(p2.returncode, 0, msg=p2.stderr + "\n" + p2.stdout)
        out = json.loads(p2.stdout)
        self.assertFalse(out["ok"])
        self.assertEqual(out["phase_results"]["phaseF_holdout"]["status"], "error")

    def test_phase_orchestrator_phaseD_skip_promptfoo(self):
        cycle_id = f"test-cycle-phased-skip-pf-{uuid.uuid4().hex[:8]}"
        p = run([
            "python3",
            "bench/prompt_eval/tools/phase_orchestrator.py",
            "--phase",
            "phaseD_dev",
            "--cycle-id",
            cycle_id,
            "--repo",
            ".",
            "--simulate-no-provider",
            "--skip-promptfoo",
            "--pairwise-top-k",
            "1",
        ])
        self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
        out = json.loads(p.stdout)
        self.assertTrue(out["ok"])
        summary = REPO / "bench/prompt_eval/reports" / cycle_id / "phaseD_dev" / "summary.json"
        payload = json.loads(summary.read_text())
        self.assertTrue(payload["promptfoo"]["skipped"])

    def test_performance_review(self):
        cycle_id = f"test-cycle-perf-{uuid.uuid4().hex[:8]}"
        p1 = run([
            "python3",
            "bench/prompt_eval/tools/phase_orchestrator.py",
            "--phase",
            "phase0_bootstrap",
            "--cycle-id",
            cycle_id,
            "--repo",
            ".",
        ])
        self.assertEqual(p1.returncode, 0, msg=p1.stderr + "\n" + p1.stdout)
        reports_root = REPO / "bench/prompt_eval/reports" / cycle_id
        out = reports_root / "manual_performance_review.json"
        p2 = run([
            "python3",
            "bench/prompt_eval/tools/performance_review.py",
            "--reports-root",
            str(reports_root),
            "--out",
            str(out),
        ])
        self.assertEqual(p2.returncode, 0, msg=p2.stderr + "\n" + p2.stdout)
        data = json.loads(out.read_text())
        self.assertTrue(data["ok"])

    def test_evaluate_gates_uses_non_tie_floor(self):
        gate = REPO / "bench/prompt_eval/config/gate_manifest.v1.json"
        with tempfile.TemporaryDirectory() as td:
            td_path = pathlib.Path(td)
            cal = td_path / "cal.json"
            sym = td_path / "sym.json"
            phase = td_path / "phase.json"
            out = td_path / "gate_out.json"
            cal.write_text(json.dumps({
                "recommended_prompt": {
                    "n": 100,
                    "accuracy": 0.9,
                    "invalid_count": 0,
                }
            }), encoding="utf-8")
            sym.write_text(json.dumps({
                "symmetry_rate": 0.99,
                "forward_repeat_agreement": 0.95,
                "reverse_repeat_agreement": 0.95,
            }), encoding="utf-8")
            phase.write_text(json.dumps({
                "baseline_variant": "overlay_baseline",
                "results": {
                    "overlay_contract_selfcheck": {
                        "pairwise_vs_baseline": {
                            "n": 500,
                            "wins": 100,
                            "losses": 50,
                            "ties": 350,
                            "non_tie_n": 150,
                            "win_rate": 0.2,
                            "non_loss_rate": 0.9
                        }
                    }
                }
            }), encoding="utf-8")
            p = run([
                "python3",
                "bench/prompt_eval/tools/evaluate_gates.py",
                "--gate-manifest", str(gate),
                "--calibration-summary", str(cal),
                "--symmetry-summary", str(sym),
                "--phase-summary", str(phase),
                "--strict",
                "--out", str(out),
            ])
            self.assertNotEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            o = json.loads(out.read_text())
            self.assertFalse(o["checks"]["promotion_sample_floor"])
            self.assertEqual(o["metrics"]["promotion"]["non_tie_n"], 150)

    def test_evaluate_gates_defaults_to_strict_mode(self):
        gate = REPO / "bench/prompt_eval/config/gate_manifest.v1.json"
        with tempfile.TemporaryDirectory() as td:
            td_path = pathlib.Path(td)
            cal = td_path / "cal.json"
            sym = td_path / "sym.json"
            phase = td_path / "phase.json"
            out = td_path / "gate_out.json"
            cal.write_text(json.dumps({
                "recommended_prompt": {
                    "n": 100,
                    "accuracy": 0.9,
                    "invalid_count": 0,
                }
            }), encoding="utf-8")
            sym.write_text(json.dumps({
                "symmetry_rate": 0.99,
                "forward_repeat_agreement": 0.95,
                "reverse_repeat_agreement": 0.95,
            }), encoding="utf-8")
            phase.write_text(json.dumps({
                "baseline_variant": "overlay_baseline",
                "results": {
                    "overlay_contract_selfcheck": {
                        "pairwise_vs_baseline": {
                            "n": 500,
                            "wins": 100,
                            "losses": 50,
                            "ties": 350,
                            "non_tie_n": 150,
                            "win_rate": 0.2,
                            "non_loss_rate": 0.9
                        }
                    }
                }
            }), encoding="utf-8")
            p = run([
                "python3",
                "bench/prompt_eval/tools/evaluate_gates.py",
                "--gate-manifest", str(gate),
                "--calibration-summary", str(cal),
                "--symmetry-summary", str(sym),
                "--phase-summary", str(phase),
                "--out", str(out),
            ])
            self.assertNotEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            o = json.loads(out.read_text())
            self.assertTrue(o["strict_mode"])

    def test_evaluate_gates_strict_requires_armj_and_armo_artifacts(self):
        gate = REPO / "bench/prompt_eval/config/gate_manifest.v1.json"
        with tempfile.TemporaryDirectory() as td:
            td_path = pathlib.Path(td)
            cal = td_path / "cal.json"
            sym = td_path / "sym.json"
            phase = td_path / "phase.json"
            out = td_path / "gate_out.json"
            cal.write_text(
                json.dumps({"recommended_prompt": {"n": 100, "accuracy": 0.95, "invalid_count": 0}}),
                encoding="utf-8",
            )
            sym.write_text(
                json.dumps({"symmetry_rate": 0.99, "forward_repeat_agreement": 0.95, "reverse_repeat_agreement": 0.95}),
                encoding="utf-8",
            )
            phase.write_text(
                json.dumps(
                    {
                        "baseline_variant": "overlay_baseline",
                        "results": {
                            "overlay_contract_selfcheck": {
                                "pairwise_vs_baseline": {
                                    "n": 500,
                                    "wins": 300,
                                    "losses": 100,
                                    "ties": 100,
                                    "non_tie_n": 400,
                                    "win_rate": 0.6,
                                    "non_loss_rate": 0.8,
                                }
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            p = run(
                [
                    "python3",
                    "bench/prompt_eval/tools/evaluate_gates.py",
                    "--gate-manifest",
                    str(gate),
                    "--calibration-summary",
                    str(cal),
                    "--symmetry-summary",
                    str(sym),
                    "--phase-summary",
                    str(phase),
                    "--strict",
                    "--out",
                    str(out),
                ]
            )
            self.assertNotEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            payload = json.loads(out.read_text(encoding="utf-8"))
            self.assertFalse(payload["checks"]["judge_lock_artifacts_present"])
            self.assertFalse(payload["checks"]["outcome_alignment_artifact_present"])

    def test_generate_judge_audit_simulated(self):
        with tempfile.TemporaryDirectory() as td:
            out = pathlib.Path(td) / "judge_audit.json"
            p = run([
                "python3",
                "bench/prompt_eval/tools/generate_judge_audit.py",
                "--simulate-no-provider",
                "--out",
                str(out),
            ])
            self.assertEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            data = json.loads(out.read_text())
            self.assertEqual(data["version"], "v1")
            self.assertEqual(data["mode"], "simulated")

    def test_validate_run_manifest(self):
        cycle_id = f"manifest-check-{uuid.uuid4().hex[:8]}"
        reports_dir = REPO / "bench/prompt_eval/reports" / cycle_id / "phase0_bootstrap"
        reports_dir.mkdir(parents=True, exist_ok=True)
        manifest = reports_dir / "run_manifest.json"
        p1 = run([
            "python3",
            "bench/prompt_eval/tools/build_run_manifest.py",
            "--phase", "phase0_bootstrap",
            "--cycle-id", cycle_id,
            "--dataset-split", "dev",
            "--dataset-path", "bench/prompt_eval/datasets/dev/cases.jsonl",
            "--config-path", "bench/prompt_eval/config/dev.promptfoo.yaml",
            "--out", str(manifest),
        ])
        self.assertEqual(p1.returncode, 0, msg=p1.stderr + "\n" + p1.stdout)
        p2 = run([
            "python3",
            "bench/prompt_eval/tools/validate_run_manifest.py",
            "--manifest", str(manifest),
            "--schema", "bench/prompt_eval/config/run_manifest.schema.json",
        ])
        self.assertEqual(p2.returncode, 0, msg=p2.stderr + "\n" + p2.stdout)
        out = json.loads(p2.stdout)
        self.assertTrue(out["ok"])

    def test_validate_run_manifest_rejects_missing_schema(self):
        cycle_id = f"manifest-check-missing-schema-{uuid.uuid4().hex[:8]}"
        reports_dir = REPO / "bench/prompt_eval/reports" / cycle_id / "phase0_bootstrap"
        reports_dir.mkdir(parents=True, exist_ok=True)
        manifest = reports_dir / "run_manifest.json"
        p1 = run([
            "python3",
            "bench/prompt_eval/tools/build_run_manifest.py",
            "--phase", "phase0_bootstrap",
            "--cycle-id", cycle_id,
            "--dataset-split", "dev",
            "--dataset-path", "bench/prompt_eval/datasets/dev/cases.jsonl",
            "--config-path", "bench/prompt_eval/config/dev.promptfoo.yaml",
            "--out", str(manifest),
        ])
        self.assertEqual(p1.returncode, 0, msg=p1.stderr + "\n" + p1.stdout)
        p2 = run([
            "python3",
            "bench/prompt_eval/tools/validate_run_manifest.py",
            "--manifest", str(manifest),
            "--schema", "/tmp/definitely_missing_run_manifest_schema.json",
        ])
        self.assertNotEqual(p2.returncode, 0)

    def test_validate_run_manifest_rejects_tampered_dataset_hash(self):
        cycle_id = f"manifest-check-tampered-hash-{uuid.uuid4().hex[:8]}"
        reports_dir = REPO / "bench/prompt_eval/reports" / cycle_id / "phase0_bootstrap"
        reports_dir.mkdir(parents=True, exist_ok=True)
        manifest = reports_dir / "run_manifest.json"
        p1 = run([
            "python3",
            "bench/prompt_eval/tools/build_run_manifest.py",
            "--phase", "phase0_bootstrap",
            "--cycle-id", cycle_id,
            "--dataset-split", "dev",
            "--dataset-path", "bench/prompt_eval/datasets/dev/cases.jsonl",
            "--config-path", "bench/prompt_eval/config/dev.promptfoo.yaml",
            "--out", str(manifest),
        ])
        self.assertEqual(p1.returncode, 0, msg=p1.stderr + "\n" + p1.stdout)
        data = json.loads(manifest.read_text())
        key = next(iter(data["dataset_hashes"].keys()))
        data["dataset_hashes"][key] = "0" * 64
        manifest.write_text(json.dumps(data), encoding="utf-8")
        p2 = run([
            "python3",
            "bench/prompt_eval/tools/validate_run_manifest.py",
            "--manifest", str(manifest),
            "--schema", "bench/prompt_eval/config/run_manifest.schema.json",
        ])
        self.assertNotEqual(p2.returncode, 0)

    def test_build_run_manifest_rejects_missing_inputs(self):
        with tempfile.TemporaryDirectory() as td:
            out = pathlib.Path(td) / "manifest.json"
            p = run([
                "python3",
                "bench/prompt_eval/tools/build_run_manifest.py",
                "--phase", "phase0_bootstrap",
                "--dataset-split", "dev",
                "--dataset-path", "/tmp/definitely_missing_dataset.jsonl",
                "--config-path", "bench/prompt_eval/config/dev.promptfoo.yaml",
                "--out", str(out),
            ])
            self.assertNotEqual(p.returncode, 0)

    def test_extract_promptfoo_usage_totals(self):
        module_path = REPO / "bench/prompt_eval/tools/phase_orchestrator.py"
        sys.path.insert(0, str(module_path.parent))
        spec = importlib.util.spec_from_file_location("phase_orchestrator_mod", str(module_path))
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(mod)  # type: ignore[union-attr]

        with tempfile.TemporaryDirectory() as td:
            path = pathlib.Path(td) / "promptfoo_results.json"
            payload = {
                "results": {
                    "stats": {
                        "tokenUsage": {
                            "prompt": 120,
                            "completion": 30,
                            "total": 150,
                            "completionDetails": {"reasoning": 20},
                        },
                        "cost": 0.01,
                    },
                    "results": [
                        {"cost": 0.02},
                        {"cost": 0.03},
                    ],
                }
            }
            path.write_text(json.dumps(payload), encoding="utf-8")
            usage = mod.extract_usage_totals_from_promptfoo_results(path)

        self.assertEqual(usage["input_tokens"], 120.0)
        self.assertEqual(usage["output_tokens"], 30.0)
        self.assertEqual(usage["total_tokens"], 150.0)
        self.assertEqual(usage["reasoning_tokens"], 20.0)
        self.assertAlmostEqual(usage["cost_usd"], 0.01, places=8)

    def test_extract_promptfoo_usage_totals_row_cost_fallback(self):
        module_path = REPO / "bench/prompt_eval/tools/phase_orchestrator.py"
        sys.path.insert(0, str(module_path.parent))
        spec = importlib.util.spec_from_file_location("phase_orchestrator_mod_fallback", str(module_path))
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(mod)  # type: ignore[union-attr]

        with tempfile.TemporaryDirectory() as td:
            path = pathlib.Path(td) / "promptfoo_results.json"
            payload = {
                "results": {
                    "stats": {
                        "tokenUsage": {
                            "prompt": 50,
                            "completion": 25,
                            "total": 75,
                        }
                    },
                    "results": [
                        {"cost": 0.2},
                        {"cost": 0.3},
                    ],
                }
            }
            path.write_text(json.dumps(payload), encoding="utf-8")
            usage = mod.extract_usage_totals_from_promptfoo_results(path)
        self.assertAlmostEqual(usage["cost_usd"], 0.5, places=8)

    def test_promptfoo_rc100_assertion_failures_softened(self):
        module_path = REPO / "bench/prompt_eval/tools/phase_orchestrator.py"
        sys.path.insert(0, str(module_path.parent))
        spec = importlib.util.spec_from_file_location("phase_orchestrator_mod_rc100_soft", str(module_path))
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(mod)  # type: ignore[union-attr]

        with tempfile.TemporaryDirectory() as td:
            phase_dir = pathlib.Path(td)
            (phase_dir / "promptfoo_results.json").write_text(
                json.dumps(
                    {
                        "results": {
                            "stats": {
                                "successes": 9,
                                "failures": 3,
                                "errors": 0,
                            }
                        }
                    }
                ),
                encoding="utf-8",
            )

            original_run_cmd = mod.run_cmd
            mod.run_cmd = lambda *args, **kwargs: {
                "name": "promptfoo_eval",
                "returncode": 100,
                "elapsed_seconds": 1.0,
            }
            try:
                out = mod.maybe_promptfoo_eval(
                    repo=REPO,
                    phase_dir=phase_dir,
                    config="bench/prompt_eval/config/dev.promptfoo.yaml",
                    split="dev",
                    simulate_no_provider=False,
                )
            finally:
                mod.run_cmd = original_run_cmd

        self.assertEqual(out["returncode"], 0)
        self.assertEqual(out["raw_returncode"], 100)
        self.assertTrue(out["assertion_failures"])
        self.assertEqual(out["result_stats"]["failures"], 3)
        self.assertEqual(out["result_stats"]["errors"], 0)

    def test_promptfoo_rc100_without_results_stays_failure(self):
        module_path = REPO / "bench/prompt_eval/tools/phase_orchestrator.py"
        sys.path.insert(0, str(module_path.parent))
        spec = importlib.util.spec_from_file_location("phase_orchestrator_mod_rc100_hard", str(module_path))
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(mod)  # type: ignore[union-attr]

        with tempfile.TemporaryDirectory() as td:
            phase_dir = pathlib.Path(td)
            original_run_cmd = mod.run_cmd
            mod.run_cmd = lambda *args, **kwargs: {
                "name": "promptfoo_eval",
                "returncode": 100,
                "elapsed_seconds": 1.0,
            }
            try:
                out = mod.maybe_promptfoo_eval(
                    repo=REPO,
                    phase_dir=phase_dir,
                    config="bench/prompt_eval/config/dev.promptfoo.yaml",
                    split="dev",
                    simulate_no_provider=False,
                )
            finally:
                mod.run_cmd = original_run_cmd

        self.assertEqual(out["returncode"], 100)
        self.assertNotIn("assertion_failures", out)

    def test_promptfoo_assertion_failures_block_phase_checks(self):
        module_path = REPO / "bench/prompt_eval/tools/phase_orchestrator.py"
        sys.path.insert(0, str(module_path.parent))
        spec = importlib.util.spec_from_file_location("phase_orchestrator_mod_pf_block", str(module_path))
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(mod)  # type: ignore[union-attr]

        with self.assertRaises(RuntimeError):
            mod.ensure_promptfoo_phase_ok(
                {"returncode": 0, "assertion_failures": True},
                "phaseD",
            )
        with self.assertRaises(RuntimeError):
            mod.ensure_promptfoo_phase_ok({"returncode": 100}, "phaseD")
        # clean result should not raise
        mod.ensure_promptfoo_phase_ok({"returncode": 0}, "phaseD")

    def test_run_codex_prompt_eval_fails_when_all_model_calls_fail(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = pathlib.Path(td) / "eval_out"
            p = run([
                "python3",
                "bench/prompt_eval/run_codex_prompt_eval.py",
                "--repo",
                ".",
                "--cases",
                "bench/prompt_eval/datasets/dev/pilot_cases.jsonl",
                "--max-cases",
                "1",
                "--pairwise-top-k",
                "1",
                "--draft-model",
                "definitely-invalid-model",
                "--judge-model",
                "definitely-invalid-model",
                "--timeout",
                "5",
                "--out-dir",
                str(out_dir),
            ])
            self.assertNotEqual(p.returncode, 0, msg=p.stderr + "\n" + p.stdout)
            out = json.loads(p.stdout)
            self.assertFalse(out["ok"])
            self.assertEqual(out["error"], "all_model_calls_failed")

    def test_promptfoo_cli_provider_codex_usage_mapping(self):
        provider_path = REPO / "bench/prompt_eval/providers/promptfoo_cli_provider.py"
        spec = importlib.util.spec_from_file_location("promptfoo_cli_provider_mod_codex", str(provider_path))
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(mod)  # type: ignore[union-attr]

        class Proc:
            def __init__(self):
                self.returncode = 0
                self.stdout = "\n".join(
                    [
                        json.dumps({"type": "usage", "usage": {"input_tokens": 10, "output_tokens": 4, "total_tokens": 14, "cost_usd": 0.05}}),
                        json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "hello from codex"}}),
                    ]
                )
                self.stderr = ""

        original_run = mod.subprocess.run
        mod.subprocess.run = lambda *args, **kwargs: Proc()
        try:
            out = mod.call_api(
                "test prompt",
                {"config": {"runner": "codex", "model": "gpt-5.4-spark", "reasoning_effort": "xhigh", "timeout_sec": 1}},
                {},
            )
        finally:
            mod.subprocess.run = original_run

        self.assertEqual(out["output"], "hello from codex")
        self.assertEqual(out["tokenUsage"]["prompt"], 10)
        self.assertEqual(out["tokenUsage"]["completion"], 4)
        self.assertEqual(out["tokenUsage"]["total"], 14)
        self.assertAlmostEqual(out["cost"], 0.05, places=8)

    def test_promptfoo_cli_provider_claude_json_result(self):
        provider_path = REPO / "bench/prompt_eval/providers/promptfoo_cli_provider.py"
        spec = importlib.util.spec_from_file_location("promptfoo_cli_provider_mod_claude", str(provider_path))
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(mod)  # type: ignore[union-attr]

        class Proc:
            def __init__(self):
                self.returncode = 0
                self.stdout = json.dumps(
                    [
                        {
                            "type": "result",
                            "result": "hello from claude",
                            "usage": {"input_tokens": 12, "output_tokens": 8, "total_tokens": 20},
                            "total_cost_usd": 0.12,
                        }
                    ]
                )
                self.stderr = ""

        original_run = mod.subprocess.run
        mod.subprocess.run = lambda *args, **kwargs: Proc()
        try:
            out = mod.call_api(
                "test prompt",
                {"config": {"runner": "claude", "model": "claude-opus-4-6", "reasoning_effort": "high", "timeout_sec": 1}},
                {},
            )
        finally:
            mod.subprocess.run = original_run

        self.assertEqual(out["output"], "hello from claude")
        self.assertEqual(out["tokenUsage"]["prompt"], 12)
        self.assertEqual(out["tokenUsage"]["completion"], 8)
        self.assertEqual(out["tokenUsage"]["total"], 20)
        self.assertAlmostEqual(out["cost"], 0.12, places=8)

    def test_promptfoo_cli_provider_auggie_json_result(self):
        provider_path = REPO / "bench/prompt_eval/providers/promptfoo_cli_provider.py"
        spec = importlib.util.spec_from_file_location("promptfoo_cli_provider_mod_auggie", str(provider_path))
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(mod)  # type: ignore[union-attr]

        class Proc:
            def __init__(self):
                self.returncode = 0
                self.stdout = '\n'.join([
                    'Applying --max-turns override: 1',
                    json.dumps({"type": "result", "result": '\n{"winner":"B","confidence":"High","rationale":"better"}\n'}),
                ])
                self.stderr = ""

        original_run = mod.subprocess.run
        mod.subprocess.run = lambda *args, **kwargs: Proc()
        try:
            out = mod.call_api(
                "test prompt",
                {"config": {"runner": "auggie", "model": "gpt5.4", "reasoning_effort": "high", "timeout_sec": 1}},
                {},
            )
        finally:
            mod.subprocess.run = original_run

        self.assertEqual(out["output"], '{"winner":"B","confidence":"High","rationale":"better"}')

    def test_run_provider_exec_supports_auggie(self):
        runner_path = REPO / "bench/prompt_eval/run_codex_prompt_eval.py"
        spec = importlib.util.spec_from_file_location("run_codex_prompt_eval_mod_auggie", str(runner_path))
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        sys.path.insert(0, str(REPO / "bench/prompt_eval"))
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        try:
            spec.loader.exec_module(mod)  # type: ignore[union-attr]
        finally:
            sys.path.pop(0)

        class Proc:
            def __init__(self):
                self.returncode = 0
                self.stdout = '\n'.join([
                    'Applying --max-turns override: 1',
                    json.dumps({"type": "result", "result": '\n{"winner":"A","confidence":"Medium","rationale":"clearer"}\n'}),
                ])
                self.stderr = ""

        original_run = mod.subprocess.run
        mod.subprocess.run = lambda *args, **kwargs: Proc()
        try:
            text, events = mod.run_provider_exec(
                prompt="judge this",
                provider={"runner": "auggie", "model": "gpt5.4", "reasoning_effort": "high"},
                timeout_s=1,
            )
        finally:
            mod.subprocess.run = original_run

        self.assertEqual(text, '{"winner":"A","confidence":"Medium","rationale":"clearer"}')
        self.assertEqual(events, [])


if __name__ == "__main__":
    unittest.main()
