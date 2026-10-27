#!/usr/bin/env bash
# Grok Bot Notify - herdr plugin hook.
# POSTs a small JSON payload to a Grok Bot routine webhook when any
# herdr-detected coding agent finishes, needs input, or exits, and (opt-in,
# see configure.sh) for other hookable herdr events. It never prints or logs the webhook URL
# or Authorization value, and never sends terminal output.
#
# Usage (normally invoked by herdr):
#   notify.sh            handle HERDR_PLUGIN_EVENT / HERDR_PLUGIN_EVENT_JSON
#   notify.sh --test     send a synthetic test payload now
#   notify.sh --enable   resume sending
#   notify.sh --disable  pause sending (event hooks stay registered)
#   notify.sh --status   print config summary (no secret values)
#
# Portable to bash 3.2 (macOS /bin/bash): no ${x,,}, no `local -`, no mapfile.
set -u
set -f   # never glob-expand list items such as "*"

VERSION="0.3.0"
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr-grokbot-notify}"
CONFIG_FILE="${GROKBOT_NOTIFY_CONFIG:-$CONFIG_DIR/.env}"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-$HOME/.local/state/herdr-grokbot-notify}"
HERDR="${HERDR_BIN_PATH:-herdr}"

mkdir -p "$STATE_DIR/panes" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null
LOG="$STATE_DIR/notify.log"
DISABLED_FLAG="$STATE_DIR/disabled"
# shared with the optional-events companion plugin, which has its own state dir
PAUSED_FLAG="$CONFIG_DIR/paused"
PANES="$STATE_DIR/panes"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(now_iso)" "$*" >> "$LOG" 2>/dev/null || true; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

# --- config: KEY=VALUE lines, parsed (never sourced/executed). Env vars win. ---
ALLOWED_KEYS=" GROKBOT_WEBHOOK_URL GROKBOT_WEBHOOK_AUTH GROKBOT_NOTIFY_EVENTS GROKBOT_NOTIFY_STATUSES GROKBOT_NOTIFY_AGENTS GROKBOT_NOTIFY_DEBOUNCE_SECS GROKBOT_NOTIFY_TIMEOUT_SECS GROKBOT_NOTIFY_INCLUDE_HOST "
load_config() {
  [ -r "$CONFIG_FILE" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    key="${line%%=*}"; val="${line#*=}"
    [ "$key" != "$line" ] || continue
    case "$ALLOWED_KEYS" in *" $key "*) ;; *) continue ;; esac
    # strip one layer of matching quotes
    if [ "${#val}" -ge 2 ]; then
      case "$val" in \"*\") val="${val:1:${#val}-2}" ;; \'*\') val="${val:1:${#val}-2}" ;; esac
    fi
    [ -n "${!key+x}" ] || printf -v "$key" '%s' "$val"
  done < "$CONFIG_FILE"
}
load_config

# Defaults: every detected agent; finished (done / idle after work), blocked,
# and agent/pane exits. Other herdr events are opt-in via GROKBOT_NOTIFY_EVENTS.
DEFAULT_EVENTS="pane.agent_status_changed,agent.released,pane.exited"
EVENTS="$(lower "${GROKBOT_NOTIFY_EVENTS:-$DEFAULT_EVENTS}")"
STATUSES="$(lower "${GROKBOT_NOTIFY_STATUSES:-done,idle,blocked}")"
AGENTS="$(lower "${GROKBOT_NOTIFY_AGENTS:-*}")"
DEBOUNCE_SECS="${GROKBOT_NOTIFY_DEBOUNCE_SECS:-60}"
TIMEOUT_SECS="${GROKBOT_NOTIFY_TIMEOUT_SECS:-10}"
INCLUDE_HOST="${GROKBOT_NOTIFY_INCLUDE_HOST:-1}"
case "$DEBOUNCE_SECS" in ''|*[!0-9]*) DEBOUNCE_SECS=60 ;; esac
case "$TIMEOUT_SECS" in ''|*[!0-9]*) TIMEOUT_SECS=10 ;; esac

in_list() { # in_list <needle> <comma-list> [substring]
  local needle="$1" list="$2" mode="${3:-exact}" item IFS=','
  for item in $list; do
    item="${item//[[:space:]]/}"
    [ -n "$item" ] || continue
    [ "$item" = "*" ] && return 0
    if [ "$mode" = substring ]; then
      [ -n "$needle" ] || continue
      case "$needle" in *"$item"*) return 0 ;; esac
    else
      [ "$needle" = "$item" ] && return 0
    fi
  done
  return 1
}
event_on() { in_list "$1" "$EVENTS"; }

