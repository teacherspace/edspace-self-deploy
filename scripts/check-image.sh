#!/usr/bin/env bash
# Verify that the image pinned in container-image.txt exists in the registry.
#
# release-guard.sh can only check the *shape* of the pin; it runs in CI without
# registry access. This is the other half: the tag (or digest) must actually be
# there, or every Deploy-to-Azure / Update click ends in ImagePullBackOff —
# with the deployment itself reporting success, since ARM only sees the
# Container App resource, not the replica behind it. Run it before tagging.
#
# Usage: scripts/check-image.sh [image]     (default: the committed pin)
# Needs an `az login` with read access to the registry.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=${1:-$(tr -d '[:space:]' < marketplace/azure/managed-app/container-image.txt)}

REGISTRY=${IMAGE%%/*}                # edspace.azurecr.io
REGISTRY_NAME=${REGISTRY%%.*}        # edspace
REPO_REF=${IMAGE#*/}                 # edspace/edspace:1.0.2 | edspace/edspace@sha256:…
if [[ $REPO_REF == *@* ]]; then
  REPO=${REPO_REF%%@*}; REF=${REPO_REF#*@}
else
  REPO=${REPO_REF%%:*}; REF=${REPO_REF#*:}
fi

if az acr manifest show -r "$REGISTRY_NAME" -n "${REPO}:${REF}" -o none 2>/dev/null \
   || az acr manifest show -r "$REGISTRY_NAME" -n "${REPO}@${REF}" -o none 2>/dev/null; then
  echo "ok: $IMAGE exists"
  exit 0
fi

echo "MISSING: $IMAGE is not in $REGISTRY" >&2
echo "tags present in $REGISTRY/$REPO:" >&2
az acr repository show-tags -n "$REGISTRY_NAME" --repository "$REPO" --orderby time_desc --top 10 -o tsv >&2 || true
exit 1
