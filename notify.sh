#!/usr/bin/env bash
# Grok Bot Notify - herdr plugin hook.
# POSTs a small JSON payload to a Grok Bot routine webhook when a coding-agent
# pane changes to a configured status (default: done / blocked).
# It never prints or logs the webhook URL or Authorization value.
#
# Usage (normally invoked by herdr):
#   notify.sh            handle HERDR_PLUGIN_EVENT_JSON (pane.agent_status_changed)
#   notify.sh --test     send a synthetic test payload now
#   notify.sh --enable   resume sending
#   notify.sh --disable  pause sending (event hook stays registered)
#   notify.sh --status   print config summary (no secret values)
set -u

CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr-grokbot-notify}"
CONFIG_FILE="${GROKBOT_NOTIFY_CONFIG:-$CONFIG_DIR/.env}"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-$HOME/.local/state/herdr-grokbot-notify}"
HERDR="${HERDR_BIN_PATH:-herdr}"

mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null
LOG="$STATE_DIR/notify.log"
DISABLED_FLAG="$STATE_DIR/disabled"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(now_iso)" "$*" >> "$LOG" 2>/dev/null || true; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# --- config: KEY=VALUE lines, parsed (never sourced/executed). Env vars win. ---
ALLOWED_KEYS=" GROKBOT_WEBHOOK_URL GROKBOT_WEBHOOK_AUTH GROKBOT_NOTIFY_STATUSES GROKBOT_NOTIFY_AGENTS GROKBOT_NOTIFY_DEBOUNCE_SECS GROKBOT_NOTIFY_TIMEOUT_SECS GROKBOT_NOTIFY_INCLUDE_HOST "
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

STATUSES="$(lower "${GROKBOT_NOTIFY_STATUSES:-done,blocked}")"
AGENTS="$(lower "${GROKBOT_NOTIFY_AGENTS:-claude,codex}")"
DEBOUNCE_SECS="${GROKBOT_NOTIFY_DEBOUNCE_SECS:-180}"
TIMEOUT_SECS="${GROKBOT_NOTIFY_TIMEOUT_SECS:-10}"
INCLUDE_HOST="${GROKBOT_NOTIFY_INCLUDE_HOST:-1}"
case "$DEBOUNCE_SECS" in ''|*[!0-9]*) DEBOUNCE_SECS=180 ;; esac
case "$TIMEOUT_SECS" in ''|*[!0-9]*) TIMEOUT_SECS=10 ;; esac

in_list() { # in_list <needle> <comma-list> [substring]
  local needle="$1" list="$2" mode="${3:-exact}" item
  local IFS=',' -
  set -f   # no glob expansion of "*" items
  for item in $list; do
    item="${item//[[:space:]]/}"
    [ -n "$item" ] || continue
    [ "$item" = "*" ] && return 0
    if [ "$mode" = substring ]; then
      case "$needle" in *"$item"*) return 0 ;; esac
    else
      [ "$needle" = "$item" ] && return 0
    fi
  done
  return 1
}

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

build_body() { # ws pane agent status title cwd test
  jq -nc --arg ws "$1" --arg p "$2" --arg a "$3" --arg s "$4" --arg t "$5" --arg c "$6" \
    --arg h "$(host_name)" --arg at "$(now_iso)" --argjson test "$7" \
    '{source:"herdr",event:"pane.agent_status_changed",workspace_id:$ws,pane_id:$p,agent:$a,agent_status:$s,title:$t,cwd:$c,host:$h,at:$at,test:$test}'
}

