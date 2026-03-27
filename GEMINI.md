@./SKILL.md
@./references/tool-mappings.md

# Gemini CLI Notes

This skill was written for Claude Code. Key differences in Gemini CLI:

- **No subagent dispatch**: Where the skill references `Task` or `Agent` tools for parallel agents, use sequential execution instead. Work through audit scopes one at a time.
- **Tool names differ**: See the tool mappings loaded above. Use `read_file` instead of `Read`, `write_file` instead of `Write`, etc.
- **Skill activation**: Skills activate via `activate_skill` tool, not `Skill` tool.
- **No TodoWrite**: Use `write_todos` instead.
