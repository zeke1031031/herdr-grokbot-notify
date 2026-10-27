# Grok Bot Notify (herdr plugin)

Wake a [Grok Bot](https://x.ai) routine when any coding agent in [herdr](https://herdr.dev)
finishes, needs your input, or exits.

Every agent herdr detects is covered by default: Claude Code, Codex, Cursor Agent,
GitHub Copilot CLI, Gemini CLI, OpenCode, Pi, Grok CLI, Amp, Droid, Devin, Kimi, Kilo,
Kiro, Hermes, Qoder, Qwen, Letta, Maki, Cline, Antigravity, MastraCode, OMP, and agents
that report themselves to herdr (Command Code, Crush, Muse Code, Prime Agent, ...).
The plugin POSTs a small JSON payload to your routine's webhook. The routine can then
read the pane, approve safe local prompts, and tell you what needs your attention:
a "shepherd" for your agents.

```json
{"source":"herdr","plugin_version":"0.3.0","event":"pane.agent_status_changed",
 "reason":"needs_attention","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p2",
 "agent":"claude","agent_status":"blocked","title":"Fix login bug","cwd":"/home/me/app",
 "host":"laptop","at":"2026-01-01T12:00:00Z","test":false}
```

No terminal output is sent, only pane metadata. The routine decides whether to read the pane.

## What fires the webhook

`reason` tells the routine why it was woken:

| `reason` | When | Default |
| --- | --- | --- |
| `finished` | The agent completed a turn. herdr reports this as `done` (you weren't looking) or `idle` (you were). The plugin uses herdr's `completion_seq` so each turn is sent once, and agents that are merely idle at startup stay quiet. | on |
| `needs_attention` | `blocked`: herdr recognised an approval, question, or permission prompt. | on |
| `agent_exited` | The agent process left the pane (quit, crash, `Ctrl-C`). `final_status` is its last state. | on |
| `pane_exited` | A pane that was running a detected agent exited. Plain shells stay quiet. | on |
| `status_changed` | Any other status you add to `GROKBOT_NOTIFY_STATUSES` (`working`, `unknown`). | off |
| `agent_started` | herdr detected an agent starting in a pane (`pane.agent_detected`). | off |
| `event` | Any other herdr event you opt into. The raw herdr event data is in `data`. | off |
| `test` | The `test` action. | - |

By default only the agent signals are registered with herdr (`pane.agent_status_changed`,
`pane.agent_detected`, `pane.exited`), so herdr starts no hook process for anything else.
Optional events are off until you turn them on with `configure.sh --events +name`
(see [Configure from a script or a bot](#configure-from-a-script-or-a-bot)):

| Event | Fires when | `reason` |
| --- | --- | --- |
| `pane.agent_detected` | an agent started in a pane | `agent_started` |
| `workspace.created` | a workspace was created | `event` |
| `workspace.updated` | a workspace changed (e.g. its cwd or settings) | `event` |
| `workspace.closed` | a workspace was closed | `event` |
| `workspace.renamed` | a workspace was renamed | `event` |
| `workspace.moved` | a workspace was moved | `event` |
| `workspace.reordered` | the workspace list was reordered | `event` |
| `worktree.created` | a git worktree was created from herdr | `event` |
| `worktree.opened` | an existing git worktree was opened as a workspace | `event` |
| `worktree.removed` | a git worktree was removed | `event` |
| `tab.created` / `tab.closed` | a tab was created / closed | `event` |
| `tab.renamed` / `tab.moved` | a tab was renamed / moved | `event` |
| `pane.created` / `pane.closed` | a pane was created / closed | `event` |
| `pane.moved` | a pane was moved | `event` |

The default events can be switched off the same way (`-pane.exited`, `-agent.released`,
`-pane.agent_status_changed`). `agent.released` is this plugin's name for
"`pane.agent_detected` with `released: true`". `workspace.focused`, `tab.focused` and
`pane.focused` are not offered: they fire on every click or switch.

herdr does not let plugins hook terminal output (`pane.output_matched`), `pane.updated`,
`layout.updated`, or `workspace.metadata_updated`; those are only on the socket
subscription API. herdr has no separate "error" status: a crashed agent shows up as
`agent_exited` or `pane_exited`.

## Requirements

- herdr >= 0.9.5 (uses `plugin config-dir`, plugin actions and popup panes)
- bash (written for 3.2+, so macOS `/bin/bash` is fine), `jq`, `curl` (macOS: `brew install jq`; curl ships with the OS)
- A Grok Bot routine with a **Webhook** trigger
- Linux or macOS. Optional: `timeout` (coreutils). No `flock` needed.

## 1. Create the Grok Bot routine

1. In Grok Bot, ask it to create a routine triggered by a **webhook**, e.g.
   *"Create a routine with a webhook trigger that shepherds my herdr agents"*,
   and give it the prompt in [`examples/routine-prompt.md`](examples/routine-prompt.md).
2. Open the routine panel and copy:
   - the **webhook URL**
   - the **Authorization header / sender key** value
3. Treat both as secrets. Anyone with them can wake your bot.

For the shepherd prompt to act on panes, herdr must run somewhere your Grok Bot can run
commands (its own box, or a computer you registered with it). If not, use a
notify-only prompt instead ("summarise the payload and message me").

## 2. Install

```sh
herdr plugin install zeke1031031/herdr-grokbot-notify
```

Or from a local clone:

```sh
git clone https://github.com/zeke1031031/herdr-grokbot-notify.git
herdr plugin link ./herdr-grokbot-notify
```

## 3. Set up (one step)

```sh
herdr plugin pane open --plugin grokbot-notify --entrypoint setup
```

Paste the webhook URL and the Authorization value (input is hidden). That's it: every
agent, finished / blocked / exited. The popup then offers optional events and settings
(agents, statuses, debounce) and a test webhook. It writes
`$(herdr plugin config-dir grokbot-notify)/.env` with mode `600`. Run it again any time;
press Enter to keep the saved values.

### Configure from a script or a bot

`configure.sh` does the same without prompts. It never takes secrets as arguments and
never prints them.

```sh
ROOT="$(herdr plugin list --plugin grokbot-notify --json | jq -r '.result.plugins[0].plugin_root')"

# secrets from the environment (or: printf '%s\n%s\n' "$URL" "$AUTH" | ... --secrets-from-stdin)
GROKBOT_WEBHOOK_URL=... GROKBOT_WEBHOOK_AUTH=... bash "$ROOT/configure.sh" --url-from-env --auth-from-env

bash "$ROOT/configure.sh" --list                          # every event, on/off, one-line description
bash "$ROOT/configure.sh" --list --json                   # same, for a bot
bash "$ROOT/configure.sh" --events +tab.created,+worktree.created,-pane.exited
bash "$ROOT/configure.sh" --events none                   # back to the default events only
bash "$ROOT/configure.sh" --agents claude,codex --statuses done,idle,blocked --debounce 60
bash "$ROOT/configure.sh" --show                          # summary; secrets shown as set / MISSING
bash "$ROOT/configure.sh" --test                          # send the test webhook
```

`--events` takes `+name` (turn on), `-name` (turn off), bare names (replace the optional
set, defaults untouched), or `none` / `all` / `default`. Unknown names and `*.focused` are
rejected and nothing is written.

How optional events are registered: herdr only runs hooks listed in a plugin manifest and
has no setting to add more, but it re-reads manifests before every event. Instead of
editing this plugin's `herdr-plugin.toml` (which would conflict with `git pull` and be
lost on `herdr plugin update`), `configure.sh` writes a tiny companion plugin,
`grokbot-notify-events`, into the config dir and runs `herdr plugin link` on it. Its
manifest lists only the events you chose, and its hook hands them to this plugin's
`notify.sh` with the same config. With no optional events the companion is unlinked and
deleted. If you edit `GROKBOT_NOTIFY_EVENTS` in `.env` by hand, run
`configure.sh --apply` (or `herdr plugin action invoke apply --plugin grokbot-notify`)
to sync the hooks.

You can also copy [`.env.example`](.env.example) to the config dir by hand and `chmod 600` it.

Settings (environment variables override the file):

| Key | Default | Meaning |
| --- | --- | --- |
| `GROKBOT_NOTIFY_AGENTS` | `*` | Comma-separated agent ids/substrings (`claude,codex,cursor`); `*` = every agent |
| `GROKBOT_NOTIFY_EVENTS` | `pane.agent_status_changed,agent.released,pane.exited` | Which events may fire (set with `configure.sh --events`) |
| `GROKBOT_NOTIFY_STATUSES` | `done,idle,blocked` | Statuses for `pane.agent_status_changed`. `done`/`idle` mean "finished" |
| `GROKBOT_NOTIFY_DEBOUNCE_SECS` | `60` | Ignore repeats of the same pane + reason for this long (`0` = off). Each new completed turn still gets through |
| `GROKBOT_NOTIFY_TIMEOUT_SECS` | `10` | HTTP timeout |
| `GROKBOT_NOTIFY_INCLUDE_HOST` | `1` | Include the short hostname in the payload |

The agent filter applies to agent events (`finished`, `needs_attention`, `agent_exited`,
`pane_exited`, `agent_started`). Other opt-in events are not filtered by agent.

## Set up with Grok Bot

Let your Grok Bot do all of the above. Paste this into a chat with it:

```text
Set up herdr -> Grok Bot notifications for me with the herdr-grokbot-notify plugin
(https://github.com/zeke1031031/herdr-grokbot-notify). Work on the computer where herdr runs.
Never print, log or echo the webhook URL or Authorization value, and never ask me to
paste them in chat.

1. Create a routine with a Webhook trigger called "herdr agent shepherd".
2. Ask me for that routine's webhook URL and Authorization header with a secret request.
3. Check herdr >= 0.9.5, bash, jq and curl. Install the plugin with
   `herdr plugin install zeke1031031/herdr-grokbot-notify` (if it is already installed:
   `herdr plugin update grokbot-notify`), then find its folder:
   ROOT="$(herdr plugin list --plugin grokbot-notify --json | jq -r '.result.plugins[0].plugin_root')"
4. Save the secrets: pass them only as the environment variables GROKBOT_WEBHOOK_URL and
   GROKBOT_WEBHOOK_AUTH and run `bash "$ROOT/configure.sh" --url-from-env --auth-from-env`.
5. Run `bash "$ROOT/configure.sh" --list` and show me the optional events with their
   one-line descriptions. By default I only get finished, needs attention, agent exited
   and pane exited, and no optional event is on. Turn on only the ones I pick, e.g.
   `bash "$ROOT/configure.sh" --events +worktree.created,+tab.created`.
6. Run `herdr plugin action invoke test --plugin grokbot-notify` and check that the
   routine received a payload with "test": true.
7. Set the routine's prompt to examples/routine-prompt.md from the repo. Then show me
   `bash "$ROOT/configure.sh" --show` and tell me how to pause it
   (`herdr plugin action invoke disable --plugin grokbot-notify`) or change events later.
```

## 4. Test

```sh
herdr plugin action invoke test --plugin grokbot-notify      # sends {"test":true,...}
herdr plugin action invoke status --plugin grokbot-notify    # config summary, never prints secrets
herdr plugin log list --plugin grokbot-notify                # hook runs
```

The plugin's own log (`notify.log`) is in the plugin state dir; it records
`sent / debounced / skip` lines and HTTP codes, never the URL or token.

Developers: `bash test/run-tests.sh` runs offline tests against a local dummy
HTTP listener with fake credentials and a stub `herdr` (needs python3).

## 5. Pause, disable, uninstall

```sh
herdr plugin action invoke disable --plugin grokbot-notify   # pause (enable to resume)
herdr plugin disable grokbot-notify                           # stop the hooks entirely
bash "$ROOT/configure.sh" --events default                  # drop optional-event hooks (companion)
herdr plugin uninstall grokbot-notify                         # or: herdr plugin unlink grokbot-notify
rm -rf "$(herdr plugin config-dir grokbot-notify)"            # remove saved secrets
```

Also delete or rotate the webhook in the Grok Bot routine panel if you no longer use it.

## Security notes

- Secrets live only in the plugin **config dir** `.env` (mode 600), never in the plugin
  checkout. `.gitignore` blocks `.env` files.
- The `.env` is parsed as `KEY=VALUE`, never `source`d, so it cannot run code.
- The URL and Authorization header are passed to `curl` through a temporary mode-600
  config file, so they don't appear in `ps` output, and they are never logged.
- The payload contains pane metadata (title, cwd, hostname) and, for opt-in events,
  herdr's event data (ids, labels, worktree paths). Never terminal contents.
  Set `GROKBOT_NOTIFY_INCLUDE_HOST=0` to drop the hostname.
- Requests run in the foreground with a timeout; no background processes are left behind.
- Your routine prompt is the real safety boundary. Keep auto-approval to safe,
  local, reversible actions, and have it report everything else to you.

## How it works

The manifest registers `notify.sh` for the three agent events only; optional events
come through the generated companion plugin (see above), so an event you didn't choose
never starts a process. A `disable` action pauses both (a `paused` flag in the config
dir). For agent events it keeps tiny
per-pane state (last status, agent name, last completion sent) in the plugin state dir,
asks `herdr agent get` for `completion_seq` and pane metadata, debounces per pane and
reason (portable `mkdir` lock), then POSTs. A non-2xx response clears the debounce
stamp so the next change retries.

Limits: herdr detects status from the screen for most agents, so a brand-new prompt
style can show as `idle` instead of `blocked` until herdr learns it. Antigravity and
Grok report `idle` when they return to their prompt, even if background jobs still run.
Agents that herdr doesn't detect (plain terminals) never produce agent events.

---

## 繁體中文說明

**用途**：herdr 偵測到的所有 coding agent（Claude Code、Codex、Cursor、Copilot、Gemini、
OpenCode、Pi、Grok、Amp、Droid、Kimi、Kiro、Qwen… 以及自行回報狀態的 agent）
**完成工作、需要你回應（blocked）、或結束/當掉**時，自動呼叫你的 Grok Bot routine webhook。
Grok Bot 可以去讀該 pane、只自動核准安全的本機操作，其他需要你決定的事再回報給你。
payload 只有 pane 的中繼資料，不含終端機輸出。

**觸發原因（`reason`）**

| reason | 說明 | 預設 |
| --- | --- | --- |
| `finished` | agent 完成一輪工作（`done` 或你正在看時的 `idle`；用 herdr 的 `completion_seq` 避免重複，啟動時的 idle 不會觸發） | 開 |
| `needs_attention` | `blocked`：等待核准、提問或權限 | 開 |
| `agent_exited` | agent 程式離開 pane（結束、當掉、Ctrl-C），附 `final_status` | 開 |
| `pane_exited` | 執行過 agent 的 pane 結束（一般 shell 不會觸發） | 開 |
| `status_changed` | 額外加入的狀態，例如 `working`、`unknown` | 關 |
| `agent_started` | 偵測到 agent 啟動（`pane.agent_detected`） | 關 |
| `event` | 其他 herdr 事件（workspace / worktree / tab / pane 生命週期，不含 `*.focused` 焦點事件），原始資料放在 `data` | 關 |

預設只向 herdr 註冊 agent 相關的 3 個事件，其他事件完全不會啟動程序。可選事件用
`configure.sh --events +名稱` 開啟、`-名稱` 關閉（`none` = 回到預設），`--list` 會列出每個事件與一行說明：
`pane.agent_detected`（agent 啟動）、`workspace.created/updated/closed/renamed/moved/reordered`、
`worktree.created/opened/removed`、`tab.created/closed/renamed/moved`、`pane.created/closed/moved`。
herdr 沒有「另外加事件」的設定，但每次事件前都會重讀 manifest；所以 `configure.sh` 不改本 plugin 的檔案
（避免 `git pull` 衝突、`herdr plugin update` 後消失），而是在 config 目錄產生一個只列出你選的事件的
小型附屬 plugin `grokbot-notify-events` 並 `herdr plugin link`；沒有可選事件時會自動移除。

**快速開始**

1. 在 Grok Bot 建立一個 **Webhook 觸發**的 routine（提示詞可用 `examples/routine-prompt.md`），
   從 routine 面板複製 **Webhook URL** 與 **Authorization 標頭 / sender key**。
2. 安裝：`herdr plugin install zeke1031031/herdr-grokbot-notify`
3. 設定（一步完成）：`herdr plugin pane open --plugin grokbot-notify --entrypoint setup`
   貼上 URL 和 Authorization（輸入不會顯示）即可；進階設定（agent、事件、狀態、debounce）可選。
   寫入 `herdr plugin config-dir grokbot-notify` 目錄下的 `.env`，權限 600。
4. 測試：`herdr plugin action invoke test --plugin grokbot-notify`
5. 暫停：`... invoke disable`；移除：先 `configure.sh --events default`，再 `herdr plugin uninstall grokbot-notify`，並刪除 config 目錄。

**給腳本 / Bot 用的非互動設定**（不接受把秘密放在參數，也不會印出）：

```sh
ROOT="$(herdr plugin list --plugin grokbot-notify --json | jq -r '.result.plugins[0].plugin_root')"
GROKBOT_WEBHOOK_URL=... GROKBOT_WEBHOOK_AUTH=... bash "$ROOT/configure.sh" --url-from-env --auth-from-env
bash "$ROOT/configure.sh" --list            # 列出事件、開關狀態、一行說明（--json 給 bot）
bash "$ROOT/configure.sh" --events +tab.created,-pane.exited
bash "$ROOT/configure.sh" --show            # 摘要；秘密只顯示 set / MISSING
```

**用 Grok Bot 設定**：把下面這段貼給你的 Grok Bot（英文版見上方 “Set up with Grok Bot”）：

```text
請用 herdr-grokbot-notify plugin（https://github.com/zeke1031031/herdr-grokbot-notify）幫我設定
herdr -> Grok Bot 通知，在跑 herdr 的那台電腦上操作。絕對不要印出、記錄或回顯 webhook URL 與
Authorization，也不要叫我貼在聊天裡。

1. 建立一個 Webhook 觸發的 routine，名稱 "herdr agent shepherd"。
2. 用 secret request（秘密輸入）向我要這個 routine 的 webhook URL 和 Authorization 標頭。
3. 確認 herdr >= 0.9.5、bash、jq、curl。安裝：`herdr plugin install zeke1031031/herdr-grokbot-notify`
   （已安裝就 `herdr plugin update grokbot-notify`），再找出資料夾：
   ROOT="$(herdr plugin list --plugin grokbot-notify --json | jq -r '.result.plugins[0].plugin_root')"
4. 只透過環境變數 GROKBOT_WEBHOOK_URL、GROKBOT_WEBHOOK_AUTH 傳入秘密，執行
   `bash "$ROOT/configure.sh" --url-from-env --auth-from-env`。
5. 執行 `bash "$ROOT/configure.sh" --list`，把可選事件和一行說明列給我。預設只有完成、需要處理、
   agent 結束、pane 結束，可選事件全部關閉；只開我選的，例如
   `bash "$ROOT/configure.sh" --events +worktree.created,+tab.created`。
6. 執行 `herdr plugin action invoke test --plugin grokbot-notify`，確認 routine 收到 "test": true。
7. 把 repo 裡的 examples/routine-prompt.md 設為 routine 的提示詞，再給我看
   `bash "$ROOT/configure.sh" --show`，並告訴我之後怎麼暫停（action disable）或改事件。
```

**設定**（`.env` 或環境變數）：

- `GROKBOT_NOTIFY_AGENTS`：預設 `*`（全部 agent），可改成 `claude,codex` 等
- `GROKBOT_NOTIFY_EVENTS`：預設 `pane.agent_status_changed,agent.released,pane.exited`；
  請用 `configure.sh --events` 修改（手動改 `.env` 後要跑 `configure.sh --apply`）
- `GROKBOT_NOTIFY_STATUSES`：預設 `done,idle,blocked`
- `GROKBOT_NOTIFY_DEBOUNCE_SECS`：預設 `60`（同一 pane 同一原因的重複通知間隔；每個新完成的工作仍會送出）

**無法支援的部分**：herdr 不開放 plugin 掛勾終端輸出比對（`pane.output_matched`）、
`pane.updated`、`layout.updated`、`workspace.metadata_updated`；也沒有獨立的「錯誤」狀態，
當掉會以 `agent_exited` / `pane_exited` 呈現。

需求：herdr ≥ 0.9.5、bash、jq、curl；Linux / macOS。
請勿把 `.env`、Webhook URL 或 token 提交到 Git 或貼到公開地方。

## License

MIT, see [LICENSE](LICENSE). Not affiliated with xAI or the herdr project.
