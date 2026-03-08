import importlib.util
import pathlib
import subprocess
import sys
import unittest

MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "run_codex_prompt_eval.py"
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("run_codex_prompt_eval", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class EvalRunnerHelperTests(unittest.TestCase):
    def test_consensus_2_of_3(self):
        winner, ok = MODULE.consensus_2_of_3(["A", "A", "B"])
        self.assertEqual(winner, "A")
        self.assertTrue(ok)

        winner, ok = MODULE.consensus_2_of_3(["A", "B", "Tie"])
        self.assertEqual(winner, "Tie")
        self.assertFalse(ok)

    def test_score_margin(self):
        self.assertAlmostEqual(MODULE.score_margin_from_decision({"score_a": 0.7, "score_b": 0.4}), 0.3, places=6)
        self.assertIsNone(MODULE.score_margin_from_decision({"score_a": 0.7}))

    def test_add_usage_normalizes_promptfoo_and_cached_tokens(self):
        acc = {}
        MODULE.add_usage(
            acc,
            {
                "prompt": 120,
                "completion": 30,
                "total": 150,
                "input_tokens_details": {"cached_tokens": 60},
                "cost_usd": 0.004,
            },
        )
        self.assertEqual(acc.get("input_tokens"), 120.0)
        self.assertEqual(acc.get("output_tokens"), 30.0)
        self.assertEqual(acc.get("total_tokens"), 150.0)
        self.assertEqual(acc.get("cached_input_tokens"), 60.0)
        self.assertAlmostEqual(acc.get("cost_usd", 0.0), 0.004, places=9)

    def test_extract_last_json_object_with_log_noise(self):
        raw = (
            "Loaded cached credentials.\\n"
            "Some startup logs...\\n"
            '{"session_id":"x","response":"{\\"winner\\":\\"Tie\\"}","stats":{"models":{"gemini-x":{"tokens":{"prompt":10,"candidates":2,"total":12,"cached":3}}}}}\\n'
            "trailing non-json noise\\n"
        )
        obj = MODULE._extract_last_json_object(raw)
        self.assertIsInstance(obj, dict)
        usage = MODULE._extract_gemini_usage(obj)
        self.assertEqual(usage.get("input_tokens"), 10)
        self.assertEqual(usage.get("output_tokens"), 2)
        self.assertEqual(usage.get("total_tokens"), 12)
        self.assertEqual(usage.get("cached_input_tokens"), 3)

    def test_is_timeout_exception(self):
        self.assertTrue(MODULE._is_timeout_exception(subprocess.TimeoutExpired(cmd="x", timeout=1)))
        self.assertFalse(MODULE._is_timeout_exception(RuntimeError("timed out in log text only")))

    def test_family_best_variant_requires_superiority(self):
        rows = [
            {"preset": "coding", "variant": "overlay_contract_selfcheck", "judge_decision": {"winner": "B"}, "repeat_votes": ["B"]},
            {"preset": "coding", "variant": "overlay_precision_guard", "judge_decision": {"winner": "Tie"}, "repeat_votes": ["Tie"]},
        ]
        out = MODULE.summarize_pairwise_by_family(rows, baseline_variant="overlay_baseline", repeats=1)
        self.assertIn("coding", out)
        self.assertIsNone(out["coding"]["best_variant"])

    def test_one_sided_binom_pvalue_large_n_no_overflow(self):
        p = MODULE.one_sided_binom_pvalue(wins=1100, total=1200)
        self.assertGreaterEqual(p, 0.0)
        self.assertLessEqual(p, 1.0)

    def test_should_trigger_escalation_on_critical_without_uncertainty(self):
        self.assertTrue(
            MODULE.should_trigger_escalation(
                [],
                escalation_on_critical=True,
                case_is_critical=True,
            )
        )
        self.assertFalse(
            MODULE.should_trigger_escalation(
                [],
                escalation_on_critical=False,
                case_is_critical=True,
            )
        )


if __name__ == "__main__":
    unittest.main()
