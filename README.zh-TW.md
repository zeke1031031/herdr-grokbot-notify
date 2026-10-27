# Grok Bot Notify（herdr 外掛）

[English](README.md) | 繁體中文

當 [herdr](https://herdr.dev) 裡任何 coding agent 完成工作或需要你時，用 webhook 叫醒你的
[Grok Bot](https://grokbot.dev/) routine。支援 Claude Code、Codex、Cursor、Copilot、Gemini、
OpenCode、Grok、Amp、Kimi、Qwen，以及所有 herdr 偵測得到的 agent。

例如，你會在手機上收到這樣的通知：

> **需要你：** claude 在 laptop 的 app (fix/login) 需要你回應：Fix login bug [api / review]

## 快速開始

1. **建立 webhook routine。** 在 Grok Bot 建立一個以 **Webhook** 觸發的 routine，提示詞使用
   [`examples/routine-prompt.md`](examples/routine-prompt.md) 裡的 notify-only 版本。
   複製 routine 的 **webhook URL** 與 **Authorization 標頭**。兩者都應視為秘密。
2. **安裝**（herdr 0.9.5 以上、Linux 或 macOS，需要 `bash`、`jq`、`curl`）：

   ```sh
   herdr plugin install zeke1031031/herdr-grokbot-notify --ref v0.4.0 --yes
   ```

   會印出 manifest 預覽（掛勾的事件與執行的指令）。在終端機裡拿掉 `--yes`，可以先手動確認。
3. **貼上 URL 與 Authorization 標頭**到設定視窗（輸入不會顯示），然後送出測試：

   ```sh
   herdr plugin pane open --plugin grokbot-notify --entrypoint setup
   ```

完成。任何 agent 完成一輪工作、卡在問題或核准提示，或結束執行時，你都會收到通知。
不會掛勾其他事件，也不會傳送終端機輸出。

想讓機器人幫你設定？請看[透過 Grok Bot 設定](#透過-grok-bot-設定)。

## 通知範例

routine 每次通知會收到一份小型 JSON 本文：

```json
{"source":"herdr","schema":1,"plugin_version":"0.4.0","event":"pane.agent_status_changed",
 "reason":"needs_attention",
 "message":"claude needs your input in app (fix/login): Fix login bug [api / review] on laptop",
 "workspace_id":"w1","workspace_label":"api","tab_id":"w1:t1","tab_label":"review",
 "pane_id":"w1:p2","agent":"claude","agent_status":"blocked","title":"Fix login bug",
 "cwd":"/Users/me/app","repo":"app","branch":"fix/login","host":"laptop",
 "at":"2026-01-01T12:00:00Z","test":false}
```

`message` 可以直接轉發。每個欄位的說明都在[酬載](#酬載)。

## 透過 Grok Bot 設定

把下面這段貼到你與 Grok Bot 的對話中。秘密不會經過聊天、命令列或環境變數：
你會把它們貼進隱藏輸入的設定視窗。以下保留可直接使用的英文提示詞。

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

## 什麼情況會觸發 webhook

`reason` 告訴 routine 這次為什麼被喚醒：

| `reason` | 觸發時機 | 預設 |
| --- | --- | --- |
| `finished` | agent 完成一輪工作。你沒看著 pane 時 herdr 回報 `done`，有在看時則是 `idle`。herdr 的 `completion_seq` 確保每輪只送一次；啟動時已閒置的 agent 不會觸發。 | 開 |
| `needs_attention` | `blocked`：herdr 辨識到核准、提問或權限提示。 | 開 |
| `agent_exited` | agent 程式離開 pane（結束、當掉、`Ctrl-C`）。`final_status` 是它最後的狀態。 | 開 |
| `pane_exited` | 曾執行偵測到的 agent 的 pane 結束。一般 shell 不會觸發。 | 開 |
| `status_changed` | 你額外加入通知狀態的其他狀態（`working`、`unknown`）。 | 關 |
| `agent_started` | herdr 偵測到 agent 在 pane 中啟動。 | 關 |
| `event` | 你選擇開啟的其他 herdr 事件（見[選用的 herdr 事件](#選用的-herdr-事件)）。 | 關 |
| `test` | `configure.sh --test`、設定視窗的測試，或 `test` action。 | - |

重複通知以「pane + 原因」去重 60 秒，只去除連續相同的狀態轉換。
中間只要狀態變過（blocked、working、再次 blocked），兩次提示都會通知。

### 減少打擾：只在我不在時

```sh
bash "$ROOT/configure.sh" --statuses done,blocked
```

你沒看著 pane 時，herdr 會把已完成的一輪標成 `done`，看過後則是 `idle`，
所以這樣只會在你沒看時通知完成（以及所有 blocked 提示）。
其他篩選選項：`--agents claude,codex` 與 `--debounce N`。

## 酬載

以 HTTP `POST` 傳送，使用 `Content-Type: application/json` 與你的 Authorization 標頭。

| 欄位 | 型別 | 出現時機 | 意義 |
| --- | --- | --- | --- |
| `source` | string | 一律存在 | `"herdr"` |
| `schema` | number | 一律存在 | 酬載結構版本，目前是 `1`（見下方穩定性承諾） |
| `plugin_version` | string | 一律存在 | 傳送酬載的外掛版本，例如 `"0.4.0"` |
| `event` | string | 一律存在 | herdr 事件名稱（`pane.agent_status_changed`、`pane.agent_detected`、`pane.exited`、`tab.created` 等）或 `"test"` |
| `reason` | string | 一律存在 | 上表中的其中一個原因 |
| `message` | string | 一律存在 | 可直接給人閱讀的單行摘要。文字可能改變，請勿解析它 |
| `test` | boolean | 一律存在 | 只有測試 webhook 才是 `true` |
| `at` | string | 一律存在 | 傳送時間，ISO 8601 UTC |
| `workspace_id` | string | 已知時 | herdr 工作區 ID，例如 `w1` |
| `workspace_label` | string | 已知時 | herdr 側邊欄顯示的工作區名稱 |
| `tab_id` | string | 已知時 | herdr 分頁 ID，例如 `w1:t1` |
| `tab_label` | string | 已知時 | herdr 顯示的分頁名稱 |
| `pane_id` | string | agent 事件 | herdr pane ID，例如 `w1:p2`（可搭配 `herdr pane read` 使用） |
| `agent` | string | agent 事件 | herdr agent ID：`claude`、`codex`、`cursor`、`gemini` 等 |
| `agent_status` | string | agent 狀態事件 | `done`、`idle`、`blocked`、`working` 或 `unknown`；`agent_exited` 時與 `final_status` 相同 |
| `final_status` | string | `agent_exited`、`pane_exited` | agent 或 pane 消失前的最後狀態；可能不存在 |
| `title` | string | 已知時 | pane 的終端機標題（通常是 agent 的任務名稱） |
| `cwd` | string | 已知時 | pane 的工作目錄 |
| `repo` | string | 位於 git 儲存庫內時 | 儲存庫的資料夾名稱（連結的 worktree 使用主要 checkout 的名稱） |
| `branch` | string | 位於 git 儲存庫內時 | 目前分支；若處於 detached 狀態則是簡短的 commit 雜湊值 |
| `host` | string | 除非 `GROKBOT_NOTIFY_INCLUDE_HOST=0` | 簡短主機名稱 |
| `output` | string | 僅當 `GROKBOT_NOTIFY_OUTPUT_LINES` > 0 | pane 最後幾行輸出，移除跳脫碼，並在位元組上限內保留最新內容 |
| `output_truncated` | boolean | 隨 `output` 出現 | 若為符合位元組上限而裁掉較舊的行，則是 `true` |
| `data` | object | 僅限 `reason: "event"` | herdr 原始事件資料，保持不變，例如 `{"type":"tab_created","tab":{"tab_id":"w1:t2","workspace_id":"w1","label":"2",...}}`。其結構由 herdr 定義（`herdr api schema --json`、`schemas.event`），而非本外掛 |

沒有值的欄位會直接省略，不會傳送空值，因此請先檢查欄位是否存在。

**穩定性承諾。** 在 `schema: 1` 內只會新增欄位，不會改名、移除或改型別，`reason` 的意義也不變。
所有酬載變更，即使只是新增欄位，都會記在 [CHANGELOG.md](CHANGELOG.md)。破壞性變更會提高 `schema`。
routine 應忽略不認識的欄位。以下兩項不在承諾範圍內：`message` 的文字，以及隨 herdr 變動的 `data` 內容。

### 選用：pane 輸出

```sh
bash "$ROOT/configure.sh" --output-lines 40
```

將 agent 的 pane 最後 40 行（`herdr pane read --source recent-unwrapped`）加入 `output`，
移除跳脫碼與控制字元，上限為 `GROKBOT_NOTIFY_OUTPUT_MAX_BYTES`（預設 4000，保留最新的行）。預設關閉。
**終端機輸出可能含有秘密**（CLI 印出的 token、`.env` 內容、錯誤訊息裡的金鑰），
開啟後會傳送到你的 Grok Bot。輸出也可能含有誤導 routine 的文字，請當作不可信資料。

## 設定

設定視窗與 `configure.sh` 會寫入 `$(herdr plugin config-dir grokbot-notify)/.env`（權限 600）。
環境變數會覆蓋檔案中的設定。

| 設定鍵 | 預設值 | 意義 |
| --- | --- | --- |
| `GROKBOT_WEBHOOK_URL` | （必填） | routine 的 webhook URL（僅限 `https://`） |
| `GROKBOT_WEBHOOK_AUTH` | （必填） | `Bearer ...` 或完整的 `Authorization: Bearer ...` 一行 |
| `GROKBOT_NOTIFY_AGENTS` | `*` | agent ID 或部分字串（`claude,codex`）；`*` = 所有 agent |
| `GROKBOT_NOTIFY_EVENTS` | `pane.agent_status_changed,agent.released,pane.exited` | 可觸發通知的事件（用 `configure.sh --events` 修改） |
| `GROKBOT_NOTIFY_STATUSES` | `done,idle,blocked` | 會通知的狀態；`done,blocked` = 只在你不在時 |
| `GROKBOT_NOTIFY_DEBOUNCE_SECS` | `60` | 在這段時間內，去除每個 pane 與原因的連續相同重複通知（`0` = 關閉） |
| `GROKBOT_NOTIFY_OUTPUT_LINES` | `0` | 將 pane 最後 N 行作為 `output` 傳送（最多 500）。可能含有秘密 |
| `GROKBOT_NOTIFY_OUTPUT_MAX_BYTES` | `4000` | `output` 的位元組上限（最大 65536） |
| `GROKBOT_NOTIFY_TIMEOUT_SECS` | `10` | HTTP 逾時秒數 |
| `GROKBOT_NOTIFY_INCLUDE_HOST` | `1` | 包含簡短主機名稱 |

agent 篩選只適用於 agent 事件；選擇開啟的 herdr 事件不會依 agent 篩選。

### configure.sh（腳本與機器人）

`configure.sh` 與設定視窗的功能相同，但不會互動提問。它不接受以參數傳入秘密，也絕不印出秘密。

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

`--url-from-env` / `--auth-from-env` 會讀取 `GROKBOT_WEBHOOK_URL` / `GROKBOT_WEBHOOK_AUTH`，
適合環境本來就已保密的 CI 類型設定。在個人電腦上請優先使用設定視窗。

## 選用的 herdr 事件

預設只向 herdr 註冊 agent 訊號（`pane.agent_status_changed`、`pane.agent_detected`、`pane.exited`），
因此其他事件不會讓 herdr 啟動 hook 程式。以下事件預設關閉，使用 `configure.sh --events +name` 才會開啟
（`reason: "event"`，原始 herdr 資料放在 `data`）：

| 事件 | 觸發時機 |
| --- | --- |
| `pane.agent_detected` | agent 在 pane 中啟動（`reason: "agent_started"`） |
| `workspace.created` / `closed` | 建立／關閉工作區 |
| `workspace.updated` | 工作區變更（例如 cwd 或設定） |
| `workspace.renamed` / `moved` / `reordered` | 工作區重新命名／移動／清單重新排序 |
| `worktree.created` / `opened` / `removed` | git worktree 建立／以工作區開啟／移除 |
| `tab.created` / `closed` / `renamed` / `moved` | 分頁建立／關閉／重新命名／移動 |
| `pane.created` / `closed` / `moved` | pane 建立／關閉／移動 |

預設事件也能用相同方式關閉（`-pane.exited`、`-agent.released`、`-pane.agent_status_changed`）。
`agent.released` 是本外掛對帶有 `released: true` 的 `pane.agent_detected` 的稱呼。
不提供焦點事件（`*.focused`），因為每次點擊都會觸發。

註冊方式：herdr 只執行外掛 manifest 中列出的 hook，但每次事件前都會重新讀取 manifest。
`configure.sh` 會在 config 目錄寫入一個小型附屬外掛 `grokbot-notify-events`，只列出你選擇的事件，
並對它執行 `herdr plugin link`。它的 hook 透過 `herdr plugin list` 找到目前安裝的位置，
再把事件交給本外掛的 `notify.sh`，所以更新後仍能運作。本外掛自己的檔案不會被修改。
若 herdr 拒絕連結，`configure.sh` 會還原先前的 `.env` 並告知沒有儲存。
如果手動修改 `GROKBOT_NOTIFY_EVENTS`，請執行 `configure.sh --apply`。

herdr 不允許外掛掛勾終端機輸出（`pane.output_matched`）、`pane.updated`、`layout.updated`
或 `workspace.metadata_updated`，也沒有獨立的「錯誤」狀態：當掉的 agent 會呈現為 `agent_exited` 或 `pane_exited`。

## 疑難排解

**1. 送出測試。** `bash "$ROOT/configure.sh" --test` 會印出 HTTP 狀態碼，非 2xx 時以非 0 結束碼結束：

| 結果 | 意義 |
| --- | --- |
| `HTTP 2xx` | 已送達。如果 routine 沒有執行，請到 Grok Bot 檢查 routine。 |
| `HTTP 401` / `403` | Authorization 值錯誤。請在設定視窗重新貼上。 |
| `HTTP 404` | URL 錯誤，或 routine／webhook 已刪除或更換。 |
| `HTTP 000` | 無法連線：URL 拼錯、沒有網路、代理伺服器問題或逾時。 |
| `webhook URL/Authorization not configured` | 請執行設定視窗。 |

`test` action（`herdr plugin action invoke test --plugin grokbot-notify`）只會啟動 hook，
一律回報 `running`；結果要看外掛紀錄（如下）。

**2. 查看紀錄。**

- `herdr plugin log list --plugin grokbot-notify` 列出每次 hook 執行的結束碼與輸出。
  `status` action（`herdr plugin action invoke status --plugin grokbot-notify`）會把版本、路徑與設定
  寫入其中（絕不包含秘密值）。
- 外掛自己的 `notify.log` 記錄每個 `sent` / `debounced` / `skip` 決策與 HTTP 狀態碼，絕不包含 URL 或 token。
  它位於 herdr 的外掛狀態目錄，Linux 上是 `~/.local/state/herdr/plugins/grokbot-notify/notify.log`；
  上述 `status` 輸出會印出確切路徑。

**3. 常見原因。**

- **`herdr plugin action invoke ...` 或 `herdr pane ...` 回報 `server_not_running`**：
  action、pane 指令與 hook 本身都需要 herdr server 正在執行。先啟動 herdr（`herdr`）再試。
  `configure.sh --test`、`herdr plugin list` 與 `herdr plugin config-dir` 不需要 server，
  可以用來檢查設定。
- **macOS 的 notify.log 出現 `error: jq and curl are required`**：從 GUI 或 launchd 啟動的 herdr，
  `PATH` 可能沒有 Homebrew。0.4.0 起 hook 也會尋找 `/opt/homebrew/bin` 與 `/usr/local/bin`。
  用 `brew install jq` 安裝 jq（macOS 15 以上已內建 `/usr/bin/jq`）。
- **某個 agent 沒有通知**：herdr 主要從畫面偵測 agent；全新的提示樣式在 herdr 學會辨識前，
  可能顯示為 `idle` 而非 `blocked`。請在 `configure.sh --show` 檢查 `--agents` 與 `--statuses`。
- **暫停了嗎？** 執行 `disable` action 後，`configure.sh --show` / `status` action 會印出 `enabled: no`。
  用 `herdr plugin action invoke enable --plugin grokbot-notify` 恢復。
- **選用事件不再觸發**：執行 `bash "$ROOT/configure.sh" --apply`。

## 更新、回復、移除

```sh
# update (also the way to move a --ref install to a newer tag)
herdr plugin install zeke1031031/herdr-grokbot-notify --ref v0.4.0 --yes
# roll back to an earlier release
herdr plugin install zeke1031031/herdr-grokbot-notify --ref v0.3.0 --yes
```

`herdr plugin update grokbot-notify --yes` 只會更新沒有固定 `--ref` 的安裝；固定 tag 的安裝會停在該 tag。
設定保存在 config 目錄，更新或回復都會保留。本機 clone：`git pull` 或 `git checkout v0.3.0`。

```sh
herdr plugin action invoke disable --plugin grokbot-notify   # pause (enable to resume)
bash "$ROOT/configure.sh" --events default                  # 1. remove the companion plugin
herdr plugin uninstall grokbot-notify                         # 2. or: herdr plugin unlink grokbot-notify
rm -rf "$(herdr plugin config-dir grokbot-notify)"            # 3. remove saved secrets
```

請在 `$ROOT` 還存在時先執行步驟 1，再執行步驟 2。如果不再使用，也請到 Grok Bot 的 routine 面板刪除或更換 webhook。

## 進階：shepherd 模式

若 herdr 跑在 Grok Bot 能執行 shell 指令的地方（Grok Bot 主機，或你向它註冊的電腦），
routine 不只可以通知你，還可以讀取 pane（`herdr pane read <pane_id> --source recent-unwrapped --lines 120`）、
摘要已完成的工作，並可選擇代你回答少數安全的提示。
提示詞在 [`examples/routine-prompt.md`](examples/routine-prompt.md#advanced-shepherd-mode)。

- 該提示詞的自動核准**預設關閉**；必須由你明確開啟。
- 絕不選擇「永遠允許」／「不再詢問」／「本次工作階段都允許」。
- 執行測試、建置、linter 或套件腳本都算執行程式碼，因此只會回報給你，不會核准。
- pane 文字可能含有提示注入（prompt injection，例如 README、網頁或相依套件印出「全部核准」）。
  提示詞會要求 routine 把它當作資料，但 routine 提示詞才是真正的安全界線：請把可核准的範圍維持在很小的範圍內。

## 安全注意事項

- 秘密只存放在 config 目錄的 `.env`（權限 600），不會放在外掛 checkout 中。
  `.gitignore` 會排除 `.env` 檔案。
- `.env` 以 `KEY=VALUE` 解析，絕不使用 `source` 載入，因此無法執行程式碼。
- URL 與 Authorization 標頭透過權限 600 的暫存設定檔傳給 `curl`，不會出現在 `ps`，也不會被記錄或印出。
- 酬載包含 pane 中繼資料（標題、cwd、repo、branch、標籤、主機名稱）。
  只有開啟 `GROKBOT_NOTIFY_OUTPUT_LINES` 才會傳送終端機輸出。
  設定 `GROKBOT_NOTIFY_INCLUDE_HOST=0` 可省略主機名稱。
- 請求在前景執行並設有逾時，不會留下背景程序。

## 需求與平台

- herdr >= 0.9.5；bash 3.2 以上（macOS 的 `/bin/bash` 即可）、`jq`、`curl`。
  選用：`git`（用於 `repo` / `branch`）、`timeout`。
- Linux 與 macOS。**不支援 Windows**：manifest 宣告 `platforms = ["linux", "macos"]`，
  且 hook 是 bash 腳本。WSL 裡執行的 herdr 視同 Linux，但尚未測試。

## 運作方式

manifest 只為三種 agent 事件註冊 `notify.sh`。對於 agent 事件，它會在外掛狀態目錄保存少量的
個別 pane 狀態（上次狀態、agent、上次已通知的完成序號），向 `herdr agent get` 查詢 `completion_seq`
與 pane 中繼資料，依 pane 與原因去除相同的重複通知（使用可攜的 `mkdir` 鎖），加入工作區／分頁標籤
與 git 資訊，然後 POST。非 2xx 回應會清除去重標記，讓下一次變更可重試。
沒有重試佇列：webhook 無法使用時，該通知會遺失並留下紀錄。

Antigravity 與 Grok 回到提示畫面時會回報 `idle`，即使背景工作還在執行。一般終端機不會產生 agent 事件。

開發者：`bash test/run-tests.sh` 使用本機假接收器、假憑證與模擬的 `herdr` 執行離線測試
（需要 python3）。請見 [CHANGELOG.md](CHANGELOG.md)。

## 授權

MIT，見 [LICENSE](LICENSE)。本專案與 xAI、Grok Bot 或 herdr 專案無隸屬關係。
