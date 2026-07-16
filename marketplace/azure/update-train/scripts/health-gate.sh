#!/usr/bin/env bash
# Health gate for one EdSpace instance after an update.
#
# Polls /health until it returns 200 (10-minute budget — migrations run on
# boot and the startup probe alone allows 5), then asserts /version reports
# the expected GIT_SHA.
#
# Usage: health-gate.sh <fqdn> [expected-git-sha]
set -euo pipefail

FQDN="${1:?usage: $0 <fqdn> [expected-git-sha]}"
EXPECTED_SHA="${2:-}"
BUDGET_SECONDS=600
INTERVAL=10

deadline=$(( $(date +%s) + BUDGET_SECONDS ))
echo "   health gate: https://${FQDN}/health (budget ${BUDGET_SECONDS}s)"

until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${FQDN}/health" || true)" = "200" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "   /health did not return 200 within budget" >&2
    exit 1
  fi
  sleep "$INTERVAL"
done
echo "   /health OK"

if [ -n "$EXPECTED_SHA" ]; then
  actual=$(curl -s --max-time 10 "https://${FQDN}/version" || true)
  case "$actual" in
    *"$EXPECTED_SHA"*) echo "   /version OK ($EXPECTED_SHA)" ;;
    *)
      echo "   /version mismatch: expected '$EXPECTED_SHA', got '$actual'" >&2
      exit 1
      ;;
  esac
fi
