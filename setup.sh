#!/usr/bin/env bash
# Grok Bot Notify - interactive setup.
# Prompts for the Grok Bot routine webhook URL and Authorization header
# (input is hidden) and writes them to <plugin config dir>/.env with mode 600.
# Usage: setup.sh [--config-dir DIR] [--plugin-id ID]
set -euo pipefail

PLUGIN_ID="grokbot-notify"
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --config-dir) CONFIG_DIR="$2"; shift 2 ;;
    --plugin-id)  PLUGIN_ID="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
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

echo "Grok Bot Notify setup"
echo "Config file: $CONFIG_FILE"
echo "Paste values from your Grok Bot routine's webhook trigger. Input is hidden."
echo

read -r -s -p "Webhook URL: " url; echo
url="${url//[[:space:]]/}"
case "$url" in https://*) ;; *) echo "Expected an https:// URL. Nothing written." >&2; exit 1 ;; esac

read -r -s -p "Authorization header (e.g. 'Bearer ...' or 'Authorization: Bearer ...'): " auth; echo
auth="${auth#"${auth%%[![:space:]]*}"}"; auth="${auth%"${auth##*[![:space:]]}"}"
[ -n "$auth" ] || { echo "Authorization value is empty. Nothing written." >&2; exit 1; }
case "$url$auth" in *[\"\\]*) echo "Values must not contain quotes or backslashes. Nothing written." >&2; exit 1 ;; esac

mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR" 2>/dev/null || true
tmp="$(umask 077; mktemp "$CONFIG_DIR/.env.XXXXXX")"
{
  echo "# Written by grokbot-notify setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Keep private."
  printf 'GROKBOT_WEBHOOK_URL=%s\n' "$url"
  printf 'GROKBOT_WEBHOOK_AUTH=%s\n' "$auth"
  # keep any optional tuning lines from a previous config
  if [ -f "$CONFIG_FILE" ]; then
    grep -E '^(export )?GROKBOT_NOTIFY_[A-Z_]+=' "$CONFIG_FILE" || true
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
