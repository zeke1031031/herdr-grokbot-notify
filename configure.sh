#!/usr/bin/env bash
# Grok Bot Notify - non-interactive configuration (built for a Grok Bot or a script).
#
# Secrets are never taken as arguments, so they don't land in shell history,
# `ps`, or a chat transcript:
#   --url-from-env        read the webhook URL from $GROKBOT_WEBHOOK_URL
#   --auth-from-env       read the Authorization value from $GROKBOT_WEBHOOK_AUTH
#   --secrets-from-stdin  read the URL (line 1) and Authorization value (line 2) from stdin
# Settings:
#   --events SPEC    comma list. +name turns an event on, -name turns it off,
#                    bare names replace the optional set (core events untouched).
#                    Keywords: none (no optional events), all (every optional
#                    event), default (core events only).
#   --agents LIST    agent ids or substrings, "*" = every agent (default)
#   --statuses LIST  default done,idle,blocked
#   --debounce N     seconds per pane + reason (default 60)
# Info / maintenance:
#   --list [--json]  list every event with on/off and a one-line description
#   --show           config summary (never prints secret values)
#   --apply          re-create the optional-event registration from saved config
#   --test           send the plugin's test webhook after saving
#   --plugin-id ID   default: id in herdr-plugin.toml
#   --config-dir DIR default: `herdr plugin config-dir <id>`
#   --no-herdr       don't link/unlink the companion plugin (tests, dry setups)
#
# Core events (registered by the plugin manifest itself):
#   pane.agent_status_changed  finished / needs_attention
#   agent.released             agent_exited (from pane.agent_detected released:true)
#   pane.exited                pane_exited (panes that ran an agent)
#   pane.agent_detected        agent_started (optional, off by default)
# Every other optional event is registered through a small generated companion
# plugin, <id>-events, that lives in the config dir and forwards to notify.sh.
# Nothing in the plugin checkout is modified, so `git pull` and
# `herdr plugin update` stay clean. With no optional events (the default) the
# companion does not exist and herdr runs no extra hooks.
set -euo pipefail
set -f

ROOT="$(cd "$(dirname "$0")" && pwd)"
HERDR="${HERDR_BIN_PATH:-herdr}"
PLUGIN_ID="$(sed -n 's/^id = "\(.*\)"/\1/p' "$ROOT/herdr-plugin.toml" | head -1)"
[ -n "$PLUGIN_ID" ] || PLUGIN_ID="grokbot-notify"
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-}"
URL_ENV=0 AUTH_ENV=0 STDIN=0 EVENTS_SPEC="" AGENTS_SET="" STATUSES_SET="" DEBOUNCE_SET=""
DO_LIST=0 JSON=0 DO_SHOW=0 DO_APPLY=0 DO_TEST=0 USE_HERDR=1 CHANGED=0

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "configure: $*" >&2; exit 1; }
need() { [ $# -ge 2 ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --url-from-env) URL_ENV=1; CHANGED=1; shift ;;
    --auth-from-env) AUTH_ENV=1; CHANGED=1; shift ;;
    --secrets-from-stdin) STDIN=1; CHANGED=1; shift ;;
    --events) need "$@"; EVENTS_SPEC="$2"; CHANGED=1; shift 2 ;;
    --agents) need "$@"; AGENTS_SET="$2"; CHANGED=1; shift 2 ;;
    --statuses) need "$@"; STATUSES_SET="$2"; CHANGED=1; shift 2 ;;
    --debounce) need "$@"; DEBOUNCE_SET="$2"; CHANGED=1; shift 2 ;;
    --list) DO_LIST=1; shift ;;
    --json) JSON=1; shift ;;
    --show) DO_SHOW=1; shift ;;
    --apply) DO_APPLY=1; shift ;;
    --test) DO_TEST=1; shift ;;
    --plugin-id) need "$@"; PLUGIN_ID="$2"; shift 2 ;;
    --config-dir) need "$@"; CONFIG_DIR="$2"; shift 2 ;;
    --no-herdr) USE_HERDR=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --url|--auth|--url=*|--auth=*) die "secrets are not accepted as arguments; use --url-from-env/--auth-from-env or --secrets-from-stdin" ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ $((CHANGED + DO_LIST + DO_SHOW + DO_APPLY + DO_TEST)) -gt 0 ] || DO_SHOW=1

if [ -z "$CONFIG_DIR" ]; then
  CONFIG_DIR="$("$HERDR" plugin config-dir "$PLUGIN_ID" 2>/dev/null || true)"
fi
[ -n "$CONFIG_DIR" ] || CONFIG_DIR="$HOME/.config/herdr-grokbot-notify"
CONFIG_FILE="$CONFIG_DIR/.env"
COMP_ID="${PLUGIN_ID}-events"
COMP_DIR="$CONFIG_DIR/events-plugin"

