#!/usr/bin/env bash
# Body of the deployment script in update.bicep (inlined by loadTextContent).
# Runs inside the Azure CLI deployment-script container as the updater
# identity. Inputs: APP, RG, IMAGE. Writes outputs to $AZ_SCRIPTS_OUTPUT_PATH.
set -euo pipefail

echo "Updating container app '$APP' in '$RG' to $IMAGE"

# A role assignment made seconds ago is not always visible to ARM yet; the
# first calls can 403. Retry for a few minutes rather than fail the button.
for attempt in $(seq 1 12); do
  if PREV=$(az containerapp show -n "$APP" -g "$RG" \
      --query 'properties.template.containers[0].image' -o tsv 2>/dev/null); then
    break
  fi
  echo "waiting for role assignment to propagate ($attempt/12)"
  sleep 15
done
[ -n "${PREV:-}" ] || { echo "cannot read container app $APP in $RG" >&2; exit 1; }
echo "current image: $PREV"

az containerapp update -n "$APP" -g "$RG" --image "$IMAGE" -o none
LATEST=$(az containerapp show -n "$APP" -g "$RG" --query properties.latestRevisionName -o tsv)
echo "new revision: $LATEST"

# The startup probe allows 5 minutes of migrations (60 x 5 s), plus image
# pull. Poll well past that before calling it failed.
for attempt in $(seq 1 60); do
  STATE=$(az containerapp revision show -n "$APP" -g "$RG" --revision "$LATEST" \
    --query '[properties.runningState, properties.healthState]' -o tsv | tr '\n' ' ')
  echo "revision $LATEST: $STATE"
  case "$STATE" in
    *Running*Healthy*) break ;;
    *Failed*|*ActivationFailed*|*Degraded*)
      echo "revision $LATEST did not become healthy; the previous revision keeps serving." >&2
      az containerapp revision show -n "$APP" -g "$RG" --revision "$LATEST" \
        --query 'properties.runningStateDetails' -o tsv >&2 || true
      az containerapp replica list -n "$APP" -g "$RG" --revision "$LATEST" \
        --query '[].properties.containers[].runningStateDetails' -o tsv >&2 || true
      exit 1 ;;
  esac
  sleep 10
done
case "$STATE" in
  *Running*Healthy*) ;;
  *) echo "timed out waiting for revision $LATEST (last state: $STATE)" >&2; exit 1 ;;
esac

echo "update complete: $PREV -> $IMAGE"
jq -n --arg prev "$PREV" --arg new "$IMAGE" --arg rev "$LATEST" \
  '{previousImage: $prev, newImage: $new, revision: $rev}' > "$AZ_SCRIPTS_OUTPUT_PATH"
