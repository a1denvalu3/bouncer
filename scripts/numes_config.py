#!/usr/bin/env python3
"""Build OpenCode's Numes provider from its authenticated model catalog.

See https://numes.ai/docs/integrations/coding-agents for the provider contract.
"""

import json
import os
from pathlib import Path
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


BASE_URL = "https://api.numes.ai/api/v1"


def build_config(catalog, model_id, config):
    model = next((m for m in catalog["data"] if m["id"] == model_id), None)
    if model is None:
        raise ValueError(f"Numes model '{model_id}' is unavailable to this API key")

    parameters = model["supported_parameters"]
    if "tools" not in parameters:
        raise ValueError(f"Numes model '{model_id}' does not support tool calling")

    context = model["context_length"]
    output = (model.get("top_provider") or {}).get("max_completion_tokens") or 8192
    if not isinstance(context, int) or context <= 0 or not isinstance(output, int) or output <= 0:
        raise ValueError("Numes returned invalid model token limits")

    architecture = model["architecture"]
    input_modalities = architecture["input_modalities"]
    definition = {
        "name": model["name"],
        "tool_call": True,
        "reasoning": "reasoning" in parameters,
        "temperature": "temperature" in parameters,
        "attachment": any(m in input_modalities for m in ("image", "file")),
        "modalities": {"input": input_modalities, "output": architecture["output_modalities"]},
        "limit": {"context": context, "output": min(output, context, 131072)},
    }
    if model.get("max_input_tokens"):
        definition["limit"]["input"] = min(model["max_input_tokens"], context)
    if definition["reasoning"]:
        definition["variants"] = {
            effort: {"reasoning": {"effort": effort}}
            for effort in (model.get("reasoning") or {}).get("supported_efforts", [])
        }

    # OpenCode expects USD per million tokens; BTC prices are in satoshis.
    if model.get("billing_currency") == "USD":
        pricing = model["pricing"]
        definition["cost"] = {
            field: float(pricing.get(source) or 0) * 1_000_000
            for field, source in (
                ("input", "prompt"), ("output", "completion"),
                ("cache_read", "input_cache_read"), ("cache_write", "input_cache_write"),
            )
        }

    config.setdefault("provider", {})["numes"] = {
        "npm": "@openrouter/ai-sdk-provider",
        "name": "Numes",
        "options": {"baseURL": BASE_URL, "apiKey": "{env:NUMES_API_KEY}"},
        "models": {model_id: definition},
    }
    plugin = Path(__file__).with_name("numes_reasoning.mjs").as_uri()
    plugins = config.setdefault("plugin", [])
    if plugin not in plugins:
        plugins.append(plugin)
    return config


def main():
    api_key = os.environ.get("NUMES_API_KEY")
    if not api_key:
        print("ERROR: NUMES_API_KEY must be set for numes/ models.", file=sys.stderr)
        return 1

    try:
        request = Request(
            f"{BASE_URL}/models?supported_parameters=tools",
            headers={"Authorization": f"Bearer {api_key}"},
        )
        with urlopen(request, timeout=30) as response:
            catalog = json.load(response)
        config = json.loads(os.environ.get("OPENCODE_CONFIG_CONTENT") or "{}")
        model_id = os.environ["OPENCODE_MODEL"].removeprefix("numes/")
        print(json.dumps(build_config(catalog, model_id, config)))
    except HTTPError as error:
        print(f"ERROR: Numes model catalog request failed (HTTP {error.code}).", file=sys.stderr)
        return 1
    except (URLError, OSError):
        print("ERROR: Unable to fetch the Numes model catalog.", file=sys.stderr)
        return 1
    except (ValueError, KeyError, TypeError) as error:
        print(f"ERROR: Invalid Numes configuration: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