# --- event catalog: name|kind|reason|description ---
# kind: core = registered by the main manifest; extra = needs the companion.
CATALOG='pane.agent_status_changed|core|finished, needs_attention|an agent finished a turn or is blocked waiting for you (statuses: done, idle, blocked)
agent.released|core|agent_exited|an agent quit or crashed in its pane
pane.exited|core|pane_exited|a pane that was running an agent exited
pane.agent_detected|core-opt|agent_started|an agent started in a pane
workspace.created|extra|event|a workspace was created
workspace.updated|extra|event|a workspace changed (e.g. its cwd or settings)
workspace.closed|extra|event|a workspace was closed
workspace.renamed|extra|event|a workspace was renamed
workspace.moved|extra|event|a workspace was moved
workspace.reordered|extra|event|the workspace list was reordered
worktree.created|extra|event|a git worktree was created from herdr
worktree.opened|extra|event|an existing git worktree was opened as a workspace
worktree.removed|extra|event|a git worktree was removed
tab.created|extra|event|a tab was created
tab.closed|extra|event|a tab was closed
tab.renamed|extra|event|a tab was renamed
tab.moved|extra|event|a tab was moved
pane.created|extra|event|a pane was created
pane.closed|extra|event|a pane was closed
pane.moved|extra|event|a pane was moved'
CORE_DEFAULT="pane.agent_status_changed,agent.released,pane.exited"

kind_of() { printf '%s\n' "$CATALOG" | awk -F'|' -v n="$1" '$1==n{print $2}'; }
all_names() { printf '%s\n' "$CATALOG" | cut -d'|' -f1; }
optional_names() { printf '%s\n' "$CATALOG" | awk -F'|' '$2!="core"{print $1}'; }
extra_names() { printf '%s\n' "$CATALOG" | awk -F'|' '$2=="extra"{print $1}'; }

# --- config file helpers (parsed, never sourced) ---
cur() {
  [ -f "$CONFIG_FILE" ] || return 0
  { grep -E "^(export )?$1=" "$CONFIG_FILE" || true; } | tail -1 | sed -E "s/^(export )?$1=//; s/^[\"']//; s/[\"']\$//"
}
bad_chars() { case "$1" in *[\"\\]*|*$'\n'*|*$'\r'*) return 0 ;; esac; return 1; }
trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }
url_ok() {
  case "$1" in
    https://?*) return 0 ;;
    http://127.0.0.1[:/]*|http://localhost[:/]*) return 0 ;;   # local testing only
  esac
  return 1
}

# normalized, de-duplicated, catalog-ordered list from a comma list
normalize() {
  local list=",$1," n out="" IFS=$' \n\t'
  for n in $(all_names); do case "$list" in *",$n,"*) out="$out,$n" ;; esac; done
  printf '%s' "${out#,}"
}
current_events() {
  local e; e="$(cur GROKBOT_NOTIFY_EVENTS)"
  [ -n "$e" ] || e="$CORE_DEFAULT"
  if [ "$e" = "*" ]; then all_names | paste -sd, -; return; fi
  normalize "$(printf '%s' "$e" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
}
has() { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }

apply_spec() { # apply_spec <current> <spec> -> new list
  local curl="$1" spec tok name bare="" mode="" IFS=','
  spec="$(printf '%s' "$2" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  local set="$curl"
  for tok in $spec; do
    [ -n "$tok" ] || continue
    case "$tok" in
      none)    set="$(core_part "$set")" ;;
      all)     set="$(core_part "$set"),$(optional_names | paste -sd, -)" ;;
      default) set="$CORE_DEFAULT" ;;
      +*|-*)
        name="${tok#?}"; check_name "$name"
        if [ "${tok:0:1}" = "+" ]; then set="$set,$name"; else set="$(remove "$set" "$name")"; fi ;;
      *) check_name "$tok"; bare="$bare,$tok"; mode=replace ;;
    esac
  done
  [ "$mode" != replace ] || set="$(core_part "$set")$bare"
  normalize "$set"
}
core_part() { local n out=""; for n in pane.agent_status_changed agent.released pane.exited; do has "$1" "$n" && out="$out,$n"; done; printf '%s' "${out#,}"; }
remove() { local n out=""; IFS=','; for n in $1; do [ "$n" = "$2" ] || out="$out,$n"; done; unset IFS; printf '%s' "${out#,}"; }
check_name() {
  case "$1" in
    *.focused) die "'$1' is not supported (focus events fire on every click and are not registered)" ;;
  esac
  [ -n "$(kind_of "$1")" ] || die "unknown event '$1' (run --list)"
}

