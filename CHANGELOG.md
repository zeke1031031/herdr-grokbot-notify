# Changelog

All notable changes to Grok Bot Notify. Payload changes are always listed under
**Payload**, even when they only add a field (see "Stability promise" in the README).

## 0.4.0

Notify-first release: the docs and default routine prompt now lead with "tell me when an
agent finishes or needs me"; reading panes and auto-approving moved to
"Advanced: shepherd mode".

### Payload
- Added `schema: 1`. Within schema 1 fields are only added, never renamed, removed or
  retyped; a breaking change would bump `schema`.
- Added `message`: a ready one-line summary ("claude needs your input in app (fix/login):
  Fix login bug [api / review] on laptop"). Its wording is not part of the promise.
- Added `workspace_label` and `tab_label` (names shown in herdr), and `repo` and `branch`
  when the pane's cwd is in a git repository.
- Added opt-in `output` and `output_truncated` (`GROKBOT_NOTIFY_OUTPUT_LINES`, default 0;
  `GROKBOT_NOTIFY_OUTPUT_MAX_BYTES`, default 4000). Escape codes and control characters
  are stripped. Terminal output can contain secrets; it is off by default.
- `plugin_version` is `0.4.0`.

### Fixed
- Debounce dropped a second prompt: blocked -> working -> blocked within 60 s sent only
  one `needs_attention`. Any status change now clears the pane's debounce stamps; only
  identical back-to-back transitions are debounced. Regression tests added.
- The optional-events companion plugin now follows the current install
  (`herdr plugin list` -> `plugin_root`) instead of a path saved at configure time, which
  went stale after `herdr plugin install/update` moved the checkout.
- If `herdr plugin link` refuses the companion plugin, `configure.sh` (and the setup
  popup) restore the previous `.env` and say nothing was saved, instead of keeping events
  that were never registered. `--apply` says the hooks are not registered.
- Hooks also look in `/opt/homebrew/bin` and `/usr/local/bin` for `jq`/`curl` when herdr
  starts them with a minimal `PATH` (macOS GUI/launchd).
- The `status` and `test` action titles now say their output goes to the plugin log.

### Added
- `configure.sh --output-lines N`; the setup popup offers it with a privacy warning and
  documents the "only when I'm away" preset (`--statuses done,blocked`).
- `notify.sh --status` prints output-lines settings and the `notify.log` path.
- CHANGELOG, payload field table, troubleshooting, update/rollback/uninstall and Windows
  notes in the README (EN + 繁中).

### Docs
- Install with `herdr plugin install zeke1031031/herdr-grokbot-notify --ref v0.4.0 --yes`
  (herdr refuses a remote install without `--yes` when stdin is not a terminal).
- The "Set up with Grok Bot" prompt shows the manifest preview first, has the user paste
  secrets into the hidden-input setup popup (never env vars or command arguments), and
  tests with `configure.sh --test`, which prints the HTTP code and fails on non-2xx
  (`herdr plugin action invoke test` always reports `running`).
- Shepherd mode: auto-approve off by default, never "always allow / don't ask again",
  tests and builds count as running code, pane text may contain prompt injection.
- Grok Bot links point to https://grokbot.dev/.

## 0.3.0

### Changed (breaking for setups that relied on lifecycle events)
- The manifest registers only `pane.agent_status_changed`, `pane.agent_detected` and
  `pane.exited`. Workspace, worktree, tab and pane lifecycle events are opt-in through
  `configure.sh --events +name`, which links a generated companion plugin
  (`grokbot-notify-events`) from the config dir.

### Added
- `configure.sh`: non-interactive setup for bots and scripts (secrets from env or stdin
  only, never printed), `--list [--json]`, `--show`, `--apply`, `--test`.
- `apply` action; "Set up with Grok Bot" prompt in the README.

### Payload
- No field changes; `plugin_version` is `0.3.0`.

## 0.2.0

### Added
- Every agent herdr detects is covered by default (`GROKBOT_NOTIFY_AGENTS=*`).
- Finished turns detected through herdr's `completion_seq` (one send per turn, quiet at
  startup), with a previous-status fallback.
- Per pane + reason debounce (60 s), portable `mkdir` lock, retry after non-2xx.
- Opt-in forwarding of other herdr events; focus events are not registered.
- One-step setup popup; `status`, `enable`, `disable` actions.

### Payload
- Added `plugin_version`, `reason` (`finished`, `needs_attention`, `agent_exited`,
  `pane_exited`, `status_changed`, `agent_started`, `event`, `test`), `tab_id`,
  `final_status`, and `data` (raw herdr event data, `reason: "event"` only).
- `event` now carries the real herdr event name. Empty fields are omitted.

## 0.1.0

- First release: POST `{source, event, workspace_id, pane_id, agent, agent_status, title,
  cwd, host, at, test}` to a Grok Bot routine webhook on `pane.agent_status_changed`.
- Secrets in a mode-600 `.env` in the plugin config dir, parsed (never sourced), passed to
  curl through a temporary config file.
