#!/usr/bin/env bash
# Discover EdSpace managed-app instances and print instance-registry JSON.
#
# Until the marketplace notification endpoint feeds instances.json
# automatically, this discovers instances in tenants the CI identity can
# already reach.
#
# TODO(edspace): cross-tenant auth — this only sees tenants the current
# login can access. Long-term, the notification endpoint (Partner Center)
# appends {applicationId, tenantId, managedRg, plan, eventType} to a storage
# table and this script reads that instead.
#
# Usage: discover-instances.sh [tenant-id ...]
set -euo pipefail

TENANTS=("$@")
[ ${#TENANTS[@]} -eq 0 ] && TENANTS=("$(az account show --query tenantId -o tsv)")

echo '{"instances":['
first=1
for tenant in "${TENANTS[@]}"; do
  # az login --service-principal --tenant "$tenant" ...   # TODO(edspace)
  az managedapp list --query "[?contains(managedResourceGroupId, 'edspace') || plan.name != null]" -o json 2>/dev/null |
    jq -c --arg tenant "$tenant" '.[] | {
      name: .name,
      ring: "broad",
      tenantId: $tenant,
      subscriptionId: (.id | split("/")[2]),
      managedRg: (.managedResourceGroupId | split("/")[-1]),
      fqdn: (.outputs.appFqdn.value // ""),
      notes: ("discovered " + (now | strftime("%Y-%m-%d")))
    }' | while read -r line; do
      [ "$first" = 1 ] && first=0 || printf ','
      printf '%s\n' "$line"
    done
done
echo ']}'