# --- companion plugin for optional herdr events ---
write_companion() { # write_companion <extra-events-comma-list>
  local list="$1" e tmp
  mkdir -p "$COMP_DIR"
  tmp="$(mktemp "$COMP_DIR/.manifest.XXXXXX")"
  {
    echo "# Generated by grokbot-notify configure.sh - do not edit; re-run configure.sh."
    printf 'id = "%s"\n' "$COMP_ID"
    printf 'name = "Grok Bot Notify (optional events)"\n'
    printf 'version = "%s"\n' "$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/herdr-plugin.toml" | head -1)"
    printf 'min_herdr_version = "0.9.5"\n'
    printf 'description = "Forwards the optional herdr events you enabled to %s."\n' "$PLUGIN_ID"
    printf 'platforms = ["linux", "macos"]\n'
    IFS=','; for e in $list; do printf '\n[[events]]\non = "%s"\ncommand = ["bash", "hook.sh"]\n' "$e"; done; unset IFS
  } > "$tmp"
  mv -f "$tmp" "$COMP_DIR/herdr-plugin.toml"
  {
    echo '#!/usr/bin/env bash'
    echo "# Generated by grokbot-notify configure.sh: hands optional herdr events to the main plugin."
    printf 'MAIN_ID=%q\nMAIN_ROOT=%q\nMAIN_CONFIG_DIR=%q\n' "$PLUGIN_ID" "$ROOT" "$CONFIG_DIR"
    cat <<'HOOK'
H="${HERDR_BIN_PATH:-herdr}"
info="$("$H" plugin list --plugin "$MAIN_ID" --json 2>/dev/null || true)"
if [ -n "$info" ] && command -v jq >/dev/null 2>&1; then
  [ "$(jq -r '.result.plugins[0].enabled == false' <<<"$info")" = true ] && exit 0
  [ -f "$MAIN_ROOT/notify.sh" ] || MAIN_ROOT="$(jq -r '.result.plugins[0].plugin_root // empty' <<<"$info")"
fi
[ -f "$MAIN_ROOT/notify.sh" ] || exit 0
export HERDR_PLUGIN_CONFIG_DIR="$MAIN_CONFIG_DIR"
exec bash "$MAIN_ROOT/notify.sh"
HOOK
  } > "$COMP_DIR/hook.sh"
  chmod 700 "$COMP_DIR/hook.sh"
}
comp_linked() { "$HERDR" plugin list --plugin "$COMP_ID" --json 2>/dev/null | grep -q -E "\"plugin_id\": *\"$COMP_ID\""; }
sync_companion() { # sync_companion <full-event-list>
  local extras="" n
  for n in $(extra_names); do has "$1" "$n" && extras="$extras,$n"; done
  extras="${extras#,}"
  if [ -n "$extras" ]; then
    write_companion "$extras"
    if [ "$USE_HERDR" = 1 ]; then
      "$HERDR" plugin link "$COMP_DIR" >/dev/null 2>&1 || die "herdr plugin link $COMP_DIR failed"
      "$HERDR" plugin enable "$COMP_ID" >/dev/null 2>&1 || true
    fi
    echo "optional hooks : $extras (via companion plugin $COMP_ID)"
  else
    if [ "$USE_HERDR" = 1 ] && comp_linked; then "$HERDR" plugin unlink "$COMP_ID" >/dev/null 2>&1 || true; fi
    rm -rf "$COMP_DIR"
    echo "optional hooks : none (no companion plugin, no extra hook processes)"
  fi
}

# --- --list ---
list_events() {
  local evs; evs="$(current_events)"
  if [ "$JSON" = 1 ]; then
    command -v jq >/dev/null || die "--json needs jq"
    printf '%s\n' "$CATALOG" | while IFS='|' read -r n k r d; do
      on=false; has "$evs" "$n" && on=true
      jq -nc --arg n "$n" --arg k "$k" --arg r "$r" --arg d "$d" --argjson on "$on" \
        '{name:$n, default:($k=="core"), enabled:$on, reason:$r, description:$d}'
    done | jq -sc .
  else
    printf '%s\n' "$CATALOG" | while IFS='|' read -r n k r d; do
      on=off; has "$evs" "$n" && on=on
      tag=optional; [ "$k" = core ] && tag=default
      printf '%-3s  %-26s %-8s %s  [reason: %s]\n' "$on" "$n" "$tag" "$d" "$r"
    done
  fi
}

