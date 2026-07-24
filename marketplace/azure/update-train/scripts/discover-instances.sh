#!/usr/bin/env bash
# Discover EdSpace managed-app instances visible to the authorized publisher
# identity and print instance-registry JSON.
#
# Managed Application publisher access is projected from the publisher tenant
# onto each customer managed resource group. The script therefore stays logged
# into the publisher tenant, scans subscriptions visible to that identity, and
# accepts only managed RGs whose `edspace` Container App has EdSpace's exact
# publisher-owned product tag. It never guesses from names.
#
# Usage: EDSPACE_PUBLISHER_TENANT_ID=<guid> discover-instances.sh
set -euo pipefail

[ $# -eq 0 ] || { echo "usage: EDSPACE_PUBLISHER_TENANT_ID=<guid> $0" >&2; exit 2; }

PRODUCT_ID=edspace
PUBLISHER_TENANT=${EDSPACE_PUBLISHER_TENANT_ID:-}

die() { echo "error: $*" >&2; exit 2; }
valid_guid() {
  [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] &&
    [ "$1" != "00000000-0000-0000-0000-000000000000" ]
}

valid_guid "$PUBLISHER_TENANT" || die "EDSPACE_PUBLISHER_TENANT_ID must be a non-zero GUID"
CURRENT_TENANT=$(az account show --query tenantId -o tsv)
[ "$CURRENT_TENANT" = "$PUBLISHER_TENANT" ] || die \
  "Azure session tenant $CURRENT_TENANT is not publisher tenant $PUBLISHER_TENANT"

# Known instances keep their ring assignment across re-discovery; only new
# instances default to "broad".
REGISTRY="${EDSPACE_INSTANCE_REGISTRY:-$(dirname "$0")/../instances/instances.json}"
existing_ring() {
  [ -f "$REGISTRY" ] || return 0
  jq -r --arg rg "$1" --arg sub "$2" \
    '.instances[]? | select(.managedRg == $rg and .subscriptionId == $sub) | .ring' \
    "$REGISTRY" 2>/dev/null | head -n1
}

discover() {
while read -r account; do
  subscription=$(jq -r '.id' <<<"$account")
  customer_tenant=$(jq -r '.tenantId' <<<"$account")
  valid_guid "$subscription" || continue
  valid_guid "$customer_tenant" || continue
  az account set --subscription "$subscription"

  while read -r group; do
    rg=$(jq -r '.name' <<<"$group")
    managed_by=$(jq -r '.managedBy // ""' <<<"$group")
    jq -e '(.managedBy // "" | ascii_downcase | contains("/providers/microsoft.solutions/applications/"))' \
      <<<"$group" >/dev/null || continue

    app_json=$(az containerapp show -g "$rg" -n edspace -o json 2>/dev/null) || continue
    jq -e --arg product "$PRODUCT_ID" \
      '(.tags["edspace.io/product"] // "") == $product' \
      <<<"$app_json" >/dev/null || continue

    ring=$(existing_ring "$rg" "$subscription")
    jq -n \
      --arg name "$(basename "$managed_by")" \
      --arg ring "${ring:-broad}" \
      --arg tenant "$customer_tenant" \
      --arg subscription "$subscription" \
      --arg rg "$rg" \
      --arg fqdn "$(jq -r '.properties.configuration.ingress.fqdn // ""' <<<"$app_json")" \
      '{
        name: $name,
        ring: $ring,
        tenantId: $tenant,
        subscriptionId: $subscription,
        managedRg: $rg,
        fqdn: $fqdn,
        notes: ("discovered " + (now | strftime("%Y-%m-%d")))
      }'
  done < <(az group list --query '[?managedBy != null]' -o json | jq -c '.[]')
done < <(az account list --all --query "[?state=='Enabled'].{id:id,tenantId:tenantId}" -o json | jq -c '.[]')
}

out=$(discover | jq -s '{instances: .}')
printf '%s\n' "$out"
# update-instance.sh fails closed on an empty canary ring, so an all-broad
# registry stalls the train until one instance is promoted by hand.
jq -e 'any(.instances[]?; .ring == "canary")' <<<"$out" >/dev/null || \
  echo "warning: no canary-ring instance; assign ring=\"canary\" to at least one entry before running the update train" >&2
