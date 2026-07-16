#!/usr/bin/env bash
# Update EdSpace managed-app instances in one ring.
#
# Routine (image-only) update:
#   update-instance.sh --ring canary --instances instances.json \
#     --image registry.edspace.io/edspace/edspace:v1.2.3 --expected-sha abc1234
#
# Infra (template) update — for template changes only:
#   update-instance.sh --ring canary --instances instances.json --template \
#     --image ... --expected-sha ...
#
# Image-only updates use `az containerapp update`: atomic revision swap and
# it CANNOT rotate secrets. Template mode redeploys mainTemplate.json with
# bootstrapSecrets=false (mandatory — true would rotate every secret).
#
# Rollback: re-run with the previous tag. Migrations are forward-only, so the
# release policy keeps each schema backward-compatible with the previous app
# version; anything beyond app-level rollback needs vendor intervention.
set -euo pipefail

RING="" INSTANCES="" IMAGE="" EXPECTED_SHA="" MODE="image"
while [ $# -gt 0 ]; do
  case "$1" in
    --ring) RING="$2"; shift 2 ;;
    --instances) INSTANCES="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --expected-sha) EXPECTED_SHA="$2"; shift 2 ;;
    --template) MODE="template"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$RING" ] && [ -n "$INSTANCES" ] && [ -n "$IMAGE" ] || {
  echo "usage: $0 --ring <canary|broad> --instances <file> --image <ref> [--expected-sha <sha>] [--template]" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN_TEMPLATE="$SCRIPT_DIR/../../managed-app/dist/mainTemplate.json"

FAILED=0
COUNT=$(jq -r --arg ring "$RING" '[.instances[] | select(.ring == $ring and (.name != null))] | length' "$INSTANCES")
echo "== ring '$RING': $COUNT instance(s)"

jq -c --arg ring "$RING" '.instances[] | select(.ring == $ring)' "$INSTANCES" | while read -r inst; do
  name=$(jq -r '.name' <<<"$inst")
  tenant=$(jq -r '.tenantId' <<<"$inst")
  sub=$(jq -r '.subscriptionId' <<<"$inst")
  rg=$(jq -r '.managedRg' <<<"$inst")
  fqdn=$(jq -r '.fqdn' <<<"$inst")

  echo "== [$name] tenant=$tenant rg=$rg mode=$MODE"

  # TODO(edspace): cross-tenant auth. With a multi-tenant SP consented in the
  # customer tenant:
  #   az login --service-principal -u "$CLIENT_ID" -p "$CLIENT_SECRET" --tenant "$tenant"
  az account set --subscription "$sub"

  previous=$(az containerapp show -g "$rg" -n edspace \
    --query 'properties.template.containers[0].image' -o tsv)
  echo "   current image: $previous"

  if [ "$MODE" = "image" ]; then
    az containerapp update -g "$rg" -n edspace --image "$IMAGE" >/dev/null
  else
    [ -f "$MAIN_TEMPLATE" ] || { echo "build managed-app dist first"; exit 1; }
    # bootstrapSecrets=false is MANDATORY here — see managed-app/README.md.
    az deployment group create -g "$rg" \
      --template-file "$MAIN_TEMPLATE" \
      --parameters bootstrapSecrets=false containerImage="$IMAGE" >/dev/null
  fi

  if ! "$SCRIPT_DIR/health-gate.sh" "$fqdn" "${EXPECTED_SHA:-}"; then
    echo "!! [$name] health gate FAILED — rolling back to $previous" >&2
    az containerapp update -g "$rg" -n edspace --image "$previous" >/dev/null || true
    FAILED=1
    break # halt the ring on first failure
  fi
  echo "   [$name] OK"
done

exit "$FAILED"
