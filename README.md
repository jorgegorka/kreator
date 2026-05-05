# Kreator

Kreator is a Ruby 3.2+ headless agent runtime and CLI.

```sh
exe/kreator --provider openai --model gpt-4o-mini "Summarize this repo"
```

Set `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` for the matching provider. Provider base URLs can be overridden with `OPENAI_BASE_URL` and `ANTHROPIC_BASE_URL`.
