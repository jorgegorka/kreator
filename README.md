# Kreator

Kreator is a Ruby 3.2+ headless agent runtime and CLI for running coding-agent style workflows from a terminal, script, or JSONL RPC client. It streams assistant output, can call local tools, persists conversations as append-only sessions, and supports project resources, prompt templates, skills, and local Ruby plugins.

```sh
kreator --provider openai --model gpt-4o-mini "Summarize this repo"
```

## Requirements

- Ruby 3.2 or newer.
- Bundler for local development.
- Optional: `tmux` for model-orchestrated child agents.
- A provider API key:
  - `OPENAI_API_KEY` for `--provider openai`
  - `ANTHROPIC_API_KEY` for `--provider anthropic`
  - `OPENROUTER_API_KEY` for `--provider openrouter`

Optional provider base URLs can be overridden with `OPENAI_BASE_URL`, `ANTHROPIC_BASE_URL`, and `OPENROUTER_BASE_URL`.

## Installation

Install dependencies for local development:

```sh
bundle install
```

Install `tmux` if you want the model to spawn and monitor child agents:

```sh
brew install tmux
# or on Debian/Ubuntu:
sudo apt-get install tmux
```

Run the CLI from the checkout:

```sh
bundle exec ruby exe/kreator "Explain the project structure"
```

Build and install the gem locally:

```sh
gem build kreator.gemspec
gem install ./kreator-0.2.0.gem
```

After installing the gem, use the executable directly:

```sh
kreator "Summarize this repo"
```

When Kreator is published to RubyGems, it can be installed with:

```sh
gem install kreator
```

## Configuration

Kreator defaults to the OpenAI provider and the `gpt-4o-mini` model.

| Setting | Purpose | Default |
| --- | --- | --- |
| `KREATOR_PROVIDER` | Default provider name, `openai`, `anthropic`, or `openrouter`. | `openai` |
| `KREATOR_MODEL` | Default model name. | `gpt-4o-mini` |
| `KREATOR_HOME` | Global resource home for prompts, skills, plugins, and agent records. | `~/.kreator` |
| `KREATOR_COMPACT_THRESHOLD` | Character threshold for automatic session compaction. | unset |
| `KREATOR_APPROVAL_POLICY` | Built-in tool approval policy: `auto`, `prompt`, or `deny`. | `auto` |
| `KREATOR_PLUGIN_TOOL_POLICY` | Plugin tool approval policy: `auto`, `prompt`, or `deny`. | `prompt` |
| `KREATOR_AGENT_EXECUTABLE` | Executable path used by child agents started through the `agent` tool. | bundled `exe/kreator` |
| `OPENAI_API_KEY` | API key for the OpenAI provider. | required for OpenAI |
| `OPENAI_BASE_URL` | OpenAI-compatible API base URL. | `https://api.openai.com/v1` |
| `ANTHROPIC_API_KEY` | API key for the Anthropic provider. | required for Anthropic |
| `ANTHROPIC_BASE_URL` | Anthropic API base URL. | `https://api.anthropic.com/v1` |
| `OPENROUTER_API_KEY` | API key for the OpenRouter provider. | required for OpenRouter |
| `OPENROUTER_BASE_URL` | OpenRouter API base URL. | `https://openrouter.ai/api/v1` |
| `OPENROUTER_SITE_URL` | Optional OpenRouter app attribution URL. | unset |
| `OPENROUTER_APP_NAME` | Optional OpenRouter app attribution title. | unset |

## Basic Usage

Run a prompt and stream the assistant response:

```sh
kreator "Find the main entry points in this codebase"
```

Choose a provider and model:

```sh
kreator --provider anthropic --model claude-3-7-sonnet-latest "Review the CLI design"
kreator --provider openrouter --model openrouter/auto "Review the CLI design"
```

OpenRouter uses the same chat-completions flow as the OpenAI provider. Set `OPENROUTER_SITE_URL` and `OPENROUTER_APP_NAME` when you want requests attributed in OpenRouter dashboards.

Disable local tools for a pure chat-style response:

```sh
kreator --no-tools "Explain what this gem does"
```

Limit the enabled tools:

```sh
kreator --tools read,grep,find,ls,bash,agent "Inspect the tests and tell me how to run them"
```

Emit structured JSON instead of streaming plain text:

```sh
kreator --json --no-session "Return a short project summary"
```

Start interactive mode by running Kreator with no prompt in a TTY:

```sh
kreator
```

Interactive mode supports chat-style prompting plus slash commands such as `/help`, `/new`, `/resume`, `/model`, `/session`, `/prompt`, `/plugins`, `/plugin`, `/compact`, `/fork`, `/exit`, and `:q`.