show() {
  echo "plugin id      : $PLUGIN_ID ($ROOT)"
  echo "config file    : $CONFIG_FILE ($( [ -f "$CONFIG_FILE" ] && echo present || echo missing ))"
  echo "webhook url    : $( [ -n "$(cur GROKBOT_WEBHOOK_URL)" ] && echo set || echo MISSING )"
  echo "authorization  : $( [ -n "$(cur GROKBOT_WEBHOOK_AUTH)" ] && echo set || echo MISSING )"
  echo "events         : $(current_events)"
  local a s d; a="$(cur GROKBOT_NOTIFY_AGENTS)"; s="$(cur GROKBOT_NOTIFY_STATUSES)"; d="$(cur GROKBOT_NOTIFY_DEBOUNCE_SECS)"
  echo "agents         : ${a:-*}"
  echo "statuses       : ${s:-done,idle,blocked}"
  echo "debounce       : ${d:-60}s"
  if [ -f "$COMP_DIR/herdr-plugin.toml" ]; then
    echo "companion      : $COMP_ID ($(sed -n 's/^on = "\(.*\)"/\1/p' "$COMP_DIR/herdr-plugin.toml" | paste -sd, -))"
  else
    echo "companion      : none"
  fi
}

# --- main ---
if [ "$CHANGED" = 1 ]; then
  url="$(cur GROKBOT_WEBHOOK_URL)"; auth="$(cur GROKBOT_WEBHOOK_AUTH)"
  if [ "$STDIN" = 1 ]; then
    IFS= read -r url || true; IFS= read -r auth || true
  fi
  [ "$URL_ENV" = 0 ] || url="${GROKBOT_WEBHOOK_URL:-}"
  [ "$AUTH_ENV" = 0 ] || auth="${GROKBOT_WEBHOOK_AUTH:-}"
  url="$(trim "${url%$'\r'}")"; auth="$(trim "${auth%$'\r'}")"
  if [ "$URL_ENV$AUTH_ENV$STDIN" != 000 ]; then
    [ -n "$url" ] || die "webhook URL is empty; nothing written"
    [ -n "$auth" ] || die "Authorization value is empty; nothing written"
  fi
  [ -z "$url" ] || url_ok "$url" || die "webhook URL must start with https://; nothing written"
  if bad_chars "$url$auth"; then die "values must not contain quotes, backslashes or newlines; nothing written"; fi

  events="$(current_events)"
  [ -z "$EVENTS_SPEC" ] || events="$(apply_spec "$events" "$EVENTS_SPEC")"
  agents="${AGENTS_SET:-$(cur GROKBOT_NOTIFY_AGENTS)}"; agents="${agents:-*}"
  statuses="${STATUSES_SET:-$(cur GROKBOT_NOTIFY_STATUSES)}"; statuses="${statuses:-done,idle,blocked}"
  debounce="${DEBOUNCE_SET:-$(cur GROKBOT_NOTIFY_DEBOUNCE_SECS)}"; debounce="${debounce:-60}"
  case "$debounce" in *[!0-9]*) die "--debounce must be a whole number of seconds" ;; esac
  for v in "$agents" "$statuses"; do bad_chars "$v" && die "settings must not contain quotes or backslashes"; done
  agents="$(printf '%s' "$agents" | tr -d '[:space:]')"; statuses="$(printf '%s' "$statuses" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"

  mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR" 2>/dev/null || true
  tmp="$(umask 077; mktemp "$CONFIG_DIR/.env.XXXXXX")"
  {
    echo "# Written by grokbot-notify configure.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Keep private."
    [ -z "$url" ]  || printf 'GROKBOT_WEBHOOK_URL=%s\n' "$url"
    [ -z "$auth" ] || printf 'GROKBOT_WEBHOOK_AUTH=%s\n' "$auth"
    printf 'GROKBOT_NOTIFY_EVENTS=%s\n' "${events:-none}"
    printf 'GROKBOT_NOTIFY_AGENTS=%s\n' "$agents"
    printf 'GROKBOT_NOTIFY_STATUSES=%s\n' "$statuses"
    printf 'GROKBOT_NOTIFY_DEBOUNCE_SECS=%s\n' "$debounce"
    if [ -f "$CONFIG_FILE" ]; then
      grep -E '^(export )?GROKBOT_NOTIFY_[A-Z_]+=' "$CONFIG_FILE" \
        | grep -v -E '^(export )?GROKBOT_NOTIFY_(AGENTS|EVENTS|STATUSES|DEBOUNCE_SECS)=' || true
    fi
  } > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$CONFIG_FILE"
  unset url auth
  echo "saved (mode 600): $CONFIG_FILE"
  sync_companion "$events"
elif [ "$DO_APPLY" = 1 ]; then
  sync_companion "$(current_events)"
fi

[ "$DO_LIST" = 0 ] || list_events
[ "$DO_SHOW" = 0 ] || show
if [ "$DO_TEST" = 1 ]; then
  GROKBOT_NOTIFY_CONFIG="$CONFIG_FILE" HERDR_PLUGIN_CONFIG_DIR="$CONFIG_DIR" bash "$ROOT/notify.sh" --test
fi
