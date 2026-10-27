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
{"source":"herdr","plugin_version":"0.2.0","event":"pane.agent_status_changed",
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

Opt-in events: all hookable herdr 0.9.5 plugin events are registered, so you turn them on
in config without editing the manifest:

- workspaces: `workspace.created`, `workspace.updated`, `workspace.closed`, `workspace.renamed`,
  `workspace.moved`, `workspace.reordered`, `workspace.focused`
- worktrees: `worktree.created`, `worktree.opened`, `worktree.removed`
- tabs: `tab.created`, `tab.closed`, `tab.renamed`, `tab.moved`, `tab.focused`
- panes: `pane.created`, `pane.closed`, `pane.focused`, `pane.moved`, `pane.exited`,
  `pane.agent_detected`, `pane.agent_status_changed`
- `agent.released`: this plugin's shorthand for "`pane.agent_detected` with `released: true`".

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
agent, finished / blocked / exited. The popup then offers optional advanced settings
(agents, events, statuses, debounce) and a test webhook. It writes
`$(herdr plugin config-dir grokbot-notify)/.env` with mode `600`. Run it again any time;
press Enter to keep the saved values. You can also run `bash setup.sh` from a checkout,
or copy [`.env.example`](.env.example) there by hand and `chmod 600` it.

Settings (environment variables override the file):

| Key | Default | Meaning |
| --- | --- | --- |
| `GROKBOT_NOTIFY_AGENTS` | `*` | Comma-separated agent ids/substrings (`claude,codex,cursor`); `*` = every agent |
| `GROKBOT_NOTIFY_EVENTS` | `pane.agent_status_changed,agent.released,pane.exited` | Which herdr events may fire; `*` = all |
| `GROKBOT_NOTIFY_STATUSES` | `done,idle,blocked` | Statuses for `pane.agent_status_changed`. `done`/`idle` mean "finished" |
| `GROKBOT_NOTIFY_DEBOUNCE_SECS` | `60` | Ignore repeats of the same pane + reason for this long (`0` = off). Each new completed turn still gets through |
| `GROKBOT_NOTIFY_TIMEOUT_SECS` | `10` | HTTP timeout |
| `GROKBOT_NOTIFY_INCLUDE_HOST` | `1` | Include the short hostname in the payload |

The agent filter applies to agent events (`finished`, `needs_attention`, `agent_exited`,
`pane_exited`, `agent_started`). Other opt-in events are not filtered by agent.

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

The manifest registers `notify.sh` for all 22 hookable herdr events. For an event you
didn't enable, `notify.sh` exits before doing any work. For agent events it keeps tiny
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
| `event` | 其他 herdr 事件（workspace / worktree / tab / pane），原始資料放在 `data` | 關 |

**快速開始**

1. 在 Grok Bot 建立一個 **Webhook 觸發**的 routine（提示詞可用 `examples/routine-prompt.md`），
   從 routine 面板複製 **Webhook URL** 與 **Authorization 標頭 / sender key**。
2. 安裝：`herdr plugin install zeke1031031/herdr-grokbot-notify`
3. 設定（一步完成）：`herdr plugin pane open --plugin grokbot-notify --entrypoint setup`
   貼上 URL 和 Authorization（輸入不會顯示）即可；進階設定（agent、事件、狀態、debounce）可選。
   寫入 `herdr plugin config-dir grokbot-notify` 目錄下的 `.env`，權限 600。
4. 測試：`herdr plugin action invoke test --plugin grokbot-notify`
5. 暫停：`... invoke disable`；移除：`herdr plugin uninstall grokbot-notify`，並刪除 config 目錄。

**設定**（`.env` 或環境變數）：

- `GROKBOT_NOTIFY_AGENTS`：預設 `*`（全部 agent），可改成 `claude,codex` 等
- `GROKBOT_NOTIFY_EVENTS`：預設 `pane.agent_status_changed,agent.released,pane.exited`；
  可加入 `worktree.created`、`tab.created`、`workspace.closed` 等，或 `*` 全部
- `GROKBOT_NOTIFY_STATUSES`：預設 `done,idle,blocked`
- `GROKBOT_NOTIFY_DEBOUNCE_SECS`：預設 `60`（同一 pane 同一原因的重複通知間隔；每個新完成的工作仍會送出）

**無法支援的部分**：herdr 不開放 plugin 掛勾終端輸出比對（`pane.output_matched`）、
`pane.updated`、`layout.updated`、`workspace.metadata_updated`；也沒有獨立的「錯誤」狀態，
當掉會以 `agent_exited` / `pane_exited` 呈現。

需求：herdr ≥ 0.9.5、bash、jq、curl；Linux / macOS。
請勿把 `.env`、Webhook URL 或 token 提交到 Git 或貼到公開地方。

## License

MIT, see [LICENSE](LICENSE). Not affiliated with xAI or the herdr project.
