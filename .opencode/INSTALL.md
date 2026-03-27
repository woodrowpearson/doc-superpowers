# Installing doc-superpowers for OpenCode

## Quick Install

Add to your project's `opencode.json`:

```json
{
  "plugin": ["doc-superpowers@git+https://github.com/woodrowpearson/doc-superpowers.git"]
}
```

Or for a specific version:

```json
{
  "plugin": ["doc-superpowers@git+https://github.com/woodrowpearson/doc-superpowers.git#v2.4.0"]
}
```

## Alternative: Local Install

```bash
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.config/opencode/plugins/doc-superpowers
```

Then add to `opencode.json`:

```json
{
  "skills": {
    "paths": ["~/.config/opencode/plugins/doc-superpowers"]
  }
}
```

## Verify

Start a new OpenCode session. Try:

```
audit my project's documentation
```
