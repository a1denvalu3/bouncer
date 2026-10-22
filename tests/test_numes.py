import contextlib
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

from scripts import numes_config


ROOT = Path(__file__).resolve().parents[1]
MODEL = {
    "id": "openai/example",
    "name": "Example",
    "context_length": 200000,
    "top_provider": {"max_completion_tokens": 16384},
    "supported_parameters": ["tools", "reasoning", "temperature"],
    "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["text"]},
    "reasoning": {"supported_efforts": ["low", "high"]},
    "billing_currency": "USD",
    "pricing": {"prompt": "0.000002", "completion": "0.000008", "input_cache_read": "0.000001"},
}


class NumesConfigTests(unittest.TestCase):
    def setUp(self):
        self.model = copy.deepcopy(MODEL)

    def configure(self, config=None):
        return numes_config.build_config(
            {"data": [self.model]}, self.model["id"], config if config is not None else {}
        )

    def definition(self):
        return self.configure()["provider"]["numes"]["models"][self.model["id"]]

    def test_provider_capabilities_and_usd_costs(self):
        config = self.configure()
        provider = config["provider"]["numes"]
        self.assertEqual(provider["npm"], "@openrouter/ai-sdk-provider")
        self.assertEqual(provider["options"], {
            "baseURL": "https://api.numes.ai/api/v1", "apiKey": "{env:NUMES_API_KEY}"
        })
        model = provider["models"][self.model["id"]]
        self.assertEqual(model["limit"], {"context": 200000, "output": 16384})
        self.assertTrue(model["attachment"])
        self.assertTrue(model["temperature"])
        self.assertEqual(model["modalities"]["input"], ["text", "image"])
        self.assertEqual(model["variants"], {
            "low": {"reasoning": {"effort": "low"}},
            "high": {"reasoning": {"effort": "high"}},
        })
        self.assertEqual(model["cost"], {"input": 2, "output": 8, "cache_read": 1, "cache_write": 0})
        self.assertTrue(Path(config["plugin"][0].removeprefix("file://")).is_file())

    def test_preserves_existing_settings_and_plugins(self):
        config = {"permission": {"edit": "allow"}, "provider": {"other": {}}, "plugin": ["existing"]}
        result = self.configure(config)
        self.assertEqual(result["permission"], {"edit": "allow"})
        self.assertIn("other", result["provider"])
        self.assertEqual(result["plugin"][0], "existing")
        self.assertEqual(self.configure(result)["plugin"], result["plugin"])
        self.assertEqual(len(result["plugin"]), 2)

    def test_output_fallback_and_api_cap(self):
        for top_provider, expected in ((None, 8192), ({}, 8192),
                                       ({"max_completion_tokens": None}, 8192),
                                       ({"max_completion_tokens": 200000}, 131072)):
            with self.subTest(top_provider=top_provider):
                self.model["top_provider"] = top_provider
                self.assertEqual(self.definition()["limit"]["output"], expected)

    def test_btc_and_unknown_currency_omit_usd_costs(self):
        for currency in ("BTC", None):
            self.model["billing_currency"] = currency
            self.assertNotIn("cost", self.definition())

    def test_separate_input_limit_and_small_context(self):
        self.model["max_input_tokens"] = 100000
        self.assertEqual(self.definition()["limit"]["input"], 100000)
        self.model["context_length"] = 4096
        self.assertEqual(self.definition()["limit"], {
            "context": 4096, "input": 4096, "output": 4096,
        })

    def test_non_reasoning_text_model(self):
        self.model["supported_parameters"] = ["tools"]
        self.model["architecture"]["input_modalities"] = ["text"]
        model = self.definition()
        for capability in ("reasoning", "temperature", "attachment"):
            self.assertFalse(model[capability])
        self.assertNotIn("variants", model)

    def test_rejects_missing_model_tool_support_and_invalid_limits(self):
        with self.assertRaisesRegex(ValueError, "unavailable"):
            numes_config.build_config({"data": []}, "missing/model", {})
        self.model["supported_parameters"] = []
        with self.assertRaisesRegex(ValueError, "tool calling"):
            self.configure()
        self.model["supported_parameters"] = ["tools"]
        self.model["context_length"] = 0
        with self.assertRaisesRegex(ValueError, "token limits"):
            self.configure()

    def test_catalog_request_and_secret_handling(self):
        env = {"NUMES_API_KEY": "secret-test-key", "OPENCODE_MODEL": "numes/openai/example"}
        stdout = io.StringIO()
        response = io.StringIO(json.dumps({"data": [self.model]}))
        with patch.dict(os.environ, env, clear=True), \
                patch.object(numes_config, "urlopen") as fetch, contextlib.redirect_stdout(stdout):
            fetch.return_value.__enter__.return_value = response
            self.assertEqual(numes_config.main(), 0)
        request = fetch.call_args.args[0]
        self.assertEqual(request.full_url, f"{numes_config.BASE_URL}/models?supported_parameters=tools")
        self.assertEqual(request.get_header("Authorization"), "Bearer secret-test-key")
        self.assertEqual(fetch.call_args.kwargs["timeout"], 30)
        self.assertNotIn("secret-test-key", stdout.getvalue())
        self.assertIn("numes", json.loads(stdout.getvalue())["provider"])

    def test_missing_key_does_not_make_a_request(self):
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(numes_config, "urlopen") as fetch, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(numes_config.main(), 1)
            fetch.assert_not_called()

    def test_catalog_errors_produce_no_config(self):
        failures = (
            HTTPError("https://api.numes.ai", 401, "Unauthorized", {}, None),
            URLError("unreachable"),
            json.JSONDecodeError("invalid JSON", "", 0),
        )
        for failure in failures:
            with self.subTest(failure=failure), \
                    patch.dict(os.environ, {"NUMES_API_KEY": "secret-test-key"}, clear=True), \
                    patch.object(numes_config, "urlopen", side_effect=failure), \
                    contextlib.redirect_stdout(io.StringIO()) as stdout, \
                    contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(numes_config.main(), 1)
                self.assertEqual(stdout.getvalue(), "")
                self.assertNotIn("secret-test-key", stderr.getvalue())


