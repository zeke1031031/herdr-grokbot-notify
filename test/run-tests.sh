#!/usr/bin/env bash
# Offline tests: runs notify.sh against a local dummy HTTP listener with fake
# credentials and a stub herdr binary. Never touches a real webhook.
# shellcheck disable=SC2015,SC2016,SC2034,SC2013
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
PORT="${PORT:-18765}"
FAKE_AUTH="Bearer test-not-a-real-token"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# dummy listener: /ok -> 200, /fail -> 500; logs one JSON line per request
cat > "$T/srv.py" <<'PY'
import http.server, json, sys
log = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n).decode()
        code = 200 if self.path == "/ok" else 500
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"),
                                "ctype": self.headers.get("Content-Type"), "body": json.loads(body)}) + "\n")
        self.send_response(code); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$T/srv.py" "$PORT" "$T/req.log" & SRV=$!
for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && break; sleep 0.1; done

# stub herdr: `agent get <pane>` answers from $T/agent/<pane>.json when present
# (completion_seq etc.), otherwise fails so notify.sh falls back to `pane get`.
mkdir -p "$T/agent"
cat > "$T/herdr" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = "agent get" ]; then
  f="$T/agent/\$(printf '%s' "\$3" | tr ':' '_').json"
  [ -f "\$f" ] && { echo "{\"result\":{\"agent\":\$(cat "\$f")}}"; exit 0; }
  echo '{"error":{"code":"agent_not_found"}}'; exit 1
fi
[ "\$1 \$2" = "pane get" ] && echo '{"result":{"pane":{"agent":"claude","terminal_title_stripped":"Stub title","cwd":"/tmp/repo","workspace_id":"w9","tab_id":"w9:t1"}}}'
exit 0
SH
chmod +x "$T/herdr"
agentinfo() { printf '{"agent":"%s","agent_status":"idle","completion_seq":%s,"cwd":"/a","workspace_id":"w1","tab_id":"w1:t1","terminal_title_stripped":"Agent title"}' "$2" "$3" > "$T/agent/$(tr ':' '_' <<<"$1").json"; }

mkcfg() { printf 'GROKBOT_WEBHOOK_URL=http://127.0.0.1:%s/%s\nGROKBOT_WEBHOOK_AUTH="Authorization: %s"\n%s' "$PORT" "$1" "$FAKE_AUTH" "${2:-}" > "$T/cfg.env"; }
# run <event-name> <event-json> [VAR=value ...]
run() { env -i PATH="$PATH" HOME="$T/home" HERDR_BIN_PATH="$T/herdr" HERDR_PLUGIN_STATE_DIR="$T/state" \
  GROKBOT_NOTIFY_CONFIG="$T/cfg.env" HERDR_PLUGIN_EVENT="$1" HERDR_PLUGIN_EVENT_JSON="$2" "${@:3}" bash "$ROOT/notify.sh"; }
reqs() { [ -f "$T/req.log" ] && wc -l < "$T/req.log" | tr -d ' ' || echo 0; }
last() { tail -1 "$T/req.log" | jq -r "$1"; }
st() { printf '{"event":"pane.agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"%s","workspace_id":"w1","agent_status":"%s","agent":"%s","title":"t"}}' "$1" "$2" "$3"; }
S=pane.agent_status_changed

mkcfg ok
# --- finished / blocked for any agent -------------------------------------
run $S "$(st w1:p1 working claude)"
check "working is not sent" '[ "$(reqs)" = 0 ]'
run $S "$(st w1:p1 "done" claude)"
check "working->done sends" '[ "$(reqs)" = 1 ]'
check "auth header normalised" '[ "$(last .auth)" = "$FAKE_AUTH" ]'
check "content-type json" '[ "$(last .ctype)" = "application/json" ]'
check "payload fields" '[ "$(last ".body.event+\"|\"+.body.reason+\"|\"+.body.pane_id+\"|\"+.body.agent_status+\"|\"+.body.agent")" = "pane.agent_status_changed|finished|w1:p1|done|claude" ]'
check "payload has version, no data for agent events" '[ "$(last ".body.plugin_version + (.body|has(\"data\")|tostring)")" = "0.3.0false" ]'
run $S "$(st w1:p1 "done" claude)"
check "debounce same pane+reason" '[ "$(reqs)" = 1 ]'
run $S "$(st w1:p1 blocked claude)"
check "blocked sends (needs_attention)" '[ "$(reqs)" = 2 ] && [ "$(last .body.reason)" = needs_attention ]'

