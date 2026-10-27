#!/usr/bin/env bash
# Grok Bot Notify - herdr plugin hook.
# POSTs a small JSON payload to a Grok Bot routine webhook when any
# herdr-detected coding agent finishes, needs input, or exits, and (opt-in,
# see configure.sh) for other hookable herdr events. It never prints or logs the webhook URL
# or Authorization value, and sends terminal output only if GROKBOT_NOTIFY_OUTPUT_LINES > 0.
#
# Usage (normally invoked by herdr):
#   notify.sh            handle HERDR_PLUGIN_EVENT / HERDR_PLUGIN_EVENT_JSON
#   notify.sh --test     send a synthetic test payload now
#   notify.sh --enable   resume sending
#   notify.sh --disable  pause sending (event hooks stay registered)
#   notify.sh --status   print version, paths and settings (secrets shown as set/MISSING)
#
# Portable to bash 3.2 (macOS /bin/bash): no ${x,,}, no `local -`, no mapfile.
set -u
set -f   # never glob-expand list items such as "*"

VERSION="0.4.0"
SCHEMA=1   # payload schema; bump only for breaking changes (see CHANGELOG.md)
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr-grokbot-notify}"
CONFIG_FILE="${GROKBOT_NOTIFY_CONFIG:-$CONFIG_DIR/.env}"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-$HOME/.local/state/herdr-grokbot-notify}"
HERDR="${HERDR_BIN_PATH:-herdr}"

# herdr may start hooks with a minimal PATH (e.g. a launchd-started server on
# macOS), which hides Homebrew's jq. Append the usual locations if missing.
for d in /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$PATH:$d" ;; esac
done
export PATH

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
ALLOWED_KEYS=" GROKBOT_WEBHOOK_URL GROKBOT_WEBHOOK_AUTH GROKBOT_NOTIFY_EVENTS GROKBOT_NOTIFY_STATUSES GROKBOT_NOTIFY_AGENTS GROKBOT_NOTIFY_DEBOUNCE_SECS GROKBOT_NOTIFY_TIMEOUT_SECS GROKBOT_NOTIFY_INCLUDE_HOST GROKBOT_NOTIFY_OUTPUT_LINES GROKBOT_NOTIFY_OUTPUT_MAX_BYTES "
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
OUTPUT_LINES="${GROKBOT_NOTIFY_OUTPUT_LINES:-0}"
OUTPUT_MAX_BYTES="${GROKBOT_NOTIFY_OUTPUT_MAX_BYTES:-4000}"
case "$DEBOUNCE_SECS" in ''|*[!0-9]*) DEBOUNCE_SECS=60 ;; esac
case "$TIMEOUT_SECS" in ''|*[!0-9]*) TIMEOUT_SECS=10 ;; esac
case "$OUTPUT_LINES" in ''|*[!0-9]*) OUTPUT_LINES=0 ;; esac
case "$OUTPUT_MAX_BYTES" in ''|*[!0-9]*) OUTPUT_MAX_BYTES=4000 ;; esac
[ "$OUTPUT_LINES" -le 500 ] || OUTPUT_LINES=500
[ "$OUTPUT_MAX_BYTES" -le 65536 ] || OUTPUT_MAX_BYTES=65536

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
with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout 5 "$@"; else "$@"; fi; }

# Git branch and repo name for $CWD (repo = main checkout's folder name, also
# for linked worktrees). Empty outside a repo or without git.
git_context() {
  [ -n "$CWD" ] && [ -d "$CWD" ] && command -v git >/dev/null 2>&1 || return 0
  local common
  BRANCH="$(git -C "$CWD" symbolic-ref --short -q HEAD 2>/dev/null)" \
    || BRANCH="$(GIT_OPTIONAL_LOCKS=0 git -C "$CWD" rev-parse --short HEAD 2>/dev/null)" || BRANCH=""   # detached: short sha
  common="$(cd "$CWD" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)" || common=""
  case "$common" in
    */.git) REPO="${common%/.git}"; REPO="${REPO##*/}" ;;
    ?*) REPO="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"; REPO="${REPO##*/}"
        [ -n "$REPO" ] || { REPO="${common##*/}"; REPO="${REPO%.git}"; } ;;
  esac
}

# Workspace and tab labels as shown in herdr's sidebar.
herdr_labels() {
  local j
  if [ -n "$WS" ] && [ -z "$WS_LABEL" ]; then
    j="$(with_timeout "$HERDR" workspace get "$WS" 2>/dev/null || true)"
    WS_LABEL="$(jq -r '.result.workspace.label // empty' <<<"$j" 2>/dev/null)"
  fi
  if [ -n "$TAB" ] && [ -z "$TAB_LABEL" ]; then
    j="$(with_timeout "$HERDR" tab get "$TAB" 2>/dev/null || true)"
    TAB_LABEL="$(jq -r '.result.tab.label // empty' <<<"$j" 2>/dev/null)"
  fi
}