# --- subcommands ---
case "${1:-}" in
  --enable)  rm -f "$DISABLED_FLAG"; log "enabled"; echo "grokbot-notify: enabled"; exit 0 ;;
  --disable) : > "$DISABLED_FLAG"; log "disabled"; echo "grokbot-notify: disabled"; exit 0 ;;
  --status)
    echo "config file : $CONFIG_FILE ($( [ -r "$CONFIG_FILE" ] && echo present || echo missing ))"
    echo "state dir   : $STATE_DIR"
    echo "enabled     : $( [ -e "$DISABLED_FLAG" ] && echo no || echo yes )"
    echo "webhook url : $( [ -n "${GROKBOT_WEBHOOK_URL:-}" ] && echo set || echo MISSING )"
    echo "auth header : $( [ -n "${GROKBOT_WEBHOOK_AUTH:-}" ] && echo set || echo MISSING )"
    echo "statuses    : $STATUSES"
    echo "agents      : $AGENTS"
    echo "debounce    : ${DEBOUNCE_SECS}s"
    exit 0 ;;
  --test)
    if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then echo "grokbot-notify: needs jq and curl" >&2; exit 1; fi
    have_secrets || { echo "grokbot-notify: webhook URL/Authorization not configured ($CONFIG_FILE)" >&2; exit 1; }
    code="$(send "$(build_body "test" "test" "test" "done" "grokbot-notify test" "$PWD" true)")"
    log "test: http=$code"
    echo "grokbot-notify: test webhook -> HTTP $code"
    case "$code" in 2*) exit 0 ;; *) exit 1 ;; esac ;;
  "") ;;
  *) echo "usage: notify.sh [--test|--enable|--disable|--status]" >&2; exit 2 ;;
esac

# --- event hook ---
[ -e "$DISABLED_FLAG" ] && exit 0
if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then log "error: jq and curl are required"; exit 0; fi
ev="${HERDR_PLUGIN_EVENT_JSON:-}"
[ -n "$ev" ] || { log "skip: no event json"; exit 0; }

get() { jq -r "(.data.$1 // .$1 // .data.pane.$1 // .pane.$1 // empty) | tostring" <<<"$ev" 2>/dev/null; }

status="$(lower "$(get agent_status)")"
in_list "$status" "$STATUSES" || exit 0
pane_id="$(get pane_id)"; [ -n "$pane_id" ] || pane_id="${HERDR_PANE_ID:-}"
[ -n "$pane_id" ] || { log "skip: no pane_id status=$status"; exit 0; }

workspace_id="$(get workspace_id)"
agent="$(get agent)"
title="$(get terminal_title_stripped)"; [ -n "$title" ] || title="$(get title)"
cwd="$(get cwd)"

# Fill gaps from an authoritative pane read.
if [ -z "$agent" ] || [ -z "$title" ] || [ -z "$cwd" ] || [ -z "$workspace_id" ]; then
  if command -v timeout >/dev/null 2>&1; then
    pj="$(timeout 5 "$HERDR" pane get "$pane_id" 2>/dev/null || true)"
  else
    pj="$("$HERDR" pane get "$pane_id" 2>/dev/null || true)"
  fi
  if [ -n "$pj" ]; then
    pf() { jq -r "(.result.pane.$1 // empty) | tostring" <<<"$pj" 2>/dev/null; }
    [ -n "$agent" ] || agent="$(pf agent)"
    [ -n "$title" ] || title="$(pf terminal_title_stripped)"
    [ -n "$title" ] || title="$(pf terminal_title)"
    [ -n "$cwd" ] || cwd="$(pf cwd)"
    [ -n "$workspace_id" ] || workspace_id="$(pf workspace_id)"
  fi
fi
[ -n "$workspace_id" ] || workspace_id="${pane_id%%:*}"
agent="$(lower "$agent")"
in_list "$agent" "$AGENTS" substring || { log "skip: pane=$pane_id status=$status agent=${agent:-none}"; exit 0; }

have_secrets || { log "error: webhook URL/Authorization not configured"; exit 0; }

# --- debounce (portable mkdir lock; no flock on macOS) ---
key="$(printf '%s_%s' "$pane_id" "$status" | tr -c 'A-Za-z0-9_.-' '_')"
stamp="$STATE_DIR/last_$key"
lockdir="$STATE_DIR/.lock"
for _ in 1 2 3 4 5 6 7 8 9 10; do mkdir "$lockdir" 2>/dev/null && break; sleep 0.5; done
trap 'rmdir "$lockdir" 2>/dev/null' EXIT
now="$(date +%s)"
if [ -f "$stamp" ]; then
  last="$(cat "$stamp" 2>/dev/null)"; case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -lt "$DEBOUNCE_SECS" ]; then log "debounced: pane=$pane_id status=$status"; exit 0; fi
fi
echo "$now" > "$stamp"
rmdir "$lockdir" 2>/dev/null; trap - EXIT

code="$(send "$(build_body "$workspace_id" "$pane_id" "$agent" "$status" "$title" "$cwd" false)")"
log "sent: pane=$pane_id agent=$agent status=$status http=$code"
case "$code" in 2*) ;; *) rm -f "$stamp" ;; esac   # allow retry on next change
exit 0
