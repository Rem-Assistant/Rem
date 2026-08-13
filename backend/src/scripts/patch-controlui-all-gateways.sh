#!/bin/bash
# Patches all existing remclaw Fly gateways to add controlUi config settings.
# These settings are required for the backend to connect as openclaw-control-ui
# and approve device pairing requests (gateway v2026.2.25+).
#
# Usage: bash backend/src/scripts/patch-controlui-all-gateways.sh [--dry-run]
#
# This is a one-time migration script. New gateways get these settings
# automatically via buildGatewayConfigPatch() during deploy.

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "[patch-controlui] DRY RUN — no changes will be made"
fi

NODE_CMD='const fs=require("fs");const p="/data/.openclaw/openclaw.json";const c=JSON.parse(fs.readFileSync(p,"utf8"));const cu=c.gateway.controlUi||{};if(cu.dangerouslyDisableDeviceAuth&&cu.dangerouslyAllowHostHeaderOriginFallback){console.log("SKIP:already configured")}else{if(!c.gateway.controlUi)c.gateway.controlUi={};c.gateway.controlUi.dangerouslyDisableDeviceAuth=true;c.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback=true;fs.writeFileSync(p,JSON.stringify(c,null,2));console.log("PATCHED:"+JSON.stringify(c.gateway.controlUi))}'

APPS=$(fly apps list 2>/dev/null | grep -oE 'remclaw-[a-f0-9]{8}' || true)

if [[ -z "$APPS" ]]; then
  echo "[patch-controlui] No remclaw apps found"
  exit 0
fi

echo "[patch-controlui] Found apps:"
echo "$APPS" | while read -r app; do echo "  - $app"; done
echo ""

SUCCESS=0
FAILED=0
SKIPPED=0

while read -r APP; do
  echo -n "[patch-controlui] $APP: "

  if $DRY_RUN; then
    echo "would patch (dry-run)"
    SUCCESS=$((SUCCESS + 1))
    continue
  fi

  RESULT=$(fly ssh console -a "$APP" -C "node -e '$NODE_CMD'" 2>&1 | head -1)

  if echo "$RESULT" | grep -q "PATCHED:"; then
    echo "$RESULT"
    SUCCESS=$((SUCCESS + 1))
  elif echo "$RESULT" | grep -q "SKIP:"; then
    echo "already configured"
    SKIPPED=$((SKIPPED + 1))
  else
    echo "FAILED: $RESULT"
    FAILED=$((FAILED + 1))
  fi
done <<< "$APPS"

echo ""
echo "[patch-controlui] Done: success=$SUCCESS skipped=$SKIPPED failed=$FAILED"

if [[ $FAILED -gt 0 ]]; then
  exit 1
fi