class RunnerTests(unittest.TestCase):
    def run_runner(self, model, fail_config=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            for name in ("dhclient", "gh"):
                (path / name).write_text("#!/bin/bash\nexit 0\n")
            (path / "python3").write_text(
                '#!/bin/bash\nif [ "$FAIL_CONFIG" = 1 ]; then exit 1; fi\n'
                'printf \'%s\\n\' \'{"provider":{"numes":{}}}\'\n'
            )
            (path / "opencode").write_text(
                f"#!{sys.executable}\n"
                "import json, os, pathlib, sys\n"
                "with open('calls.jsonl', 'a') as log:\n"
                "    log.write(json.dumps({'args': sys.argv[1:], "
                "'config': os.environ.get('OPENCODE_CONFIG_CONTENT')}) + '\\n')\n"
                "if sys.argv[1] == 'run':\n"
                "    pathlib.Path(os.environ['PR_REPORT']).write_text('report')\n"
                "else:\n"
                "    print('Total Cost $0.10\\nInput 100\\nOutput 20\\nCache Read 0')\n"
            )
            for executable in path.iterdir():
                executable.chmod(0o755)
            (path / ".opencode_discovery_prompt").write_text("discover")
            (path / ".opencode_verifier_prompt").write_text("verify")
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/opencode_runner.sh")], cwd=path,
                env={"PATH": f"{path}:{os.defpath}", "OPENCODE_MODEL": model,
                     "PR_REPORT": str(path / "report"), "PR_METRICS": str(path / "metrics.json"),
                     "FAIL_CONFIG": str(int(fail_config))},
                capture_output=True, text=True, timeout=10,
            )
            log = path / "calls.jsonl"
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            metrics = json.loads((path / "metrics.json").read_text()) if result.returncode == 0 else None
            return result, calls, metrics

    def test_numes_config_reaches_discovery_verification_and_metrics(self):
        result, calls, metrics = self.run_runner("numes/openai/example")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([call["args"][0] for call in calls], ["run", "run", "stats"])
        for call in calls:
            self.assertIn("numes", json.loads(call["config"])["provider"])
        self.assertEqual(calls[0]["args"][2], "numes/openai/example")
        self.assertEqual(metrics["cost"], "$0.10")

    def test_failed_configuration_stops_before_discovery(self):
        result, calls, _ = self.run_runner("numes/openai/example", fail_config=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_other_providers_skip_numes_configuration(self):
        result, calls, _ = self.run_runner("openrouter/author/model", fail_config=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(all(call["config"] is None for call in calls))


if __name__ == "__main__":
    unittest.main()