## Interactive Mode

The interactive TUI includes a welcome panel, command autocomplete, skill autocomplete, model and session pickers, collapsible tool output, and a context meter based on the selected provider and model. In the TUI, Enter sends the current prompt, Alt+Enter inserts a newline, Ctrl+s saves a draft while you run another prompt, Ctrl+m opens the model picker, Ctrl+r opens the session picker, and Ctrl+t cycles through tool output.

When Charm Ruby gems are unavailable, Kreator falls back to line mode with the same slash commands.

## Command Reference

```text
Usage: kreator [options] "prompt"
        --provider PROVIDER
        --model MODEL
        --no-tools
        --tools LIST
        --timeout SECONDS
        --allow-path PATH
        --deny-bash PATTERN
        --approval-policy POLICY
        --plugin-tool-policy POLICY
        --ask-permission
        --name NAME
        --no-session
        --session PATH_OR_ID
        --continue
        --session-dir PATH
        --list-sessions
        --search-sessions QUERY
        --label-session LABEL
        --export-session FORMAT
        --cleanup-empty-sessions
        --resource-home PATH
        --no-plugins
        --plugin NAME
        --prompt-template NAME
        --compact-threshold CHARS
        --json
        --rpc
    -h, --help
```

Plugin management is exposed as a subcommand:

```text
kreator plugin available
kreator plugin list
kreator plugin validate PATH_OR_NAME
kreator plugin install PATH_OR_NAME [--name NAME]
kreator plugin update NAME PATH_OR_NAME
kreator plugin remove NAME
```

## Providers

Kreator includes provider adapters for:

- `openai`: OpenAI-compatible chat completions with streaming, tool calls, usage metadata, and non-streaming fallback.
- `anthropic`: Anthropic Messages API with streaming, tool calls, usage metadata, and non-streaming fallback.
- `openrouter`: OpenRouter's OpenAI-compatible chat completions endpoint with streaming, tool calls, usage metadata, and non-streaming fallback.

Provider responses are normalized into Kreator messages, tool calls, usage objects, and runtime events.

## Built-In Tools

Tools are enabled by default. Use `--no-tools` to disable them or `--tools` to select a subset.

| Tool | What it does |
| --- | --- |
| `read` | Reads a UTF-8 text file with optional line and byte truncation. |
| `grep` | Searches UTF-8 text files with a Ruby regular expression, optional glob filtering, and truncation. |
| `find` | Finds files and directories by name and type under an allowed path. |
| `ls` | Lists directory entries with type and size metadata. |
| `edit` | Applies an exact text replacement and returns a unified diff. |
| `write` | Writes complete UTF-8 text contents to a file and creates parent directories. |
| `bash` | Runs a shell command in the current workspace with timeout and output truncation. |
| `agent` | Starts, inspects, waits for, stops, or lists headless Kreator child agents in detached `tmux` sessions. |

The `agent` tool lets the model orchestrate multiple independent Kreator runs. Child agents run headlessly with `--json` inside detached `tmux` sessions, while logs and status records are stored under `KREATOR_HOME/agents` or `~/.kreator/agents`.

Useful safety options:

```sh
kreator --ask-permission "Update the README"
kreator --approval-policy prompt "Run the test suite"
kreator --approval-policy deny "Inspect files without making changes"
kreator --allow-path . --allow-path ../shared "Read files across both workspaces"
kreator --deny-bash "rm|git reset" "Work on this repo"
kreator --timeout 10 "Run a quick health check"
```

By default, file tools are restricted to the current working directory. `--allow-path` can be repeated to permit additional directories.

## Sessions

Kreator stores conversations as append-only JSONL sessions under:

```text
~/.kreator/sessions/--encoded-cwd--/<timestamp>_<uuid>.jsonl
```

Sessions preserve messages, model changes, labels, usage metadata, and compaction entries.

Common session commands:

```sh
kreator --continue "Keep working from the latest session"
kreator --session SESSION_ID "Resume this specific session"
kreator --list-sessions
kreator --search-sessions "release notes"
kreator --session SESSION_ID --label-session docs
kreator --session SESSION_ID --export-session markdown
kreator --cleanup-empty-sessions
```

Use `--no-session` for one-off runs that should not be persisted. Use `--session-dir PATH` to store sessions somewhere other than `~/.kreator/sessions`.

## Project Resources

Kreator automatically discovers resource files from the current directory and its ancestors:

- `AGENTS.md`
- `.kreator/instructions.md`
- `.kreator/prompts/*.md`
- `.kreator/skills/*/SKILL.md`
- `.kreator/plugins/*/plugin.json`

