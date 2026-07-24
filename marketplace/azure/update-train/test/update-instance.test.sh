#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
SCRIPT="$ROOT/marketplace/azure/update-train/scripts/update-instance.sh"
INSTANCES="$ROOT/marketplace/azure/update-train/test/fixtures/instances.json"
MOCK_BIN="$ROOT/marketplace/azure/update-train/test/bin"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export PATH="$MOCK_BIN:$PATH"
export MOCK_AZ_LOG="$TMP/az.log"
export EDSPACE_PUBLISHER_TENANT_ID=33333333-3333-3333-3333-333333333333
touch "$MOCK_AZ_LOG"

# A version-gate failure must roll the image back and return non-zero. This
# specifically guards the old piped-while subshell bug that returned success.
export MOCK_VERSION=wrong-sha
set +e
"$SCRIPT" --ring canary --instances "$INSTANCES" \
  --image registry.edspace.io/edspace/edspace:v2.0.0 \
  --expected-sha newsha >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 1 ]
[ "$(sed -n '1p' "$MOCK_AZ_LOG")" = "update registry.edspace.io/edspace/edspace:v2.0.0" ]
[ "$(sed -n '2p' "$MOCK_AZ_LOG")" = "update registry.edspace.io/edspace/edspace:v1.0.0" ]
echo "ok - failed health gate rolls back and fails the ring"

# Template mode must reconstruct every customer-controlled non-secret value,
# omit bootstrap secrets, and pass bootstrapSecrets=false separately.
: >"$MOCK_AZ_LOG"
unset MOCK_VERSION
EDSPACE_MAIN_TEMPLATE="$TMP/mainTemplate.json"
export EDSPACE_MAIN_TEMPLATE
printf '{}\n' >"$EDSPACE_MAIN_TEMPLATE"
"$SCRIPT" --ring canary --instances "$INSTANCES" --template \
  --image registry.edspace.io/edspace/edspace:v2.0.0 \
  --expected-sha newsha >/dev/null
grep -qx 'template-parameters-ok' "$MOCK_AZ_LOG"
echo "ok - template update preserves live parameters without secret rotation"

