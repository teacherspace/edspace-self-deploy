#!/usr/bin/env bash
# Build the Azure Marketplace managed-application package.
#
# Usage: ./build.sh [--no-zip]
#
# Produces dist/mainTemplate.json (+ UI/view definitions) and, unless
# --no-zip, dist/edspace-managed-app.zip with all files at the ZIP ROOT —
# a nested folder inside the zip is a classic marketplace packaging failure.
set -euo pipefail
cd "$(dirname "$0")"

NO_ZIP=0
[ "${1:-}" = "--no-zip" ] && NO_ZIP=1

EDSPACE_CONTAINER_IMAGE=${EDSPACE_CONTAINER_IMAGE:?set a version-pinned EdSpace container image}
case "$EDSPACE_CONTAINER_IMAGE" in
  *:latest|*__EDSPACE_CONTAINER_IMAGE__*)
    echo "EDSPACE_CONTAINER_IMAGE must use an immutable release tag or digest" >&2
    exit 2
    ;;
esac
[[ $EDSPACE_CONTAINER_IMAGE =~ @sha256:[0-9a-fA-F]{64}$ || $EDSPACE_CONTAINER_IMAGE =~ :[^/]+$ ]] || {
  echo "EDSPACE_CONTAINER_IMAGE must include a release tag or sha256 digest" >&2
  exit 2
}

rm -rf dist
mkdir -p dist

echo "== az bicep build"
az bicep build --file mainTemplate.bicep --outfile dist/mainTemplate.json

# The release image must be fixed in the package, never requested from
# customers and never left as a runnable placeholder.
PATCHED_TEMPLATE=$(mktemp)
trap 'rm -f "${PATCHED_TEMPLATE:-}"' EXIT
jq --arg image "$EDSPACE_CONTAINER_IMAGE" \
  '.parameters.containerImage.defaultValue = $image' \
  dist/mainTemplate.json > "$PATCHED_TEMPLATE"
mv "$PATCHED_TEMPLATE" dist/mainTemplate.json
PATCHED_TEMPLATE=""
if grep -Eq '__[A-Z0-9_]+__' dist/mainTemplate.json; then
  echo "compiled template still contains an unreplaced publisher token" >&2
  exit 2
fi

echo "== validating JSON assets"
python3 -m json.tool createUiDefinition.json >/dev/null
python3 -m json.tool viewDefinition.json >/dev/null
cp createUiDefinition.json viewDefinition.json dist/

if [ "$NO_ZIP" = 0 ]; then
  echo "== packaging zip (files at zip root)"
  (cd dist && zip -X -q edspace-managed-app.zip mainTemplate.json createUiDefinition.json viewDefinition.json)
  unzip -l dist/edspace-managed-app.zip
fi

cat <<'EOF'

Package built. Before submitting to Partner Center, also run:
  * ARM-TTK:      Test-AzTemplate -TemplatePath ./dist   (PowerShell; marketplace certification runs these)
  * UI sandbox:   https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/SandboxBlade
  * Service Catalog end-to-end: test/service-catalog-deploy.sh
EOF