It also loads global resources from `~/.kreator` or the directory configured with `--resource-home`:

- `~/.kreator/prompts/*.md`
- `~/.kreator/skills/*/SKILL.md`
- `~/.kreator/plugins/*/plugin.json`

Project and plugin instructions are added to the system prompt. Prompt templates and available skills are listed for the model. A skill's full `SKILL.md` content is loaded when a prompt invokes it with forms such as `$rails`, `@rails`, `skill:rails`, or `use rails skill`. Plugins can also declare `autoload_skills` to load selected skill files whenever the plugin is enabled.

Apply a prompt template:

```sh
kreator --prompt-template review "Check this implementation"
```

If a template contains `{{prompt}}`, Kreator replaces that token with the user prompt. Otherwise, it appends the prompt after the template content.

## Plugins

Plugins are local resource bundles. A plugin can provide instructions, prompt templates, skills, and Ruby-native tools.

Plugin layout:

```text
my-plugin/
  plugin.json
  instructions.md
  prompts/
    review.md
  skills/
    rails/
      SKILL.md
  tools/
    echo.rb
```

Example `plugin.json`:

```json
{
  "name": "my-plugin",
  "version": "0.1.0",
  "description": "Example local plugin",
  "autoload_skills": ["rails"],
  "tools": [
    {
      "path": "tools/echo.rb",
      "class": "MyPlugin::Echo"
    }
  ]
}
```

Example plugin tool:

```ruby
module MyPlugin
  class Echo < Kreator::PluginTool
    tool_name "echo"
    description "Echo input"
    schema(
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["text"],
      "properties" => {
        "text" => { "type" => "string" }
      }
    )

    def call(args:, context:, signal:)
      Kreator::ToolResult.new(content: "echo: #{args.fetch('text')}")
    end
  end
end
```

Plugin tool names are exposed as `plugin_name.tool_name`, for example `my-plugin.echo`.

Plugin lifecycle commands:

```sh
kreator plugin available
kreator plugin list
kreator plugin validate PATH_OR_NAME
kreator plugin install PATH_OR_NAME [--name NAME]
kreator plugin update NAME PATH_OR_NAME
kreator plugin remove NAME
```

Kreator also ships with curated bundled plugins. Install one by name:

```sh
kreator plugin available
kreator plugin install rails
kreator --plugin rails "Add a posts controller with tests"
```

The bundled `rails` plugin adds Rails conventions to the system prompt, exposes a Rails review prompt template, and autoloads its Rails skill context whenever the plugin is enabled.

Plugin controls:

```sh
kreator --no-plugins "Ignore local plugins"
kreator --plugin reviewer --plugin rails "Only enable selected plugins"
kreator --plugin-tool-policy prompt "Ask before plugin tool calls"
```

Plugin Ruby code is loaded locally, so install plugins only from sources you trust. Plugin tool calls require approval by default.

## JSON Output

`--json` emits one final JSON object and suppresses streaming text. Successful runs include:

- `ok`
- `message`
- `messages`
- `tool_calls`
- `usage`
- `session`

Errors are emitted as:

```json
{
  "ok": false,
  "error": {
    "class": "ArgumentError",
    "message": "session not found: missing",
    "code": "runtime_error"
  }
}
```

## JSONL RPC Mode

Use `--rpc` to run Kreator as a line-oriented JSON RPC process. Each input line is a JSON command. Each output line is a JSON response or event.

```sh
kreator --rpc
```

Example input:

```jsonl
{"id":"1","command":"get_state"}
{"id":"2","command":"prompt","prompt":"Summarize this project"}
{"id":"3","command":"get_messages"}
```

Responses use this shape:

```json
{"type":"response","id":"1","ok":true,"state":{}}
```

Prompt execution also emits event lines:

```json
{"type":"event","id":"2","event":{"type":"message_delta","delta":"..."}}
```

Supported RPC commands:

- `prompt`
- `abort`
- `get_state`
- `get_messages`
- `search_sessions`
- `label_session`
- `export_session`
- `cleanup_sessions`
- `get_resources`
- `plugin_list`
- `plugin_validate`
- `plugin_install`
- `plugin_update`
- `plugin_remove`
- `list_branches`
- `fork_session`
- `new_session`
- `set_model`

## Development

Run the test suite:

```sh
bundle exec rake test
```

Run RuboCop:

```sh
bundle exec rubocop
```

The gem entry point is `exe/kreator`, and the main implementation lives under `lib/kreator`.

## Contributors

- [Mario Alvarez](https://github.com/marioalna)
- [Jorge Alvarez](https://github.com/jorgegorka)

## License

Kreator is available under the [MIT License](https://opensource.org/licenses/MIT).
