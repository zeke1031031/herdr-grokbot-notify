#!/usr/bin/env bash
# Offline tests: runs notify.sh against a local dummy HTTP listener with fake
# credentials and a stub herdr binary. Never touches a real webhook.
# shellcheck disable=SC2015,SC2016
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
PORT="${PORT:-18765}"
FAKE_AUTH="Bearer test-not-a-real-token"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

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

# stub herdr: `pane get` returns metadata for enrichment
cat > "$T/herdr" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "pane get" ] && echo '{"result":{"pane":{"agent":"claude","terminal_title_stripped":"Stub title","cwd":"/tmp/repo","workspace_id":"w9"}}}'
SH
chmod +x "$T/herdr"

mkcfg() { printf 'GROKBOT_WEBHOOK_URL=http://127.0.0.1:%s/%s\nGROKBOT_WEBHOOK_AUTH="Authorization: %s"\nGROKBOT_NOTIFY_DEBOUNCE_SECS=60\n' "$PORT" "$1" "$FAKE_AUTH" > "$T/cfg.env"; }
run() { env -i PATH="$PATH" HOME="$T/home" HERDR_BIN_PATH="$T/herdr" HERDR_PLUGIN_STATE_DIR="$T/state" \
  GROKBOT_NOTIFY_CONFIG="$T/cfg.env" HERDR_PLUGIN_EVENT_JSON="$1" "${@:2}" bash "$ROOT/notify.sh"; }
reqs() { [ -f "$T/req.log" ] && wc -l < "$T/req.log" | tr -d ' ' || echo 0; }
ev() { printf '{"event":"pane.agent_status_changed","data":{"pane_id":"%s","agent_status":"%s","agent":"%s","workspace_id":"w1","cwd":"/r","terminal_title_stripped":"t"}}' "$1" "$2" "$3"; }

mkcfg ok
run "$(ev w1:p1 "done" claude)"
[ "$(reqs)" = 1 ] && ok "done+claude sends" || bad "done+claude sends"
last() { tail -1 "$T/req.log" | jq -r "$1"; }
[ "$(last .auth)" = "$FAKE_AUTH" ] && ok "auth header normalised" || bad "auth header normalised"
[ "$(last .ctype)" = "application/json" ] && ok "content-type json" || bad "content-type json"
[ "$(last '.body.pane_id + "|" + .body.agent_status + "|" + .body.agent')" = "w1:p1|done|claude" ] && ok "payload fields" || bad "payload fields"

run "$(ev w1:p1 "done" claude)"
[ "$(reqs)" = 1 ] && ok "debounce same pane+status" || bad "debounce same pane+status"
run "$(ev w1:p1 "blocked" claude)"
[ "$(reqs)" = 2 ] && ok "different status not debounced" || bad "different status not debounced"
run "$(ev w1:p2 "working" claude)"
[ "$(reqs)" = 2 ] && ok "status filter (working ignored)" || bad "status filter"
run "$(ev w1:p3 "done" aider)"
[ "$(reqs)" = 2 ] && ok "agent filter (aider ignored)" || bad "agent filter"
run "$(ev w1:p3 "done" aider)" GROKBOT_NOTIFY_AGENTS='*'
[ "$(reqs)" = 3 ] && ok "GROKBOT_NOTIFY_AGENTS=* via env" || bad "agents wildcard"
run "$(ev w1:p4 "idle" codex)" GROKBOT_NOTIFY_STATUSES=idle
[ "$(reqs)" = 4 ] && ok "custom statuses via env" || bad "custom statuses"

run '{"data":{"pane_id":"w2:p1","agent_status":"blocked"}}'
[ "$(reqs)" = 5 ] && [ "$(last .body.title)" = "Stub title" ] && [ "$(last .body.workspace_id)" = "w9" ] \
  && ok "enrichment via herdr pane get" || bad "enrichment"

mkcfg fail
run "$(ev w1:p5 "done" claude)"; run "$(ev w1:p5 "done" claude)"
[ "$(reqs)" = 7 ] && ok "non-2xx clears stamp (retry)" || bad "non-2xx retry"
grep -q 'http=500' "$T/state/notify.log" && ok "500 logged" || bad "500 logged"

mkcfg ok
: > "$T/state/disabled"; run "$(ev w1:p6 "done" claude)"
[ "$(reqs)" = 7 ] && ok "disabled flag pauses" || bad "disabled flag"; rm -f "$T/state/disabled"

out="$(run "" ; env -i PATH="$PATH" HOME="$T/home" HERDR_PLUGIN_STATE_DIR="$T/state" GROKBOT_NOTIFY_CONFIG="$T/cfg.env" bash "$ROOT/notify.sh" --test)"
[ "$(last .body.test)" = "true" ] && ok "--test action ($out)" || bad "--test action"

st="$(env -i PATH="$PATH" HOME="$T/home" HERDR_PLUGIN_STATE_DIR="$T/state" GROKBOT_NOTIFY_CONFIG="$T/cfg.env" bash "$ROOT/notify.sh" --status)"
if grep -q -e 'test-not-a-real-token' -e "127.0.0.1:$PORT" <<<"$st$(cat "$T/state/notify.log")"; then bad "secrets leaked to status/log"; else ok "no secrets in --status or log"; fi

printf 'GROKBOT_WEBHOOK_URL=http://127.0.0.1:%s/ok\nGROKBOT_WEBHOOK_AUTH=x\nGROKBOT_NOTIFY_AGENTS=$(touch %s/pwned)\n' "$PORT" "$T" > "$T/cfg.env"
run "$(ev w1:p7 "done" claude)"
[ ! -e "$T/pwned" ] && ok ".env is parsed, not executed" || bad ".env executed"

echo "---- $pass passed, $fail failed"
[ "$fail" = 0 ]
