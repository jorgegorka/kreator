# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Added

- Added OpenAI Codex/PI OAuth credential support so ChatGPT subscription-backed OpenAI access can be used without an API key.
- Added interactive `/login` and `/logout` commands for managing Kreator's OpenAI OAuth credentials.

## [0.2.0] - 2026-05-05

### Added

- Added OpenRouter provider support, including `OPENROUTER_API_KEY`, `OPENROUTER_BASE_URL`, `OPENROUTER_SITE_URL`, and `OPENROUTER_APP_NAME` configuration.
- Added a bundled `rails` plugin with Rails instructions, a review prompt template, and autoloaded Rails skill context.
- Added bundled plugin discovery and install support via `kreator plugin available` and `kreator plugin install rails`.
- Added `autoload_skills` plugin manifest support so selected plugin skills can be loaded automatically when a plugin is enabled.
- Added built-in `grep`, `find`, and `ls` tools for safer repository discovery without shell commands.
- Added the built-in `agent` tool for starting, inspecting, waiting on, stopping, and listing headless Kreator child agents in detached `tmux` sessions.
- Added `:q` as an interactive CLI quit shortcut.

### Changed

- Updated interactive model suggestions and context-window estimates for newer OpenAI, Anthropic, and OpenRouter models.
- Improved interactive mode with a welcome panel, command and skill autocomplete, a context meter, draft saving, and Enter-to-send with Alt+Enter for newlines.
- Updated CLI help, README docs, and tests for the expanded default tool set.

### Fixed

- Isolated plugin tool loading in an anonymous namespace to avoid Ruby constant and method redefinition warnings when loading plugins repeatedly.

## [0.1.0] - 2026-05-05

### Added

- Initial published version of Kreator.
- Added the `kreator` CLI for running coding-agent workflows from a terminal, script, or JSONL RPC client.
- Added OpenAI and Anthropic provider adapters with streaming responses, tool calls, usage metadata, and non-streaming fallbacks.
- Added built-in `read`, `write`, `edit`, and `bash` tools.
- Added persistent JSONL sessions with resume, search, labeling, export, and cleanup commands.
- Added project and global resources for instructions, prompt templates, skills, and local Ruby plugins.
- Added interactive mode with slash commands for sessions, models, prompts, plugins, compaction, and exits.
