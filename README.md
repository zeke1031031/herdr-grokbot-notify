# Grok Bot Notify (herdr plugin)

Wake your [Grok Bot](https://grokbot.dev/) routine by webhook when any coding agent in
[herdr](https://herdr.dev) finishes or needs you. Claude Code, Codex, Cursor, Copilot,
Gemini, OpenCode, Grok, Amp, Kimi, Qwen and every other agent herdr detects.

[繁體中文說明](#繁體中文說明)

What you get, for example on your phone:

> **Needs you:** claude needs your input in app (fix/login): Fix login bug [api / review] on laptop

## Quickstart

1. **Create a webhook routine.** In Grok Bot, create a routine with a **Webhook** trigger
   and give it the notify-only prompt from
   [`examples/routine-prompt.md`](examples/routine-prompt.md). Copy the routine's
   **webhook URL** and **Authorization header**. Treat both as secrets.
2. **Install** (herdr 0.9.5+, Linux or macOS, with `bash`, `jq`, `curl`):

   ```sh
   herdr plugin install zeke1031031/herdr-grokbot-notify --ref v0.4.0 --yes
   ```

   It prints a manifest preview (the hook events and the commands they run). Leave out
   `--yes` in a terminal to confirm it by hand first.
3. **Paste the URL and Authorization header** into the setup popup (input is hidden),
   then let it send a test:

   ```sh
   herdr plugin pane open --plugin grokbot-notify --entrypoint setup
   ```

Done. You are told when any agent finishes a turn, is blocked on a question or
approval, or exits. Nothing else is hooked and no terminal output is sent.

Prefer to let your bot do it? See [Set up with Grok Bot](#set-up-with-grok-bot).

## Sample notification

The routine receives one small JSON body per notification:

```json
{"source":"herdr","schema":1,"plugin_version":"0.4.0","event":"pane.agent_status_changed",
 "reason":"needs_attention",
 "message":"claude needs your input in app (fix/login): Fix login bug [api / review] on laptop",
 "workspace_id":"w1","workspace_label":"api","tab_id":"w1:t1","tab_label":"review",
 "pane_id":"w1:p2","agent":"claude","agent_status":"blocked","title":"Fix login bug",
 "cwd":"/Users/me/app","repo":"app","branch":"fix/login","host":"laptop",
 "at":"2026-01-01T12:00:00Z","test":false}
```

`message` is ready to forward as is. Every field is described in [Payload](#payload).

## Set up with Grok Bot

Paste this into a chat with your Grok Bot. Your secrets never go through the chat, a
command line or an environment variable: you paste them into the hidden-input popup.

```text
Set up herdr -> Grok Bot notifications for me with the herdr-grokbot-notify plugin
(https://github.com/zeke1031031/herdr-grokbot-notify, version v0.4.0).
Work on the computer where herdr runs. Never print, log or echo the webhook URL or the
Authorization value, never put them in a command line or an environment variable, and
never ask me to paste them in chat.

1. Create a routine with a Webhook trigger called "herdr agents". Use the "Notify-only"
   prompt from examples/routine-prompt.md in the repo.
2. Check herdr >= 0.9.5 (`herdr --version`) and that bash, jq and curl are installed.
3. Before installing, show me what will be installed: summarise
   https://raw.githubusercontent.com/zeke1031031/herdr-grokbot-notify/v0.4.0/herdr-plugin.toml
   (the hook events, actions and the commands they run) and wait for my OK. Then run
   `herdr plugin install zeke1031031/herdr-grokbot-notify --ref v0.4.0 --yes`
   (this also upgrades an existing install) and show me the "Plugin install preview" it prints.
   Then: ROOT="$(herdr plugin list --plugin grokbot-notify --json | jq -r '.result.plugins[0].plugin_root')"
4. Ask me to open the setup popup myself and paste the routine's webhook URL and
   Authorization header there:
   `herdr plugin pane open --plugin grokbot-notify --entrypoint setup`
   Wait until I say it is done. (Only if I can't do that, and you hold the values in a
   secret store: write them to the stdin of `bash "$ROOT/configure.sh" --secrets-from-stdin`,
   URL on line 1 and Authorization on line 2, never as arguments or variables.)
5. Run `bash "$ROOT/configure.sh" --test`. It must print "HTTP 2xx" and exit 0, and the
   routine must receive a payload with "test": true. If not, follow the README's
   Troubleshooting section.
6. Show me `bash "$ROOT/configure.sh" --show` and tell me: by default I hear about finished,
   needs input, agent exited and pane exited for every agent; `--statuses done,blocked`
   means "only while I'm not looking at that pane"; `bash "$ROOT/configure.sh" --list`
   shows optional events (all off); pause with
   `herdr plugin action invoke disable --plugin grokbot-notify`.
```

## What fires the webhook

`reason` tells the routine why it was woken:

| `reason` | When | Default |
| --- | --- | --- |
| `finished` | The agent completed a turn. herdr reports `done` (you weren't looking at the pane) or `idle` (you were). herdr's `completion_seq` makes each turn send once; agents idle at startup stay quiet. | on |
| `needs_attention` | `blocked`: herdr recognised an approval, question or permission prompt. | on |
| `agent_exited` | The agent process left the pane (quit, crash, `Ctrl-C`). `final_status` is its last state. | on |
| `pane_exited` | A pane that was running a detected agent exited. Plain shells stay quiet. | on |
| `status_changed` | Any other status you add to the statuses (`working`, `unknown`). | off |
| `agent_started` | herdr detected an agent starting in a pane. | off |
| `event` | Another herdr event you opted into (see [Optional herdr events](#optional-herdr-events)). | off |
| `test` | `configure.sh --test`, the setup popup's test, or the `test` action. | - |

Repeats are debounced per pane and reason (60 s): only identical back-to-back
transitions are dropped. If the agent changes state in between (blocked, working,
blocked again) you get both prompts.

### Less noise: "only when I'm away"

```sh
bash "$ROOT/configure.sh" --statuses done,blocked
```

herdr marks a finished turn `done` while you are not looking at that pane and `idle` once
you have seen it, so this sends finished turns only when you weren't watching (plus every
blocked prompt). Other filters: `--agents claude,codex` and `--debounce N`.

## Payload

`Content-Type: application/json`, sent as an HTTP `POST` with your Authorization header.

| Field | Type | Present | Meaning |
| --- | --- | --- | --- |
| `source` | string | always | `"herdr"` |
| `schema` | number | always | Payload schema version, currently `1` (see stability below) |
| `plugin_version` | string | always | Plugin version that sent it, e.g. `"0.4.0"` |
| `event` | string | always | herdr event name (`pane.agent_status_changed`, `pane.agent_detected`, `pane.exited`, `tab.created`, ...) or `"test"` |
| `reason` | string | always | One of the reasons in the table above |
| `message` | string | always | Ready one-line summary for humans. Wording may change; don't parse it |
| `test` | boolean | always | `true` only for test webhooks |
| `at` | string | always | Send time, ISO 8601 UTC |
| `workspace_id` | string | when known | herdr workspace id, e.g. `w1` |
| `workspace_label` | string | when known | Workspace name shown in herdr's sidebar |
| `tab_id` | string | when known | herdr tab id, e.g. `w1:t1` |
| `tab_label` | string | when known | Tab name shown in herdr |
| `pane_id` | string | agent events | herdr pane id, e.g. `w1:p2` (use with `herdr pane read`) |
| `agent` | string | agent events | herdr agent id: `claude`, `codex`, `cursor`, `gemini`, ... |
| `agent_status` | string | agent status events | `done`, `idle`, `blocked`, `working` or `unknown`; for `agent_exited` the same as `final_status` |
| `final_status` | string | `agent_exited`, `pane_exited` | Last status before the agent or pane went away; may be absent |
| `title` | string | when known | Terminal title of the pane (often the agent's task name) |
| `cwd` | string | when known | Working directory of the pane |
| `repo` | string | inside a git repo | Folder name of the repository (the main checkout's name for linked worktrees) |
| `branch` | string | inside a git repo | Current branch, or a short commit hash when detached |
| `host` | string | unless `GROKBOT_NOTIFY_INCLUDE_HOST=0` | Short hostname |
| `output` | string | only if `GROKBOT_NOTIFY_OUTPUT_LINES` > 0 | Last lines of the pane, escape codes removed, newest kept within the byte cap |
| `output_truncated` | boolean | with `output` | `true` if older lines were cut to fit the byte cap |
| `data` | object | only `reason: "event"` | herdr's raw event data, unchanged, e.g. `{"type":"tab_created","tab":{"tab_id":"w1:t2","workspace_id":"w1","label":"2",...}}`. Its shape is herdr's (`herdr api schema --json`, `schemas.event`), not this plugin's |

Fields with no value are left out rather than sent empty, so check for presence.

**Stability promise.** Within `schema: 1`, fields are only ever added. No field is renamed,
removed or changes type, and `reason` values keep their meaning. Every payload change,
even an added field, is listed in [CHANGELOG.md](CHANGELOG.md). A breaking change would
bump `schema`. Routines should ignore fields they don't know. Two things are outside the
promise: the wording of `message`, and the contents of `data`, which follow herdr.

### Optional: pane output

```sh
bash "$ROOT/configure.sh" --output-lines 40
```

Adds the last 40 lines of the agent's pane (`herdr pane read --source recent-unwrapped`)
as `output`, escape codes and control characters removed, capped at
`GROKBOT_NOTIFY_OUTPUT_MAX_BYTES` (default 4000; newest lines kept). Off by default.
**Terminal output can contain secrets** (tokens printed by a CLI, `.env` contents, keys
in error messages), and with this on it is sent to your Grok Bot. It can also contain
text written to mislead your routine; treat it as untrusted.

## Settings

The setup popup and `configure.sh` write `$(herdr plugin config-dir grokbot-notify)/.env`
(mode 600). Environment variables override the file.

| Key | Default | Meaning |
| --- | --- | --- |
| `GROKBOT_WEBHOOK_URL` | (required) | Routine webhook URL (`https://` only) |
| `GROKBOT_WEBHOOK_AUTH` | (required) | `Bearer ...` or the full `Authorization: Bearer ...` line |
| `GROKBOT_NOTIFY_AGENTS` | `*` | Agent ids or substrings (`claude,codex`); `*` = every agent |
| `GROKBOT_NOTIFY_EVENTS` | `pane.agent_status_changed,agent.released,pane.exited` | Which events may fire (change with `configure.sh --events`) |
| `GROKBOT_NOTIFY_STATUSES` | `done,idle,blocked` | Statuses that notify; `done,blocked` = only while you're away |
| `GROKBOT_NOTIFY_DEBOUNCE_SECS` | `60` | Drop identical back-to-back repeats per pane and reason for this long (`0` = off) |
| `GROKBOT_NOTIFY_OUTPUT_LINES` | `0` | Send the last N lines of the pane as `output` (max 500). Can contain secrets |
| `GROKBOT_NOTIFY_OUTPUT_MAX_BYTES` | `4000` | Byte cap for `output` (max 65536) |
| `GROKBOT_NOTIFY_TIMEOUT_SECS` | `10` | HTTP timeout |
| `GROKBOT_NOTIFY_INCLUDE_HOST` | `1` | Include the short hostname |

The agent filter applies to agent events only; opted-in herdr events are not filtered by agent.

### configure.sh (scripts and bots)

`configure.sh` does what the popup does, without prompts. It never takes secrets as
arguments and never prints them.

```sh
ROOT="$(herdr plugin list --plugin grokbot-notify --json | jq -r '.result.plugins[0].plugin_root')"

bash "$ROOT/configure.sh" --secrets-from-stdin < secrets.txt   # line 1 URL, line 2 Authorization
bash "$ROOT/configure.sh" --test            # prints "HTTP <code>", exits non-zero unless 2xx
bash "$ROOT/configure.sh" --show            # summary; secrets shown as set / MISSING
bash "$ROOT/configure.sh" --statuses done,blocked --agents claude,codex --debounce 60
bash "$ROOT/configure.sh" --output-lines 40 # 0 = off
bash "$ROOT/configure.sh" --list            # every event, on/off, one-line description (--json too)
bash "$ROOT/configure.sh" --events +tab.created,-pane.exited
bash "$ROOT/configure.sh" --events default  # core events only, removes the companion plugin
```

`--url-from-env` / `--auth-from-env` read `GROKBOT_WEBHOOK_URL` / `GROKBOT_WEBHOOK_AUTH`
for CI-style setups where the environment is already private. On someone's own computer,
prefer the popup.

## Optional herdr events

By default only the agent signals are registered with herdr (`pane.agent_status_changed`,
`pane.agent_detected`, `pane.exited`), so herdr starts no hook process for anything else.
These are off until you turn them on with `configure.sh --events +name` (`reason: "event"`,
raw herdr data in `data`):

| Event | Fires when |
| --- | --- |
| `pane.agent_detected` | an agent started in a pane (`reason: "agent_started"`) |
| `workspace.created` / `closed` | a workspace was created / closed |
| `workspace.updated` | a workspace changed (e.g. its cwd or settings) |
| `workspace.renamed` / `moved` / `reordered` | a workspace was renamed / moved / the list reordered |
| `worktree.created` / `opened` / `removed` | a git worktree was created / opened as a workspace / removed |
| `tab.created` / `closed` / `renamed` / `moved` | a tab was created / closed / renamed / moved |
| `pane.created` / `closed` / `moved` | a pane was created / closed / moved |

The default events can be switched off the same way (`-pane.exited`, `-agent.released`,
`-pane.agent_status_changed`). `agent.released` is this plugin's name for
`pane.agent_detected` with `released: true`. Focus events (`*.focused`) are not offered:
they fire on every click.

How they are registered: herdr only runs hooks listed in a plugin manifest, but re-reads
manifests before every event. `configure.sh` writes a tiny companion plugin,
`grokbot-notify-events`, into the config dir, lists only your chosen events in it and
runs `herdr plugin link` on it. Its hook finds the current install through
`herdr plugin list` and hands the event to this plugin's `notify.sh`, so it keeps working
after an update. This plugin's own files are never modified. If herdr refuses the link,
`configure.sh` restores your previous `.env` and says nothing was saved. If you edit
`GROKBOT_NOTIFY_EVENTS` by hand, run `configure.sh --apply`.

herdr does not let plugins hook terminal output (`pane.output_matched`), `pane.updated`,
`layout.updated` or `workspace.metadata_updated`, and has no separate "error" status: a
crashed agent shows up as `agent_exited` or `pane_exited`.

## Troubleshooting

**1. Send a test.** `bash "$ROOT/configure.sh" --test` prints the HTTP code and exits
non-zero unless it is 2xx:

| Result | Meaning |
| --- | --- |
| `HTTP 2xx` | Delivered. If the routine didn't run, check the routine in Grok Bot. |
| `HTTP 401` / `403` | Wrong Authorization value. Paste it again in the setup popup. |
| `HTTP 404` | Wrong URL, or the routine/webhook was deleted or rotated. |
| `HTTP 000` | No connection: typo in the URL, no network, proxy, or timeout. |
| `webhook URL/Authorization not configured` | Run the setup popup. |

The `test` action (`herdr plugin action invoke test --plugin grokbot-notify`) only starts
the hook and always reports `running`; its result is in the plugin log (below).

**2. Read the logs.**

- `herdr plugin log list --plugin grokbot-notify` lists every hook run with its exit
  code and output. The `status` action
  (`herdr plugin action invoke status --plugin grokbot-notify`) writes version, paths and
  settings there (never secret values).
- The plugin's own `notify.log` records every `sent` / `debounced` / `skip` decision with
  the HTTP code, never the URL or token. It lives in herdr's plugin state dir, on Linux
  `~/.local/state/herdr/plugins/grokbot-notify/notify.log`; the `status` output above
  prints the exact path.

**3. Common causes.**

- **`server_not_running` from `herdr plugin action invoke ...` or `herdr pane ...`**:
  actions, pane commands and the hooks themselves need the running herdr server. Start
  herdr (`herdr`) and retry. `configure.sh --test`, `herdr plugin list` and
  `herdr plugin config-dir` work without it, so use those to check your settings.
- **`error: jq and curl are required` in notify.log on macOS**: herdr started from a GUI or
  launchd may not have Homebrew in `PATH`. Since 0.4.0 the hooks also look in
  `/opt/homebrew/bin` and `/usr/local/bin`. Install jq with `brew install jq` (macOS 15+
  already ships `/usr/bin/jq`).
- **Nothing for one agent**: herdr detects most agents from the screen; a brand-new prompt
  style can show as `idle` instead of `blocked` until herdr learns it. Check
  `--agents` and `--statuses` in `configure.sh --show`.
- **Paused?** `configure.sh --show` / the `status` action print `enabled: no` after the
  `disable` action. Resume with `herdr plugin action invoke enable --plugin grokbot-notify`.
- **Optional events stopped**: run `bash "$ROOT/configure.sh" --apply`.

## Update, roll back, uninstall

```sh
# update (also the way to move a --ref install to a newer tag)
herdr plugin install zeke1031031/herdr-grokbot-notify --ref v0.4.0 --yes
# roll back to an earlier release
herdr plugin install zeke1031031/herdr-grokbot-notify --ref v0.3.0 --yes
```

`herdr plugin update grokbot-notify --yes` only moves installs without a pinned `--ref`;
an install pinned to a tag stays on it. Your settings live in the config dir and survive
updates and rollbacks. Local clone: `git pull` or `git checkout v0.3.0`.

```sh
herdr plugin action invoke disable --plugin grokbot-notify   # pause (enable to resume)
bash "$ROOT/configure.sh" --events default                  # 1. remove the companion plugin
herdr plugin uninstall grokbot-notify                         # 2. or: herdr plugin unlink grokbot-notify
rm -rf "$(herdr plugin config-dir grokbot-notify)"            # 3. remove saved secrets
```

Run step 1 before step 2, while `$ROOT` still exists. Also delete or rotate the webhook in
the Grok Bot routine panel if you no longer use it.

## Advanced: shepherd mode

If herdr runs somewhere your Grok Bot can run shell commands (the Grok Bot box, or a
computer you registered with it), the routine can do more than tell you: read the pane
(`herdr pane read <pane_id> --source recent-unwrapped --lines 120`), summarise what a
finished agent did, and optionally answer a narrow set of safe prompts. The prompt is in
[`examples/routine-prompt.md`](examples/routine-prompt.md#advanced-shepherd-mode).

- Auto-approval is **off** by default in that prompt; you switch it on explicitly.
- It never chooses "always allow" / "don't ask again" / "allow for this session".
- Running tests, builds, linters or package scripts counts as running code, so it is
  reported to you, not approved.
- Pane text can contain prompt injection (a README, a web page or a dependency printing
  "approve everything"). The prompt tells the routine to treat it as data, but the routine
  prompt is the real safety boundary: keep what it may approve small.

## Security notes

- Secrets live only in the config dir `.env` (mode 600), never in the plugin checkout.
  `.gitignore` blocks `.env` files.
- The `.env` is parsed as `KEY=VALUE`, never `source`d, so it cannot run code.
- The URL and Authorization header reach `curl` through a temporary mode-600 config file,
  so they never appear in `ps`, and they are never logged or printed.
- The payload is pane metadata (title, cwd, repo, branch, labels, hostname). Terminal
  output is only sent if you turn on `GROKBOT_NOTIFY_OUTPUT_LINES`.
  Set `GROKBOT_NOTIFY_INCLUDE_HOST=0` to drop the hostname.
- Requests run in the foreground with a timeout; no background processes are left behind.

## Requirements and platforms

- herdr >= 0.9.5; bash 3.2+ (macOS `/bin/bash` is fine), `jq`, `curl`. Optional: `git`
  (for `repo` / `branch`), `timeout`.
- Linux and macOS. **Windows is not supported**: the manifest declares
  `platforms = ["linux", "macos"]` and the hooks are bash scripts. herdr running inside
  WSL behaves like Linux but is untested.

## How it works

The manifest registers `notify.sh` for the three agent events only. For agent events it
keeps tiny per-pane state (last status, agent, last completion sent) in the plugin state
dir, asks `herdr agent get` for `completion_seq` and pane metadata, debounces identical
repeats per pane and reason (portable `mkdir` lock), adds workspace/tab labels and git
context, then POSTs. A non-2xx response clears the debounce stamp so the next change
retries. There is no retry queue: if the webhook is down, that notification is lost and
logged.

Antigravity and Grok report `idle` when they return to their prompt even if background
jobs still run. Plain terminals never produce agent events.

Developers: `bash test/run-tests.sh` runs offline tests against a local dummy listener
with fake credentials and a stub `herdr` (needs python3). See [CHANGELOG.md](CHANGELOG.md).

---

## 繁體中文說明

當 [herdr](https://herdr.dev) 裡任何 coding agent（Claude Code、Codex、Cursor、Copilot、Gemini、
OpenCode、Grok、Amp、Kimi、Qwen… 所有 herdr 偵測得到的 agent）**完成工作或需要你**時，
用 webhook 叫醒你的 [Grok Bot](https://grokbot.dev/) routine。

你會收到像這樣的通知：

> **Needs you:** claude needs your input in app (fix/login): Fix login bug [api / review] on laptop

### 三步驟快速開始

1. **建立 webhook routine**：在 Grok Bot 建立一個 **Webhook 觸發**的 routine，提示詞用
   [`examples/routine-prompt.md`](examples/routine-prompt.md) 裡的「Notify-only」版本。
   複製 routine 的 **Webhook URL** 與 **Authorization 標頭**（兩者都是秘密）。
2. **安裝**（herdr 0.9.5 以上、Linux / macOS、需要 `bash`、`jq`、`curl`）：

   ```sh
   herdr plugin install zeke1031031/herdr-grokbot-notify --ref v0.4.0 --yes
   ```

   會先印出 manifest 預覽（掛勾的事件與執行的指令）。在終端機裡拿掉 `--yes` 可以先手動確認。
3. **貼上 URL 與 Authorization 標頭**（輸入不會顯示），並送出測試：

   ```sh
   herdr plugin pane open --plugin grokbot-notify --entrypoint setup
   ```

完成。任何 agent 完成一輪工作、卡在提問或核准、或結束時都會通知你。不會掛勾其他事件，也不會傳送終端機輸出。

### 用 Grok Bot 設定

把下面這段貼給你的 Grok Bot。秘密不會經過聊天、指令列或環境變數，而是由你自己貼進隱藏輸入的設定視窗。

```text
請用 herdr-grokbot-notify plugin（https://github.com/zeke1031031/herdr-grokbot-notify，版本 v0.4.0）
幫我設定 herdr -> Grok Bot 通知，在跑 herdr 的那台電腦上操作。絕對不要印出、記錄或回顯 webhook URL
與 Authorization，不要把它們放進指令列或環境變數，也不要叫我貼在聊天裡。

1. 建立一個 Webhook 觸發的 routine，名稱 "herdr agents"，提示詞用 repo 裡 examples/routine-prompt.md
   的「Notify-only」版本。
2. 確認 herdr >= 0.9.5（`herdr --version`），以及 bash、jq、curl 都已安裝。
3. 安裝前先讓我看要裝什麼：摘要
   https://raw.githubusercontent.com/zeke1031031/herdr-grokbot-notify/v0.4.0/herdr-plugin.toml
   （掛勾的事件、action 與執行的指令），等我同意。然後執行
   `herdr plugin install zeke1031031/herdr-grokbot-notify --ref v0.4.0 --yes`
   （已安裝也用這個升級），並把它印出的「Plugin install preview」給我看。
   接著：ROOT="$(herdr plugin list --plugin grokbot-notify --json | jq -r '.result.plugins[0].plugin_root')"
4. 請我自己打開設定視窗，貼上 routine 的 webhook URL 和 Authorization 標頭：
   `herdr plugin pane open --plugin grokbot-notify --entrypoint setup`
   等我說完成。（只有在我做不到、而你把值存在秘密儲存區時：把它們寫進
   `bash "$ROOT/configure.sh" --secrets-from-stdin` 的 stdin，第 1 行 URL、第 2 行 Authorization，
   絕不放在參數或變數裡。）
5. 執行 `bash "$ROOT/configure.sh" --test`，必須印出 "HTTP 2xx" 並以 0 結束，routine 也要收到
   "test": true 的 payload。失敗就照 README 的 Troubleshooting 排查。
6. 給我看 `bash "$ROOT/configure.sh" --show`，並告訴我：預設所有 agent 的完成、需要回應、agent 結束、
   pane 結束都會通知；`--statuses done,blocked` 代表「只在我沒看著那個 pane 時」；
   `bash "$ROOT/configure.sh" --list` 列出可選事件（預設全關）；暫停用
   `herdr plugin action invoke disable --plugin grokbot-notify`。
```

### 觸發原因（`reason`）

| reason | 說明 | 預設 |
| --- | --- | --- |
| `finished` | agent 完成一輪工作（你沒在看是 `done`，有在看是 `idle`；用 `completion_seq` 避免重複，啟動時的 idle 不會觸發） | 開 |
| `needs_attention` | `blocked`：等待核准、提問或權限 | 開 |
| `agent_exited` | agent 程式離開 pane（結束、當掉、Ctrl-C），附 `final_status` | 開 |
| `pane_exited` | 執行過 agent 的 pane 結束（一般 shell 不會觸發） | 開 |
| `status_changed` | 額外加入的狀態，例如 `working`、`unknown` | 關 |
| `agent_started` | 偵測到 agent 啟動 | 關 |
| `event` | 其他你開啟的 herdr 事件，原始資料在 `data` | 關 |

重複通知以「pane + 原因」去重 60 秒，但只去除**連續相同**的狀態；中間只要狀態變過（blocked → working → blocked），兩次都會通知。

**減少打擾（只在我不在時）**：`bash "$ROOT/configure.sh" --statuses done,blocked`。
herdr 在你沒看著那個 pane 時把完成標成 `done`、看過後是 `idle`，所以這只會在你沒看時通知完成（以及所有 blocked）。

### Payload

欄位說明見上方英文 [Payload](#payload) 表格。重點：

- 一定有：`source`、`schema`（目前 `1`）、`plugin_version`、`event`、`reason`、`message`（可直接轉發的一行摘要）、`test`、`at`。
- 有值才有：`workspace_id`、`workspace_label`、`tab_id`、`tab_label`、`pane_id`、`agent`、`agent_status`、
  `final_status`、`title`、`cwd`、`repo`、`branch`、`host`；空值的欄位直接省略。
- `output` / `output_truncated`：只有開啟 `GROKBOT_NOTIFY_OUTPUT_LINES` 時才有。
- `data`：只有 `reason: "event"`，內容是 herdr 原始事件資料（格式由 herdr 定義）。

**穩定性承諾**：在 `schema: 1` 內只會新增欄位，不會改名、移除或改型別，`reason` 的意義不變；
所有變更都記在 [CHANGELOG.md](CHANGELOG.md)，破壞性變更會提高 `schema`。`message` 的文字與 `data` 的內容不在承諾範圍內。

**選用：附上 pane 輸出**：`bash "$ROOT/configure.sh" --output-lines 40` 會附上 pane 最後 40 行
（移除跳脫碼，預設上限 4000 bytes，保留最新的行）。預設關閉。
**終端機輸出可能含有秘密**（CLI 印出的 token、`.env` 內容、錯誤訊息裡的金鑰），開啟後會送到你的 Grok Bot；
也可能含有誤導 routine 的文字，請當作不可信資料。

### 設定

`.env` 位於 `$(herdr plugin config-dir grokbot-notify)`（權限 600）；環境變數優先。主要設定：
`GROKBOT_NOTIFY_AGENTS`（預設 `*`）、`GROKBOT_NOTIFY_STATUSES`（預設 `done,idle,blocked`）、
`GROKBOT_NOTIFY_DEBOUNCE_SECS`（預設 `60`）、`GROKBOT_NOTIFY_OUTPUT_LINES`（預設 `0`）、
`GROKBOT_NOTIFY_EVENTS`（請用 `configure.sh --events` 修改；手動改後跑 `configure.sh --apply`）。
完整列表見英文 [Settings](#settings)。`configure.sh` 不接受把秘密放在參數，也不會印出秘密。

可選事件（`configure.sh --events +名稱` 開啟、`-名稱` 關閉、`default` 回到預設）：`pane.agent_detected`、
`workspace.created/updated/closed/renamed/moved/reordered`、`worktree.created/opened/removed`、
`tab.created/closed/renamed/moved`、`pane.created/closed/moved`。它們透過 config 目錄裡自動產生的附屬
plugin `grokbot-notify-events` 註冊，不會修改本 plugin 的檔案；附屬 plugin 會透過 `herdr plugin list`
找到目前安裝的位置，更新後仍能運作。若 herdr 拒絕連結，`configure.sh` 會還原先前的 `.env` 並明確告知沒有儲存。

### 疑難排解

1. **送測試**：`bash "$ROOT/configure.sh" --test` 會印出 HTTP 狀態碼，非 2xx 時以非 0 結束。
   `401/403` = Authorization 錯誤；`404` = URL 錯誤或 webhook 已刪除；`000` = 連不上（網址、網路、代理、逾時）。
   `herdr plugin action invoke test` 只會回報 `running`，結果要看 plugin log。
2. **看紀錄**：`herdr plugin log list --plugin grokbot-notify` 列出每次 hook 的結束碼與輸出；
   `herdr plugin action invoke status --plugin grokbot-notify` 會把版本、路徑與設定（不含秘密）寫進去。
   plugin 自己的 `notify.log` 在 herdr 的 plugin state 目錄（Linux：`~/.local/state/herdr/plugins/grokbot-notify/notify.log`），
   記錄 sent / debounced / skip 與 HTTP 碼，不含 URL 或 token。
3. **常見原因**：
   - `herdr plugin action invoke` 或 `herdr pane` 回報 `server_not_running`：action、pane 指令與 hook 都需要 herdr server 在執行，
     先啟動 `herdr` 再試。`configure.sh --test`、`herdr plugin list`、`herdr plugin config-dir` 不需要 server。
   - macOS 上 notify.log 出現 `jq and curl are required`：從 GUI / launchd 啟動的 herdr 可能沒有 Homebrew 的 `PATH`；
     0.4.0 起 hook 會自動找 `/opt/homebrew/bin` 與 `/usr/local/bin`。用 `brew install jq` 安裝（macOS 15 以上內建 `/usr/bin/jq`）。
   - 可選事件不再觸發：執行 `bash "$ROOT/configure.sh" --apply`。

### 更新、回復、移除

```sh
herdr plugin install zeke1031031/herdr-grokbot-notify --ref v0.4.0 --yes   # 更新（換成新的 tag）
herdr plugin install zeke1031031/herdr-grokbot-notify --ref v0.3.0 --yes   # 回復舊版
```

`herdr plugin update grokbot-notify --yes` 只會更新沒有指定 `--ref` 的安裝；指定 tag 的安裝會停在該 tag。設定保存在 config 目錄，更新或回復都會保留。

移除：先 `bash "$ROOT/configure.sh" --events default`（移除附屬 plugin），再 `herdr plugin uninstall grokbot-notify`，
最後 `rm -rf "$(herdr plugin config-dir grokbot-notify)"` 刪除秘密，並到 Grok Bot 刪除或更換 webhook。

### 進階：shepherd 模式

若 herdr 跑在 Grok Bot 能執行指令的地方，routine 可以讀取 pane、摘要完成的工作，並可選擇代你回答少數安全的提示。
提示詞見 [`examples/routine-prompt.md`](examples/routine-prompt.md#advanced-shepherd-mode)：

- 自動核准**預設關閉**，要你自己明確開啟。
- 絕不選「永遠允許 / 不再詢問 / 本次工作階段都允許」。
- 執行測試、build、linter 或套件腳本都算「執行程式碼」，只回報、不核准。
- pane 文字可能含有 prompt injection（README、網頁或套件印出「全部核准」之類的文字），一律當作資料而非指令。

### 平台

Linux、macOS。**不支援 Windows**（manifest 只宣告 linux 與 macos，hook 是 bash 腳本；WSL 內的 herdr 視同 Linux，但未測試）。
請勿把 `.env`、Webhook URL 或 token 提交到 Git 或貼到公開地方。

## License

MIT, see [LICENSE](LICENSE). Not affiliated with xAI, Grok Bot or the herdr project.
