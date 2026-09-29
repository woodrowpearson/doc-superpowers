import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..", "..");

export const DocSuperpowersPlugin = async ({ directory }) => {
  // The skill is written with Claude Code's tool names; this file maps them to
  // OpenCode's. Read it once, when OpenCode loads the plugin — not on every
  // LLM request.
  const toolMappings = readFileSync(
    join(ROOT, "references", "tool-mappings.md"),
    "utf-8"
  );

  return {
    config: async (config) => {
      // Register the plugin root (it holds skills/doc-superpowers/SKILL.md)
      // as a skills path
      config.skills = config.skills || {};
      config.skills.paths = config.skills.paths || [];
      if (!config.skills.paths.includes(ROOT)) {
        config.skills.paths.push(ROOT);
      }
    },

    // output.system is a string[] (OpenCode's Hooks interface,
    // packages/plugin/src/index.ts): add one entry to it, in place. Replacing
    // it — with a string or a new array — drops what OpenCode and other plugins
    // put there, and breaks a plugin that pushes after this one.
    "experimental.chat.system.transform": async (_input, output) => {
      if (!Array.isArray(output.system)) return;
      if (!output.system.includes(toolMappings)) {
        output.system.push(toolMappings);
      }
    },
  };
};
