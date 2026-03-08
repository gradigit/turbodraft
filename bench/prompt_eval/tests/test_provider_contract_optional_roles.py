import json
import importlib.util
import pathlib
import tempfile
import unittest

MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "tools" / "provider_contract.py"
SPEC = importlib.util.spec_from_file_location("provider_contract", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)

load_provider_contract = MODULE.load_provider_contract
ProviderContractError = MODULE.ProviderContractError


class ProviderContractOptionalRoleTests(unittest.TestCase):
    def test_optional_roles_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = pathlib.Path(tmp)
            contract = {
                "version": "v1",
                "providers": {
                    "drafting": {"runner": "codex", "model": "gpt-5.3-codex-spark", "reasoning_effort": "xhigh"},
                    "judge_primary": {"runner": "codex", "model": "gpt-5.4", "reasoning_effort": "xhigh"},
                    "judge_shadow": {"runner": "claude", "model": "claude-opus-4-6", "reasoning_effort": "high"},
                    "judge_secondary": {"runner": "gemini", "model": "gemini-3.1-pro-preview", "reasoning_effort": "high"},
                },
            }
            path = repo / "providers.v1.json"
            path.write_text(json.dumps(contract), encoding="utf-8")

            out = load_provider_contract(repo, "providers.v1.json")
            self.assertIn("judge_secondary", out["providers"])
            self.assertEqual(out["providers"]["judge_secondary"]["runner"], "gemini")

    def test_required_roles_still_enforced(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = pathlib.Path(tmp)
            contract = {
                "version": "v1",
                "providers": {
                    "drafting": {"runner": "codex", "model": "gpt-5.3-codex-spark", "reasoning_effort": "xhigh"},
                    "judge_primary": {"runner": "codex", "model": "gpt-5.4", "reasoning_effort": "xhigh"},
                },
            }
            path = repo / "providers.v1.json"
            path.write_text(json.dumps(contract), encoding="utf-8")
            with self.assertRaises(ProviderContractError):
                load_provider_contract(repo, "providers.v1.json")


if __name__ == "__main__":
    unittest.main()