for a in gemini cursor opencode grok amp kiro copilot hermes; do run $S "$(st "w1:$a" "done" "$a")"; done
check "default agents = all (8 other agents sent)" '[ "$(reqs)" = 10 ]'

run $S "$(st w1:q1 working codex)"; run $S "$(st w1:q1 idle codex)"
check "working->idle (seen while focused) sends as finished" '[ "$(reqs)" = 11 ] && [ "$(last .body.reason)" = finished ]'
run $S "$(st w1:q2 idle codex)"
check "idle without prior work (startup) is quiet" '[ "$(reqs)" = 11 ]'

# completion_seq from `herdr agent get` dedupes done->idle and catches every turn
mkcfg ok 'GROKBOT_NOTIFY_DEBOUNCE_SECS=0
'
agentinfo w1:c1 pi 7
run $S "$(st w1:c1 "done" pi)"
check "completion_seq 7 sent" '[ "$(reqs)" = 12 ] && [ "$(last .body.cwd)" = /a ] && [ "$(last .body.tab_id)" = w1:t1 ]'
run $S "$(st w1:c1 idle pi)"
check "done->idle same completion_seq not resent" '[ "$(reqs)" = 12 ]'
agentinfo w1:c1 pi 9
run $S "$(st w1:c1 idle pi)"
check "next completion_seq sent even if back-to-back" '[ "$(reqs)" = 13 ]'
agentinfo w1:c2 pi null
run $S "$(st w1:c2 idle pi)"
check "idle with completion_seq=null and no work is quiet" '[ "$(reqs)" = 13 ]'
mkcfg ok

# --- filters ----------------------------------------------------------------
run $S "$(st w1:f1 "done" aider)" GROKBOT_NOTIFY_AGENTS=claude,codex
check "agent allowlist filters" '[ "$(reqs)" = 13 ]'
run $S "$(st w1:f1 "done" codex)" GROKBOT_NOTIFY_AGENTS=claude,codex
check "agent allowlist allows" '[ "$(reqs)" = 14 ]'
( cd "$T" && touch "glob-trap" && run $S "$(st w1:f2 "done" claude)" GROKBOT_NOTIFY_AGENTS='*' )
check "* is not glob-expanded" '[ "$(reqs)" = 15 ]'
run $S "$(st w1:f3 working claude)" GROKBOT_NOTIFY_STATUSES=working
check "opt-in working status" '[ "$(reqs)" = 16 ] && [ "$(last .body.reason)" = status_changed ]'
run $S "$(st w1:f4 blocked claude)" GROKBOT_NOTIFY_EVENTS=tab.created
check "agent status events can be turned off" '[ "$(reqs)" = 16 ]'

run $S '{"data":{"pane_id":"w2:p1","agent_status":"blocked"}}'
check "enrichment via herdr pane get" '[ "$(reqs)" = 17 ] && [ "$(last .body.title)" = "Stub title" ] && [ "$(last .body.workspace_id)" = w9 ] && [ "$(last .body.tab_id)" = w9:t1 ]'

# --- exits ------------------------------------------------------------------
run pane.agent_detected '{"event":"pane.agent_detected","data":{"pane_id":"w1:x1","workspace_id":"w1","agent":"droid"}}'
check "agent start quiet by default" '[ "$(reqs)" = 17 ]'
run pane.agent_detected '{"event":"pane.agent_detected","data":{"pane_id":"w1:x1","workspace_id":"w1","released":true,"final_status":"working"}}'
check "agent released -> agent_exited with final_status + remembered agent" \
  '[ "$(reqs)" = 18 ] && [ "$(last ".body.reason+\"|\"+.body.final_status+\"|\"+.body.agent")" = "agent_exited|working|droid" ]'
run pane.exited '{"event":"pane.exited","data":{"pane_id":"w1:x1","workspace_id":"w1"}}'
check "pane.exited after release is not duplicated" '[ "$(reqs)" = 18 ]'
run $S "$(st w1:x2 working kimi)"
run pane.exited '{"event":"pane.exited","data":{"pane_id":"w1:x2","workspace_id":"w1"}}'
check "pane.exited of an agent pane -> pane_exited" '[ "$(reqs)" = 19 ] && [ "$(last ".body.reason+\"|\"+.body.agent+\"|\"+.body.final_status")" = "pane_exited|kimi|working" ]'
run pane.exited '{"event":"pane.exited","data":{"pane_id":"w1:sh","workspace_id":"w1"}}'
check "pane.exited of a plain shell is quiet" '[ "$(reqs)" = 19 ]'
run pane.agent_detected '{"event":"pane.agent_detected","data":{"pane_id":"w1:x3","workspace_id":"w1","agent":"qwen"}}' GROKBOT_NOTIFY_EVENTS=pane.agent_detected
check "opt-in agent_started" '[ "$(reqs)" = 20 ] && [ "$(last .body.reason)" = agent_started ]'

