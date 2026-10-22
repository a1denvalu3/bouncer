// Translate OpenCode's defaults to Numes's reasoning format.
// https://numes.ai/docs/integrations/coding-agents#reasoning-effort-in-opencode
export default async function numesReasoning() {
  return {
    "chat.params": async ({ model }, { options }) => {
      if (
        model.providerID !== "numes" ||
        model.api.npm !== "@openrouter/ai-sdk-provider"
      ) return;

      const effort = options.reasoningEffort;
      delete options.reasoningEffort;
      if (
        model.capabilities.reasoning &&
        effort !== undefined &&
        model.variants?.[effort] !== undefined &&
        options.reasoning === undefined
      ) {
        options.reasoning = { effort };
      }
    },
  };
}