# Last GROKBOT_NOTIFY_OUTPUT_LINES lines of the pane (opt-in), escape sequences
# and control characters removed, capped at GROKBOT_NOTIFY_OUTPUT_MAX_BYTES
# (the most recent output is kept).
pane_output() {
  [ "$OUTPUT_LINES" -gt 0 ] && [ -n "$PANE" ] || return 0
  local raw
  raw="$(with_timeout "$HERDR" pane read "$PANE" --source recent-unwrapped --lines "$OUTPUT_LINES" 2>/dev/null)" || return 0
  raw="$(printf '%s\n' "$raw" \
    | LC_ALL=C sed -e $'s/\x1b][^\x07\x1b]*\x07//g' -e $'s/\x1b][^\x1b]*\x1b\\\\//g' \
        -e $'s/\x1b\\[[0-9;?<=>]*[ -/]*[@-~]//g' -e $'s/\x1b[@-_]//g' \
    | LC_ALL=C tr -d '\000-\010\013-\037\177')"
  if [ "$(printf '%s' "$raw" | wc -c | tr -d ' ')" -gt "$OUTPUT_MAX_BYTES" ]; then
    # drop the first (possibly cut) line so no partial UTF-8 is sent
    raw="$(printf '%s' "$raw" | tail -c "$OUTPUT_MAX_BYTES" | tail -n +2)"
    OUTPUT_TRUNC=true
  fi
  OUTPUT="$raw"
}

# Payload fields (empty ones are dropped; README "Payload" documents each one).
# data = raw herdr event data for generic events only.
EVENT="" REASON="" WS="" TAB="" PANE="" AGENT="" STATUS="" FINAL="" TITLE="" CWD="" DATA="null"
WS_LABEL="" TAB_LABEL="" BRANCH="" REPO="" OUTPUT="" OUTPUT_TRUNC=false
build_body() { # build_body <test:true|false>
  jq -nc --argjson schema "$SCHEMA" --arg v "$VERSION" --arg e "$EVENT" --arg r "$REASON" \
    --arg ws "$WS" --arg wsl "$WS_LABEL" --arg tab "$TAB" --arg tabl "$TAB_LABEL" \
    --arg p "$PANE" --arg a "$AGENT" --arg s "$STATUS" --arg f "$FINAL" --arg t "$TITLE" \
    --arg c "$CWD" --arg repo "$REPO" --arg br "$BRANCH" --arg h "$(host_name)" --arg at "$(now_iso)" \
    --arg out "$OUTPUT" --argjson trunc "$OUTPUT_TRUNC" --argjson test "$1" --argjson data "$DATA" \
    '{source:"herdr",schema:$schema,plugin_version:$v,event:$e,reason:$r,
      workspace_id:$ws,workspace_label:$wsl,tab_id:$tab,tab_label:$tabl,pane_id:$p,
      agent:$a,agent_status:$s,final_status:$f,title:$t,cwd:$c,repo:$repo,branch:$br,host:$h,at:$at}
     | with_entries(select(.value != ""))
     | .message = (if $r == "test" then "Grok Bot Notify test notification" + (if .host then " from " + .host else "" end) else
         ((.agent // (if $e == "test" then "grokbot-notify" else "herdr" end))
          + " " + ({finished:"finished", needs_attention:"needs your input",
                    agent_exited:("exited" + (if $f != "" then " (last status: " + $f + ")" else "" end)),
                    pane_exited:"pane exited", agent_started:"started", test:"test notification",
                    status_changed:("is now " + $s), event:$e}[$r] // $r))
         + (if (.repo // .cwd) then " in " + (.repo // (.cwd | sub("/+$"; "") | split("/") | last))
              + (if .branch then " (" + .branch + ")" else "" end) else "" end)
         + (if .title then ": " + .title else "" end)
         + ([.workspace_label, .tab_label] | map(select(. != null)) | if length > 0 then " [" + join(" / ") + "]" else "" end)
         + (if .host then " on " + .host else "" end) end)
     | . + {test:$test}
     | if $out != "" then . + {output:$out, output_truncated:$trunc} else . end
     | if $data == null then . else . + {data:$data} end'
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
    echo "output lines: $OUTPUT_LINES (max ${OUTPUT_MAX_BYTES} bytes)"
    echo "log         : $LOG"
    exit 0 ;;
  --test)
    if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then echo "grokbot-notify: needs jq and curl" >&2; exit 1; fi
    have_secrets || { echo "grokbot-notify: webhook URL/Authorization not configured ($CONFIG_FILE)" >&2; exit 1; }
    EVENT="test" REASON="test" WS="test" PANE="test" AGENT="test" STATUS="done" TITLE="grokbot-notify test" CWD="$PWD"
    git_context
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
# Debounce stamps of one pane's status-driven reasons. Cleared whenever the
# pane's status changes, so only identical back-to-back transitions are
# debounced (blocked -> working -> blocked sends twice).
clear_status_stamps() {
  local r
  for r in needs_attention finished working unknown idle "done" blocked; do rm -f "$STATE_DIR/last_$(safe "${1}_$r")"; done
}

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
  [ "$REASON" = event ] || { herdr_labels; git_context; pane_output; }
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
    [ "$prev" = "$STATUS" ] || clear_status_stamps "$PANE"
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