# --- generic opt-in events ----------------------------------------------------
run tab.created '{"event":"tab.created","data":{"type":"tab_created","tab":{"tab_id":"w1:t2","workspace_id":"w1","label":"x"}}}'
check "other events off by default" '[ "$(reqs)" = 20 ]'
run tab.created '{"event":"tab.created","data":{"type":"tab_created","tab":{"tab_id":"w1:t2","workspace_id":"w1","label":"x"}}}' GROKBOT_NOTIFY_EVENTS=tab.created,worktree.created
check "opt-in tab.created with raw data" '[ "$(reqs)" = 21 ] && [ "$(last ".body.event+\"|\"+.body.reason+\"|\"+.body.data.tab.tab_id")" = "tab.created|event|w1:t2" ]'
run worktree.removed '{"event":"worktree.removed","data":{"workspace_id":"w1","forced":false,"worktree":{"path":"/r/wt"}}}' GROKBOT_NOTIFY_EVENTS='*'
check "EVENTS=* forwards anything" '[ "$(reqs)" = 22 ] && [ "$(last .body.workspace_id)" = w1 ]'
run workspace.moved '{"event":"workspace.moved","data":{"workspace_id":"w1"}}' GROKBOT_NOTIFY_EVENTS=tab.created
check "unlisted event ignored" '[ "$(reqs)" = 22 ]'

# --- failure / control paths ---------------------------------------------------
mkcfg fail
run $S "$(st w1:p5 "done" claude)"; run $S "$(st w1:p5 "done" claude)"
check "non-2xx clears stamp (retry)" '[ "$(reqs)" = 24 ]'
check "500 logged" 'grep -q "http=500" "$T/state/notify.log"'

mkcfg ok
: > "$T/state/disabled"; run $S "$(st w1:p6 "done" claude)"
check "disabled flag pauses" '[ "$(reqs)" = 24 ]'; rm -f "$T/state/disabled"

out="$(env -i PATH="$PATH" HOME="$T/home" HERDR_PLUGIN_STATE_DIR="$T/state" GROKBOT_NOTIFY_CONFIG="$T/cfg.env" bash "$ROOT/notify.sh" --test)"
check "--test action ($out)" '[ "$(last .body.test)" = true ] && [ "$(last .body.reason)" = test ]'

stat_out="$(env -i PATH="$PATH" HOME="$T/home" HERDR_PLUGIN_STATE_DIR="$T/state" GROKBOT_NOTIFY_CONFIG="$T/cfg.env" bash "$ROOT/notify.sh" --status)"
check "no secrets in --status or log" '! grep -q -e test-not-a-real-token -e "127.0.0.1:$PORT" <<<"$stat_out$(cat "$T/state/notify.log")"'
check "--status lists events" 'grep -q "events *: pane.agent_status_changed,agent.released,pane.exited" <<<"$stat_out"'

printf 'GROKBOT_WEBHOOK_URL=http://127.0.0.1:%s/ok\nGROKBOT_WEBHOOK_AUTH=x\nGROKBOT_NOTIFY_AGENTS=$(touch %s/pwned)\n' "$PORT" "$T" > "$T/cfg.env"
run $S "$(st w1:p7 "done" claude)"
check ".env is parsed, not executed" '[ ! -e "$T/pwned" ]'

# every declared hook is a known herdr 0.9.5 plugin event; only the core three by default
known=" pane.agent_status_changed pane.agent_detected pane.exited workspace.created workspace.updated workspace.closed workspace.renamed workspace.moved workspace.reordered worktree.created worktree.opened worktree.removed tab.created tab.closed tab.renamed tab.moved pane.created pane.closed pane.moved "
evs="$(sed -n 's/^on = "\(.*\)"/\1/p' "$ROOT/herdr-plugin.toml" | paste -sd, -)"
check "manifest registers only core agent events ($evs)" '[ "$evs" = "pane.agent_status_changed,pane.agent_detected,pane.exited" ]'

