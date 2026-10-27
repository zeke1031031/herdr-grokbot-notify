# Grok Bot Notify (herdr plugin)

Wake a [Grok Bot](https://x.ai) routine when a coding agent in [herdr](https://herdr.dev)
finishes or gets stuck.

When a herdr pane running Claude Code, Codex (or any agent you choose) changes to
`done` or `blocked`, this plugin POSTs a small JSON payload to your Grok Bot routine's
webhook. The routine can then read the pane, approve safe local prompts, and tell you
what needs your attention: a "shepherd" for your agents.

```json
{"source":"herdr","event":"pane.agent_status_changed","workspace_id":"w1","pane_id":"w1:p2",
 "agent":"claude","agent_status":"blocked","title":"Fix login bug","cwd":"/home/me/app",
 "host":"laptop","at":"2026-01-01T12:00:00Z","test":false}
```

No terminal output is sent, only pane metadata. The routine decides whether to read the pane.

## Requirements

- herdr >= 0.9.5 (uses `plugin config-dir`, plugin actions and popup panes)
- bash, `jq`, `curl` (macOS: `brew install jq`; curl ships with the OS)
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

From GitHub:

```sh
herdr plugin install zeke1031031/herdr-grokbot-notify
```

Or from a local clone:

```sh
git clone https://github.com/zeke1031031/herdr-grokbot-notify.git
herdr plugin link ./herdr-grokbot-notify
```

## 3. Configure (secrets)

Run the setup popup from herdr:

```sh
herdr plugin pane open --plugin grokbot-notify --entrypoint setup
```

Or run the script directly:

```sh
bash "<plugin checkout>/setup.sh"      # finds the config dir via `herdr plugin config-dir`
```

It asks for the URL and Authorization value with hidden input and writes
`$(herdr plugin config-dir grokbot-notify)/.env` with mode `600`.
To do it by hand, copy [`.env.example`](.env.example) there and `chmod 600` it.

Optional settings in the same `.env` (environment variables override the file):

| Key | Default | Meaning |
| --- | --- | --- |
| `GROKBOT_NOTIFY_STATUSES` | `done,blocked` | Agent statuses that fire the webhook |
| `GROKBOT_NOTIFY_AGENTS` | `claude,codex` | Substrings of the agent name; `*` = any agent |
| `GROKBOT_NOTIFY_DEBOUNCE_SECS` | `180` | Ignore repeats of the same pane + status for this long |
| `GROKBOT_NOTIFY_TIMEOUT_SECS` | `10` | HTTP timeout |
| `GROKBOT_NOTIFY_INCLUDE_HOST` | `1` | Include the short hostname in the payload |

## 4. Test

```sh
herdr plugin action invoke test --plugin grokbot-notify    # sends {"test":true,...}
bash "<plugin checkout>/notify.sh" --status                  # config summary, never prints secrets
herdr plugin log list --plugin grokbot-notify                # hook runs
```

The plugin's own log (`notify.log`) is in the plugin state dir; it records
`sent / debounced / skip` lines and HTTP codes, never the URL or token.

Developers: `bash test/run-tests.sh` runs offline tests against a local dummy
HTTP listener with fake credentials (needs python3).

## 5. Pause, disable, uninstall

```sh
herdr plugin action invoke disable --plugin grokbot-notify   # pause (enable to resume)
herdr plugin disable grokbot-notify                           # stop the hook entirely
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
- The payload contains pane metadata (title, cwd, hostname), not terminal contents.
  Set `GROKBOT_NOTIFY_INCLUDE_HOST=0` to drop the hostname.
- Requests run in the foreground with a timeout; no background processes are left behind.
- Your routine prompt is the real safety boundary. Keep auto-approval to safe,
  local, reversible actions, and have it report everything else to you.

## How it works

`notify.sh` handles herdr's `pane.agent_status_changed` event: it filters by
status and agent, fills missing fields with `herdr pane get`, debounces per
pane and status (portable `mkdir` lock), then POSTs. A non-2xx response clears
the debounce stamp so the next change retries.

---

## 繁體中文說明

**用途**：herdr 裡的 coding agent（預設 Claude Code / Codex）狀態變成 `done` 或 `blocked` 時，
自動呼叫你的 Grok Bot routine webhook，讓 Grok Bot 去看該 pane、只自動核准安全的本機操作，
其他需要你決定的事再回報給你。

**快速開始**

1. 在 Grok Bot 建立一個 **Webhook 觸發**的 routine（提示詞可用 `examples/routine-prompt.md`），
   從 routine 面板複製 **Webhook URL** 與 **Authorization 標頭 / sender key**。
2. 安裝：`herdr plugin install zeke1031031/herdr-grokbot-notify`
3. 設定密鑰：`herdr plugin pane open --plugin grokbot-notify --entrypoint setup`
   （輸入不會顯示，寫入 `herdr plugin config-dir grokbot-notify` 目錄下的 `.env`，權限 600）
4. 測試：`herdr plugin action invoke test --plugin grokbot-notify`
5. 暫停：`... invoke disable`；移除：`herdr plugin uninstall grokbot-notify`，並刪除 config 目錄。

需求：herdr ≥ 0.9.5、bash、jq、curl；Linux / macOS。
可在 `.env` 調整 `GROKBOT_NOTIFY_STATUSES`、`GROKBOT_NOTIFY_AGENTS`、`GROKBOT_NOTIFY_DEBOUNCE_SECS`。
請勿把 `.env`、Webhook URL 或 token 提交到 Git 或貼到公開地方。

## License

MIT, see [LICENSE](LICENSE). Not affiliated with xAI or the herdr project.