have_secrets() { [ -n "${GROKBOT_WEBHOOK_URL:-}" ] && [ -n "${GROKBOT_WEBHOOK_AUTH:-}" ]; }

# send <json-body>  -> echoes HTTP code. Secrets go through a 0600 curl config
# file so they never appear in the process list or logs.
send() {
  local body="$1" cfg code auth
  case "$GROKBOT_WEBHOOK_URL$GROKBOT_WEBHOOK_AUTH" in *$'\n'*) echo "000"; return ;; esac
  auth="$GROKBOT_WEBHOOK_AUTH"
  auth="${auth#[Aa]uthorization:}"
  auth="${auth#"${auth%%[![:space:]]*}"}"
  esc() { local v="${1//\\/\\\\}"; printf '%s' "${v//\"/\\\"}"; }
  cfg="$(umask 077; mktemp "${TMPDIR:-/tmp}/grokbot-notify.XXXXXX")" || { echo "000"; return; }
  {
    printf 'url = "%s"\n' "$(esc "$GROKBOT_WEBHOOK_URL")"
    printf 'header = "Authorization: %s"\n' "$(esc "$auth")"
  } > "$cfg"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT_SECS" -X POST \
    -K "$cfg" -H 'Content-Type: application/json' --data-binary "$body" 2>/dev/null)" || true
  rm -f "$cfg"
  printf '%s' "${code:-000}"
}

host_name() {
  if [ "$INCLUDE_HOST" = 1 ]; then hostname -s 2>/dev/null || hostname 2>/dev/null || true; fi
}

# Payload fields (empty ones are dropped). data = raw herdr event data for
# generic events only.
EVENT="" REASON="" WS="" TAB="" PANE="" AGENT="" STATUS="" FINAL="" TITLE="" CWD="" DATA="null"
build_body() { # build_body <test:true|false>
  jq -nc --arg v "$VERSION" --arg e "$EVENT" --arg r "$REASON" --arg ws "$WS" --arg tab "$TAB" \
    --arg p "$PANE" --arg a "$AGENT" --arg s "$STATUS" --arg f "$FINAL" --arg t "$TITLE" \
    --arg c "$CWD" --arg h "$(host_name)" --arg at "$(now_iso)" --argjson test "$1" \
    --argjson data "$DATA" \
    '{source:"herdr",plugin_version:$v,event:$e,reason:$r,workspace_id:$ws,tab_id:$tab,
      pane_id:$p,agent:$a,agent_status:$s,final_status:$f,title:$t,cwd:$c,host:$h,at:$at}
     | with_entries(select(.value != ""))
     | . + {test:$test} + (if $data == null then {} else {data:$data} end)'
}

# --- subcommands ---
case "${1:-}" in
  --enable)  rm -f "$DISABLED_FLAG" "$PAUSED_FLAG"; log "enabled"; echo "grokbot-notify: enabled"; exit 0 ;;
  --disable) : > "$DISABLED_FLAG"; { [ -d "$CONFIG_DIR" ] && : > "$PAUSED_FLAG"; } 2>/dev/null; log "disabled"; echo "grokbot-notify: disabled"; exit 0 ;;
  --status)
    echo "version     : $VERSION"
    echo "config file : $CONFIG_FILE ($( [ -r "$CONFIG_FILE" ] && echo present || echo missing ))"
    echo "state dir   : $STATE_DIR"
    echo "enabled     : $( [ -e "$DISABLED_FLAG" ] || [ -e "$PAUSED_FLAG" ] && echo no || echo yes )"
    echo "webhook url : $( [ -n "${GROKBOT_WEBHOOK_URL:-}" ] && echo set || echo MISSING )"
    echo "auth header : $( [ -n "${GROKBOT_WEBHOOK_AUTH:-}" ] && echo set || echo MISSING )"
    echo "events      : $EVENTS"
    echo "statuses    : $STATUSES"
    echo "agents      : $AGENTS"
    echo "debounce    : ${DEBOUNCE_SECS}s"
    exit 0 ;;
  --test)
    if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then echo "grokbot-notify: needs jq and curl" >&2; exit 1; fi
    have_secrets || { echo "grokbot-notify: webhook URL/Authorization not configured ($CONFIG_FILE)" >&2; exit 1; }
    EVENT="test" REASON="test" WS="test" PANE="test" AGENT="test" STATUS="done" TITLE="grokbot-notify test" CWD="$PWD"
    code="$(send "$(build_body true)")"
    log "test: http=$code"
    echo "grokbot-notify: test webhook -> HTTP $code"
    case "$code" in 2*) exit 0 ;; *) exit 1 ;; esac ;;
  "") ;;
  *) echo "usage: notify.sh [--test|--enable|--disable|--status]" >&2; exit 2 ;;
