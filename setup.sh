#!/usr/bin/env bash
# Grok Bot Notify - interactive setup (the herdr popup).
# Asks for the Grok Bot routine webhook URL and Authorization header (input is
# hidden) plus optional settings, then hands everything to configure.sh, which
# writes <config dir>/.env (mode 600) and registers any optional events.
# Usage: setup.sh [--config-dir DIR] [--plugin-id ID]
set -euo pipefail
set -f

here="$(cd "$(dirname "$0")" && pwd)"
pass=()
while [ $# -gt 0 ]; do
  case "$1" in
    --config-dir|--plugin-id) [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; pass+=("$1" "$2"); shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
cfg() { bash "$here/configure.sh" ${pass[@]+"${pass[@]}"} "$@"; }

[ -t 0 ] || { echo "setup.sh needs an interactive terminal (bots: use configure.sh)." >&2; exit 1; }

echo "Grok Bot Notify setup"
cfg --show | sed -n '2,4p'
echo
echo "In Grok Bot, create a routine with a webhook trigger, then paste its URL"
echo "and Authorization header here. Input is hidden; Enter keeps a saved value."
read -r -s -p "Webhook URL: " url; echo
read -r -s -p "Authorization header, e.g. 'Bearer ...': " auth; echo
flags=()
if [ -n "${url//[[:space:]]/}" ]; then export GROKBOT_WEBHOOK_URL="$url"; flags+=(--url-from-env); fi
if [ -n "${auth//[[:space:]]/}" ]; then export GROKBOT_WEBHOOK_AUTH="$auth"; flags+=(--auth-from-env); fi
unset url auth

read -r -p "Choose optional events or other settings? [y/N] " adv || true
case "${adv:-}" in
  [Yy]*)
    echo
    cfg --list
    echo
    echo "  Events: +name to add, -name to remove, 'none' for core only. Enter = no change."
    read -r -p "  Events: " ev || true
    [ -z "${ev//[[:space:]]/}" ] || flags+=(--events "$ev")
    read -r -p "  Agents (claude,codex,... or *; Enter = no change): " ag || true
    [ -z "${ag//[[:space:]]/}" ] || flags+=(--agents "$ag")
    echo "  Statuses: done,idle,blocked (default) or done,blocked = only while you're not looking at the pane."
    read -r -p "  Statuses (Enter = no change): " stt || true
    [ -z "${stt//[[:space:]]/}" ] || flags+=(--statuses "$stt")
    read -r -p "  Debounce seconds (Enter = no change): " db || true
    [ -z "${db//[[:space:]]/}" ] || flags+=(--debounce "$db")
    echo "  Pane output: send the last N lines of the agent's pane with each notification."
    echo "  Off by default. Terminal output can contain secrets and is sent to your routine."
    read -r -p "  Output lines (0 = off; Enter = no change): " ol || true
    [ -z "${ol//[[:space:]]/}" ] || flags+=(--output-lines "$ol") ;;
esac

if [ ${#flags[@]} -gt 0 ]; then
  cfg "${flags[@]}" || echo "Setup did not finish: see the message above. Your previous settings are unchanged."
else
  echo "Nothing changed."
fi
unset GROKBOT_WEBHOOK_URL GROKBOT_WEBHOOK_AUTH

read -r -p "Send a test webhook now? [y/N] " ans || true
case "${ans:-}" in [Yy]*) cfg --test || true ;; esac
if [ -n "${HERDR_PLUGIN_ID:-}" ]; then read -r -p "Press Enter to close." _ || true; fi