# --- configure.sh (stub herdr records link/unlink; fake secrets only) ------
MANI_SUM="$(cksum < "$ROOT/herdr-plugin.toml")"
CD="$T/cfgdir"; H2="$T/herdr2"; HL="$T/herdr2.log"
cat > "$H2" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$HL"
case "\$1 \$2" in
  "plugin config-dir") echo "$CD" ;;
  "plugin link") echo linked > "$T/comp.linked" ;;
  "plugin unlink") rm -f "$T/comp.linked" ;;
  "plugin list")
    if [ "\$4" = grokbot-notify-events ]; then
      [ -f "$T/comp.linked" ] && echo '{"result":{"plugins":[{"plugin_id":"grokbot-notify-events","enabled":true}]}}' || echo '{"result":{"plugins":[]}}'
    else
      en=true; [ -f "$T/main.disabled" ] && en=false
      echo "{\"result\":{\"plugins\":[{\"plugin_id\":\"grokbot-notify\",\"enabled\":\$en,\"plugin_root\":\"$ROOT\"}]}}"
    fi ;;
esac
exit 0
SH
chmod +x "$H2"
conf() { env -i PATH="$PATH" HOME="$T/home" HERDR_BIN_PATH="$H2" "$@"; }
FAKE_URL="https://example.invalid/hooks/fake-not-real"

out="$(conf GROKBOT_WEBHOOK_URL="$FAKE_URL" GROKBOT_WEBHOOK_AUTH="$FAKE_AUTH" bash "$ROOT/configure.sh" --url-from-env --auth-from-env 2>&1)"
check "configure: writes .env with mode 600 via herdr config-dir" '[ -f "$CD/.env" ] && [ "$(stat -c %a "$CD/.env" 2>/dev/null || stat -f %Lp "$CD/.env")" = 600 ]'
check "configure: default = core events, no companion" 'grep -q "^GROKBOT_NOTIFY_EVENTS=pane.agent_status_changed,agent.released,pane.exited$" "$CD/.env" && [ ! -d "$CD/events-plugin" ] && ! grep -q "plugin link" "$HL"'
check "configure: never echoes secrets" '! grep -q -e test-not-a-real-token -e fake-not-real <<<"$out"'

out="$(conf bash "$ROOT/configure.sh" --events +tab.created,+worktree.created,-pane.exited,+pane.agent_detected 2>&1)"
check "configure: +/- edits keep secrets" 'grep -q "^GROKBOT_WEBHOOK_URL=$FAKE_URL$" "$CD/.env" && grep -q "^GROKBOT_NOTIFY_EVENTS=pane.agent_status_changed,agent.released,pane.agent_detected,worktree.created,tab.created$" "$CD/.env"'
check "configure: companion lists only lifecycle extras and is linked" '[ "$(sed -n "s/^on = \"\(.*\)\"/\1/p" "$CD/events-plugin/herdr-plugin.toml" | paste -sd, -)" = worktree.created,tab.created ] && grep -q "plugin link $CD/events-plugin" "$HL" && [ -f "$T/comp.linked" ]'
check "configure: plugin checkout left untouched" '[ "$(cksum < "$ROOT/herdr-plugin.toml")" = "$MANI_SUM" ] && [ ! -e "$ROOT/events-plugin" ]'

# companion hook forwards to main notify.sh using the main config dir
: > "$T/req.log"
printf 'GROKBOT_WEBHOOK_URL=http://127.0.0.1:%s/ok\nGROKBOT_WEBHOOK_AUTH=%s\nGROKBOT_NOTIFY_EVENTS=tab.created\n' "$PORT" "$FAKE_AUTH" > "$CD/.env"
comp() { env -i PATH="$PATH" HOME="$T/home" HERDR_BIN_PATH="$H2" HERDR_PLUGIN_STATE_DIR="$T/cstate" HERDR_PLUGIN_CONFIG_DIR="$T/wrong" \
  HERDR_PLUGIN_EVENT=tab.created HERDR_PLUGIN_EVENT_JSON='{"event":"tab.created","data":{"tab":{"tab_id":"w1:t5","workspace_id":"w1"}}}' bash "$CD/events-plugin/hook.sh"; }
