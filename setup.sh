#!/usr/bin/env bash
# Grok Bot Notify - interactive setup.
# Asks for the Grok Bot routine webhook URL and Authorization header (input is
# hidden), plus optional advanced settings, and writes <config dir>/.env (600).
# Usage: setup.sh [--config-dir DIR] [--plugin-id ID]
set -euo pipefail
set -f

PLUGIN_ID="${HERDR_PLUGIN_ID:-grokbot-notify}"
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --config-dir) CONFIG_DIR="$2"; shift 2 ;;
    --plugin-id)  PLUGIN_ID="$2"; shift 2 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$CONFIG_DIR" ]; then
  HERDR="${HERDR_BIN_PATH:-herdr}"
  CONFIG_DIR="$("$HERDR" plugin config-dir "$PLUGIN_ID" 2>/dev/null || true)"
fi
[ -n "$CONFIG_DIR" ] || CONFIG_DIR="$HOME/.config/herdr-grokbot-notify"
CONFIG_FILE="$CONFIG_DIR/.env"

[ -t 0 ] || { echo "setup.sh needs an interactive terminal." >&2; exit 1; }

# current value of KEY from an existing config (never printed for secrets)
cur() {
  [ -f "$CONFIG_FILE" ] || return 0
  { grep -E "^(export )?$1=" "$CONFIG_FILE" || true; } | tail -1 | sed -E "s/^(export )?$1=//; s/^[\"']//; s/[\"']\$//"
}
bad_chars() { case "$1" in *[\"\\]*|*$'\n'*) return 0 ;; esac; return 1; }

echo "Grok Bot Notify setup"
echo "Config file: $CONFIG_FILE"
echo "In Grok Bot, create a routine with a webhook trigger, then paste its URL"
echo "and Authorization header here. Input is hidden."
echo

old_url="$(cur GROKBOT_WEBHOOK_URL)"; old_auth="$(cur GROKBOT_WEBHOOK_AUTH)"
hint=""; [ -z "$old_url" ] || hint=" (Enter = keep current)"
read -r -s -p "Webhook URL$hint: " url; echo
url="${url//[[:space:]]/}"; [ -n "$url" ] || url="$old_url"
case "$url" in https://*) ;; *) echo "Expected an https:// URL. Nothing written." >&2; exit 1 ;; esac

hint=""; [ -z "$old_auth" ] || hint=" (Enter = keep current)"
read -r -s -p "Authorization header, e.g. 'Bearer ...'$hint: " auth; echo
auth="${auth#"${auth%%[![:space:]]*}"}"; auth="${auth%"${auth##*[![:space:]]}"}"
[ -n "$auth" ] || auth="$old_auth"
[ -n "$auth" ] || { echo "Authorization value is empty. Nothing written." >&2; exit 1; }
if bad_chars "$url$auth"; then echo "Values must not contain quotes or backslashes. Nothing written." >&2; exit 1; fi
unset old_url old_auth

# --- optional advanced settings (Enter keeps the shown value) ---
agents="$(cur GROKBOT_NOTIFY_AGENTS)"; events="$(cur GROKBOT_NOTIFY_EVENTS)"
statuses="$(cur GROKBOT_NOTIFY_STATUSES)"; debounce="$(cur GROKBOT_NOTIFY_DEBOUNCE_SECS)"
ask() { # ask <prompt> <current-or-default>
  local v; read -r -p "  $1 [$2]: " v || true; v="${v//[[:space:]]/}"; printf '%s' "${v:-$2}"
}
read -r -p "Change advanced settings (agents, events, debounce)? [y/N] " adv || true
case "${adv:-}" in
  [Yy]*)
    echo "  Agents: comma-separated herdr agent ids (claude,codex,cursor,gemini,...) or * for all."
    agents="$(ask "Agents" "${agents:-*}")"
    echo "  Events: pane.agent_status_changed, agent.released, pane.exited, pane.agent_detected,"
    echo "  workspace.*, worktree.*, tab.*, pane.created/closed/focused/moved (full names), or *."
    events="$(ask "Events" "${events:-pane.agent_status_changed,agent.released,pane.exited}")"
    echo "  Statuses: done, idle (= finished), blocked (= needs input), working, unknown."
    statuses="$(ask "Statuses" "${statuses:-done,idle,blocked}")"
    debounce="$(ask "Debounce seconds per pane + reason" "${debounce:-60}")"
    case "$debounce" in *[!0-9]*) echo "Debounce must be a number. Nothing written." >&2; exit 1 ;; esac
    for v in "$agents" "$events" "$statuses"; do
      if bad_chars "$v"; then echo "Settings must not contain quotes or backslashes. Nothing written." >&2; exit 1; fi
    done ;;
esac

mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR" 2>/dev/null || true
tmp="$(umask 077; mktemp "$CONFIG_DIR/.env.XXXXXX")"
{
  echo "# Written by grokbot-notify setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Keep private."
  printf 'GROKBOT_WEBHOOK_URL=%s\n' "$url"
  printf 'GROKBOT_WEBHOOK_AUTH=%s\n' "$auth"
  [ -z "$agents" ]   || printf 'GROKBOT_NOTIFY_AGENTS=%s\n' "$agents"
  [ -z "$events" ]   || printf 'GROKBOT_NOTIFY_EVENTS=%s\n' "$events"
  [ -z "$statuses" ] || printf 'GROKBOT_NOTIFY_STATUSES=%s\n' "$statuses"
  [ -z "$debounce" ] || printf 'GROKBOT_NOTIFY_DEBOUNCE_SECS=%s\n' "$debounce"
  # keep any other optional tuning lines from a previous config
  if [ -f "$CONFIG_FILE" ]; then
    grep -E '^(export )?GROKBOT_NOTIFY_[A-Z_]+=' "$CONFIG_FILE" \
      | grep -v -E '^(export )?GROKBOT_NOTIFY_(AGENTS|EVENTS|STATUSES|DEBOUNCE_SECS)=' || true
  fi
} > "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$CONFIG_FILE"
unset url auth
echo "Saved (mode 600): $CONFIG_FILE"

here="$(cd "$(dirname "$0")" && pwd)"
read -r -p "Send a test webhook now? [y/N] " ans || true
case "${ans:-}" in
  [Yy]*) GROKBOT_NOTIFY_CONFIG="$CONFIG_FILE" bash "$here/notify.sh" --test || true ;;
esac
if [ -n "${HERDR_PLUGIN_ID:-}" ]; then read -r -p "Press Enter to close." _ || true; fi