esac

# --- event hook ---
[ -e "$DISABLED_FLAG" ] || [ -e "$PAUSED_FLAG" ] && exit 0
ev="${HERDR_PLUGIN_EVENT_JSON:-}"
EVENT="${HERDR_PLUGIN_EVENT:-}"

# Fast path: bail out before spawning jq for events nobody asked for.
# The main manifest registers only the agent events; anything else arrives via
# the optional-events companion plugin generated by configure.sh.
case "$EVENT" in
  ''|pane.agent_status_changed|pane.agent_detected|pane.exited|pane.created|pane.closed) ;;
  *) event_on "$EVENT" || exit 0 ;;
esac

if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then log "error: jq and curl are required"; exit 0; fi
[ -n "$ev" ] || { log "skip: no event json"; exit 0; }
[ -n "$EVENT" ] || EVENT="$(jq -r '.event // empty' <<<"$ev" 2>/dev/null)"
[ -n "$EVENT" ] || EVENT="pane.agent_status_changed"   # legacy payloads without a name

get() { jq -r "(.data.$1 // .$1 // .data.pane.$1 // .pane.$1 // .data.workspace.$1 // .data.tab.$1 // empty) | tostring" <<<"$ev" 2>/dev/null; }
with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout 5 "$@"; else "$@"; fi; }

# --- state helpers (portable mkdir lock; no flock on macOS) ---
lockdir="$STATE_DIR/.lock"
lock() {
  local i=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 20 ]; then rm -rf "$lockdir"; mkdir "$lockdir" 2>/dev/null; break; fi  # stale lock
    sleep 0.25
  done
  trap 'rmdir "$lockdir" 2>/dev/null' EXIT
}
unlock() { rmdir "$lockdir" 2>/dev/null; trap - EXIT; }
rd() { [ -f "$1" ] && cat "$1" 2>/dev/null; }
forget_pane() { rm -f "$PANES/$1".agent "$PANES/$1".status "$PANES/$1".cseq; }

# Fill workspace/tab/title/cwd/agent (and completion seq) from herdr itself.
CSEQ=""
enrich() {
  local j
  j="$(with_timeout "$HERDR" agent get "$PANE" 2>/dev/null || true)"
  if [ -n "$j" ] && jq -e '.result' >/dev/null 2>&1 <<<"$j"; then
    j="$(jq -c '.result.agent // .result' <<<"$j")"
  else
    j="$(with_timeout "$HERDR" pane get "$PANE" 2>/dev/null || true)"
    [ -n "$j" ] && j="$(jq -c '.result.pane // empty' <<<"$j" 2>/dev/null)"
  fi
  [ -n "$j" ] || { [ -n "$WS" ] || WS="${PANE%%:*}"; return 0; }
  pf() { jq -r "(.$1 // empty) | tostring" <<<"$j" 2>/dev/null; }
  [ -n "$AGENT" ] || AGENT="$(pf agent)"
  [ -n "$TITLE" ] || TITLE="$(pf terminal_title_stripped)"
  [ -n "$TITLE" ] || TITLE="$(pf terminal_title)"
  [ -n "$CWD" ] || CWD="$(pf foreground_cwd)"
  [ -n "$CWD" ] || CWD="$(pf cwd)"
  [ -n "$WS" ] || WS="$(pf workspace_id)"
  [ -n "$TAB" ] || TAB="$(pf tab_id)"
  CSEQ="$(pf completion_seq)"
  [ -n "$WS" ] || WS="${PANE%%:*}"
}

# deliver <debounce-key or ""> [cseq-file cseq]
deliver() {
  local key="$1" stamp="" now last code
  have_secrets || { log "error: webhook URL/Authorization not configured"; exit 0; }
  if [ -n "$key" ] && [ "$DEBOUNCE_SECS" -gt 0 ]; then
    stamp="$STATE_DIR/last_$(safe "$key")"
    lock; now="$(date +%s)"
    last="$(rd "$stamp")"; case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt "$DEBOUNCE_SECS" ]; then unlock; log "debounced: $key"; exit 0; fi
    echo "$now" > "$stamp"; unlock
  fi
  code="$(send "$(build_body false)")"
  log "sent: event=$EVENT reason=$REASON pane=${PANE:-none} agent=${AGENT:-none} status=${STATUS:-none} http=$code"
  case "$code" in
    2*) [ -z "${2:-}" ] || echo "$3" > "$2" ;;
    *) [ -z "$stamp" ] || rm -f "$stamp" ;;   # allow retry on next change
  esac
  exit 0
}

