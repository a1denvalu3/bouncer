import assert from "node:assert/strict";
import test from "node:test";
import numesReasoning from "../scripts/numes_reasoning.mjs";

const hooks = await numesReasoning();
const model = {
  providerID: "numes",
  api: { npm: "@openrouter/ai-sdk-provider" },
  capabilities: { reasoning: true },
  variants: { high: { reasoning: { effort: "high" } } },
};

test("translates supported reasoning effort", async () => {
  const options = { reasoningEffort: "high", temperature: 0.5 };
  await hooks["chat.params"]({ model }, { options });
  assert.deepEqual(options, { reasoning: { effort: "high" }, temperature: 0.5 });
});

test("drops unsupported effort and defaults on non-reasoning models", async () => {
  for (const [candidate, effort] of [
    [model, "xhigh"],
    [{ ...model, capabilities: { reasoning: false } }, "high"],
  ]) {
    const options = { reasoningEffort: effort };
    await hooks["chat.params"]({ model: candidate }, { options });
    assert.deepEqual(options, {});
  }
});

test("preserves an explicit reasoning setting", async () => {
  const options = { reasoningEffort: "high", reasoning: { effort: "low" } };
  await hooks["chat.params"]({ model }, { options });
  assert.deepEqual(options, { reasoning: { effort: "low" } });
});

test("leaves other providers and adapters unchanged", async () => {
  for (const candidate of [
    { ...model, providerID: "openrouter" },
    { ...model, api: { npm: "@ai-sdk/openai" } },
  ]) {
    const options = { reasoningEffort: "high" };
    await hooks["chat.params"]({ model: candidate }, { options });
    assert.deepEqual(options, { reasoningEffort: "high" });
  }
});