comp
check "companion: forwards opted-in event" '[ "$(reqs)" = 1 ] && [ "$(last .body.event)" = tab.created ] && [ "$(last .body.reason)" = event ]'
: > "$T/main.disabled"; comp; rm -f "$T/main.disabled"
check "companion: silent when main plugin is disabled in herdr" '[ "$(reqs)" = 1 ]'
env -i PATH="$PATH" HOME="$T/home" HERDR_PLUGIN_STATE_DIR="$T/mstate" HERDR_PLUGIN_CONFIG_DIR="$CD" bash "$ROOT/notify.sh" --disable >/dev/null
comp
check "companion: honours the shared pause flag" '[ "$(reqs)" = 1 ] && [ -e "$CD/paused" ]'
env -i PATH="$PATH" HOME="$T/home" HERDR_PLUGIN_STATE_DIR="$T/mstate" HERDR_PLUGIN_CONFIG_DIR="$CD" bash "$ROOT/notify.sh" --enable >/dev/null
comp
check "companion: resumes after --enable" '[ "$(reqs)" = 2 ]'

env -i PATH="$PATH" HOME="$T/home" HERDR_BIN_PATH="$H2" HERDR_PLUGIN_STATE_DIR="$T/cstate" HERDR_PLUGIN_EVENT=workspace.created \
  HERDR_PLUGIN_EVENT_JSON='{"event":"workspace.created","data":{"type":"workspace_created","workspace":{"workspace_id":"wZ","label":"x"}}}' \
  GROKBOT_NOTIFY_EVENTS=workspace.created bash "$CD/events-plugin/hook.sh"
check "companion: workspace_id read from nested workspace object" '[ "$(reqs)" = 3 ] && [ "$(last .body.workspace_id)" = wZ ]'
out="$(conf bash "$ROOT/configure.sh" --events none 2>&1)"
check "configure: none removes companion and unlinks" '[ ! -d "$CD/events-plugin" ] && [ ! -f "$T/comp.linked" ] && grep -q "plugin unlink grokbot-notify-events" "$HL"'
conf bash "$ROOT/configure.sh" --events tab.closed,pane.moved >/dev/null
check "configure: bare names replace optional set, core kept" 'grep -q "^GROKBOT_NOTIFY_EVENTS=tab.closed,pane.moved$" "$CD/.env"'
conf bash "$ROOT/configure.sh" --events default >/dev/null
check "configure: default restores core only" 'grep -q "^GROKBOT_NOTIFY_EVENTS=pane.agent_status_changed,agent.released,pane.exited$" "$CD/.env" && [ ! -d "$CD/events-plugin" ]'

js="$(conf bash "$ROOT/configure.sh" --list --json)"
check "configure: --list --json has 20 entries, 3 on by default" '[ "$(jq length <<<"$js")" = 20 ] && [ "$(jq "[.[]|select(.enabled)]|length" <<<"$js")" = 3 ] && [ "$(jq -r "[.[]|select(.default)|.name]|join(\",\")" <<<"$js")" = pane.agent_status_changed,agent.released,pane.exited ]'
before="$(cat "$CD/.env")"
conf bash "$ROOT/configure.sh" --events +tab.focused >/dev/null 2>&1; r1=$?
conf bash "$ROOT/configure.sh" --events +nope.event >/dev/null 2>&1; r2=$?
conf GROKBOT_WEBHOOK_URL="http://example.invalid/x" bash "$ROOT/configure.sh" --url-from-env >/dev/null 2>&1; r3=$?
conf GROKBOT_WEBHOOK_URL='https://x.invalid/"q' bash "$ROOT/configure.sh" --url-from-env >/dev/null 2>&1; r4=$?
conf bash "$ROOT/configure.sh" --url "$FAKE_URL" >/dev/null 2>&1; r5=$?
check "configure: rejects focus/unknown events, http, quotes, secret args; nothing written" '[ $r1 != 0 ] && [ $r2 != 0 ] && [ $r3 != 0 ] && [ $r4 != 0 ] && [ $r5 != 0 ] && [ "$(cat "$CD/.env")" = "$before" ]'
printf '%s\n%s\n' "$FAKE_URL" "Bearer from-stdin-fake" | conf bash "$ROOT/configure.sh" --secrets-from-stdin --agents claude,codex --debounce 30 >/dev/null
check "configure: --secrets-from-stdin + settings" 'grep -q "^GROKBOT_WEBHOOK_AUTH=Bearer from-stdin-fake$" "$CD/.env" && grep -q "^GROKBOT_NOTIFY_AGENTS=claude,codex$" "$CD/.env" && grep -q "^GROKBOT_NOTIFY_DEBOUNCE_SECS=30$" "$CD/.env"'
show="$(conf bash "$ROOT/configure.sh" --show)"
check "configure: --show reports set/missing only" 'grep -q "webhook url *: set" <<<"$show" && ! grep -q -e from-stdin-fake -e fake-not-real <<<"$show"'

echo "---- $pass passed, $fail failed"
[ "$fail" = 0 ]
