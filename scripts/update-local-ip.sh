#!/usr/bin/env bash
# Auto-detect Mac local IP and update RemClaw debug + local dev URLs.
# Run from repo root: ./scripts/update-local-ip.sh
# Other devs run this once to set their LAN IP everywhere.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/RemClaw/.env.Debug.xcconfig"
BACKEND_ENV="$REPO_ROOT/backend/.env.local"

get_local_ip() {
  local ip=""
  ip=$(ipconfig getifaddr en0 2>/dev/null || true)
  if [ -z "$ip" ]; then
    ip=$(ipconfig getifaddr en1 2>/dev/null || true)
  fi
  if [ -z "$ip" ]; then
    ip=$(ifconfig | awk '/inet / && $2 != "127.0.0.1" { print $2; exit }')
  fi
  echo "$ip"
}

LOCAL_IP="${1:-$(get_local_ip)}"

if [ -z "$LOCAL_IP" ]; then
  echo "warning: could not detect local IP address" >&2
  exit 0
fi

TEMP_DIR="${TEMP_DIR:-/tmp}"
UPDATED=()

# 1. RemClaw/.env.Debug.xcconfig — API_BASE_URL for iOS app
if [ -f "$CONFIG_FILE" ]; then
  TEMP_FILE="$TEMP_DIR/remclaw.env.Debug.xcconfig.$$"
  EMPTY_VAR_STR='$()'
  if awk -v ip="$LOCAL_IP" -v empty_var="$EMPTY_VAR_STR" '
    /^API_BASE_URL = / {
      print "API_BASE_URL = http:/" empty_var "/" ip ":3000"
      next
    }
    { print }
  ' "$CONFIG_FILE" > "$TEMP_FILE" 2>/dev/null && mv "$TEMP_FILE" "$CONFIG_FILE" 2>/dev/null; then
    UPDATED+=("API_BASE_URL in RemClaw/.env.Debug.xcconfig")
  else
    rm -f "$TEMP_FILE"
  fi
fi

# 2. backend/.env.local — LOCAL_GATEWAY_URL so backend returns device-reachable gateway
if [ -f "$BACKEND_ENV" ] && grep -q '^LOCAL_GATEWAY_URL=' "$BACKEND_ENV" 2>/dev/null; then
  TEMP_BACKEND="$TEMP_DIR/remclaw.backend.env.local.$$"
  if awk -v ip="$LOCAL_IP" '
    /^LOCAL_GATEWAY_URL=/ { print "LOCAL_GATEWAY_URL=http://" ip ":8080"; next }
    { print }
  ' "$BACKEND_ENV" > "$TEMP_BACKEND" 2>/dev/null && mv "$TEMP_BACKEND" "$BACKEND_ENV" 2>/dev/null; then
    rm -f "$TEMP_BACKEND"
    UPDATED+=("LOCAL_GATEWAY_URL in backend/.env.local")
  fi
fi

if [ ${#UPDATED[@]} -gt 0 ]; then
  echo "Updated to http://$LOCAL_IP: ${UPDATED[*]}"
else
  echo "No updates needed (IP: $LOCAL_IP)"
fi