agent_allowed() {
  AGENT="$(lower "$AGENT")"
  in_list "$AGENT" "$AGENTS" substring && return 0
  log "skip: event=$EVENT pane=$PANE agent=${AGENT:-none} (agent filter)"; return 1
}

PANE="$(get pane_id)"
WS="$(get workspace_id)"
TAB="$(get tab_id)"
P="$(safe "$PANE")"

case "$EVENT" in
  pane.agent_status_changed)
    [ -n "$PANE" ] || PANE="${HERDR_PANE_ID:-}"
    [ -n "$PANE" ] || { log "skip: no pane_id"; exit 0; }
    P="$(safe "$PANE")"
    STATUS="$(lower "$(get agent_status)")"
    AGENT="$(get agent)"; [ -n "$AGENT" ] || AGENT="$(get display_agent)"
    TITLE="$(get terminal_title_stripped)"; [ -n "$TITLE" ] || TITLE="$(get title)"
    CWD="$(get cwd)"
    lock
    prev="$(rd "$PANES/$P.status")"
    echo "$STATUS" > "$PANES/$P.status"
    [ -z "$AGENT" ] || echo "$AGENT" > "$PANES/$P.agent"
    unlock
    event_on "$EVENT" || exit 0
    in_list "$STATUS" "$STATUSES" || exit 0
    enrich
    [ -n "$AGENT" ] || AGENT="$(rd "$PANES/$P.agent")"
    agent_allowed || exit 0
    case "$STATUS" in
      blocked) REASON="needs_attention"; deliver "${PANE}_needs_attention" ;;
      done|idle)
        REASON="finished"
        if [ -n "$CSEQ" ] && [ "$CSEQ" != null ]; then
          # herdr marks this idle transition as completed work.
          if [ "$CSEQ" = "$(rd "$PANES/$P.cseq")" ]; then log "skip: pane=$PANE completion $CSEQ already sent"; exit 0; fi
          deliver "" "$PANES/$P.cseq" "$CSEQ"
        fi
        # No completion_seq (older server, or the agent moved on already).
        if [ "$STATUS" = "done" ]; then deliver "${PANE}_finished"; fi
        case "$prev" in
          working|blocked) deliver "${PANE}_finished" ;;
          *) log "skip: pane=$PANE idle without completed work (prev=${prev:-none})"; exit 0 ;;
        esac ;;
      *) REASON="status_changed"; deliver "${PANE}_$STATUS" ;;
    esac ;;

  pane.agent_detected)
    [ -n "$PANE" ] || exit 0
    AGENT="$(get agent)"
    released="$(jq -r '.data.released // false' <<<"$ev" 2>/dev/null)"
    if [ "$released" = true ]; then
      FINAL="$(lower "$(get final_status)")"
      [ -n "$AGENT" ] || AGENT="$(rd "$PANES/$P.agent")"
      lock; forget_pane "$P"; unlock
      event_on agent.released || event_on "$EVENT" || exit 0
      REASON="agent_exited"; STATUS="$FINAL"
      enrich; agent_allowed || exit 0
      deliver "${PANE}_agent_exited"
    else
      lock; [ -z "$AGENT" ] || echo "$AGENT" > "$PANES/$P.agent"; rm -f "$PANES/$P.cseq"; unlock
      event_on "$EVENT" || exit 0
      REASON="agent_started"
      enrich; agent_allowed || exit 0
      deliver "${PANE}_agent_started"
    fi ;;

  pane.exited)
    [ -n "$PANE" ] || exit 0
    AGENT="$(rd "$PANES/$P.agent")"; STATUS="$(rd "$PANES/$P.status")"
    lock; forget_pane "$P"; unlock
    event_on "$EVENT" || exit 0
    # Only panes that were running a detected agent (plain shells stay quiet).
    [ -n "$AGENT" ] || { log "skip: pane.exited pane=$PANE (no agent tracked)"; exit 0; }
    REASON="pane_exited"; FINAL="$STATUS"; STATUS=""
    agent_allowed || exit 0
    deliver "${PANE}_pane_exited" ;;

  *)
    case "$EVENT" in pane.created|pane.closed) [ -z "$PANE" ] || { lock; forget_pane "$P"; unlock; } ;; esac
    event_on "$EVENT" || exit 0
    REASON="event"
    DATA="$(jq -c '.data // {}' <<<"$ev" 2>/dev/null)"; [ -n "$DATA" ] || DATA="{}"
    deliver "" ;;
esac
