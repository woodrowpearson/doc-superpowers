import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..", "..");

export const DocSuperpowersPlugin = async ({ directory }) => {
  return {
    config: async (config) => {
      // Register the skill root so OpenCode discovers SKILL.md
      config.skills = config.skills || {};
      config.skills.paths = config.skills.paths || [];
      if (!config.skills.paths.includes(ROOT)) {
        config.skills.paths.push(ROOT);
      }
    },

    "experimental.chat.system.transform": async (input, output) => {
      // Inject the full tool mapping reference so the skill's Claude Code
      // tool references get translated to OpenCode equivalents
      const toolMappings = readFileSync(
        join(ROOT, "references", "tool-mappings.md"),
        "utf-8"
      );

      output.system = output.system || "";
      output.system += "\n\n" + toolMappings;
    },
  };
};
