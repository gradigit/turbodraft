import importlib.util
import pathlib
import sys
import unittest

TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1] / "tools"
MODULE_PATH = TOOLS_DIR / "run_judge_quality_calibration.py"
SCHEMA_PATH = pathlib.Path(__file__).resolve().parents[1] / "schemas" / "judge_decision.schema.json"

sys.path.insert(0, str(TOOLS_DIR))
SPEC = importlib.util.spec_from_file_location("run_judge_quality_calibration", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class JudgeCalibrationHelperTests(unittest.TestCase):
    def test_looks_like_invalid_judge_output(self) -> None:
        self.assertTrue(MODULE.looks_like_invalid_judge_output("JSON parse failed"))
        self.assertTrue(MODULE.looks_like_invalid_judge_output("schema validation error"))
        self.assertFalse(MODULE.looks_like_invalid_judge_output("network temporarily unavailable"))

    def test_parse_error_counts_toward_invalid_json_rate(self) -> None:
        row = {
            "id": "case1",
            "expected_winner": "A",
            "split": "dev",
            "error_tags": [],
            "draft_prompt": "draft",
            "candidate_a": "A",
            "candidate_b": "B",
            "preset_family": "coding",
        }
        original = MODULE.run_codex_judge

        def fake_run_codex_judge(**_: object):
            raise RuntimeError("JSON parse failed: malformed payload")

        MODULE.run_codex_judge = fake_run_codex_judge
        try:
            metrics, by_case, usage = MODULE.evaluate_run(
                run_index=0,
                rows=[row],
                prompt_template="Preset: {{preset}}\nDraft: {{draft_prompt}}\nA: {{candidate_a}}\nB: {{candidate_b}}",
                model="gpt-5.4",
                reasoning_effort="xhigh",
                schema_path=SCHEMA_PATH,
                timeout_s=30,
                simulate_no_provider=False,
                critical_tags=set(),
                margin_labels={},
            )
        finally:
            MODULE.run_codex_judge = original

        self.assertEqual(len(by_case), 1)
        self.assertEqual(usage, {})
        self.assertAlmostEqual(float(metrics["runtime_error_rate"]), 1.0, places=6)
        self.assertAlmostEqual(float(metrics["invalid_json_rate"]), 1.0, places=6)


if __name__ == "__main__":
    unittest.main()
