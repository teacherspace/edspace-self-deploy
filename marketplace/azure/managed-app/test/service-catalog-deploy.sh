#!/usr/bin/env bash
# End-to-end test of the managed-app package via Service Catalog —
# exercises the REAL managed-application machinery (deny assignments,
# publisher authorizations, createUiDefinition) without Partner Center.
#
# Prereqs: az login into a test subscription; ./build.sh already run.
#
# Usage:
#   ./service-catalog-deploy.sh <definition-rg> <storage-rg> <storage-account>
set -euo pipefail
cd "$(dirname "$0")/.."

DEF_RG="${1:?usage: $0 <definition-rg> <storage-rg> <storage-account>}"
STG_RG="${2:?}"
STG_ACCOUNT="${3:?}"

# The group lives in the publisher tenant and is the same authorization model
# configured on the Partner Center plan. Never publish a zero placeholder.
PUBLISHER_GROUP_OBJECT_ID="${PUBLISHER_GROUP_OBJECT_ID:?set the publisher operations group object id}"
[[ $PUBLISHER_GROUP_OBJECT_ID =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] &&
  [ "$PUBLISHER_GROUP_OBJECT_ID" != "00000000-0000-0000-0000-000000000000" ] || {
    echo "PUBLISHER_GROUP_OBJECT_ID must be a non-zero GUID" >&2
    exit 2
  }
# Owner: Contributor cannot write RBAC if a later template version needs it.
OWNER_ROLE_ID="8e3af657-a8ff-443c-a75c-2fe8c4bcb635"

ZIP=dist/edspace-managed-app.zip
[ -f "$ZIP" ] || { echo "run ./build.sh first"; exit 1; }

echo "== uploading package"
az storage container create -n managedapp --account-name "$STG_ACCOUNT" -g "$STG_RG" --auth-mode login >/dev/null
az storage blob upload --account-name "$STG_ACCOUNT" -c managedapp -f "$ZIP" -n edspace-managed-app.zip --overwrite --auth-mode login >/dev/null
EXPIRY=$(date -u -v+2H '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d '+2 hours' '+%Y-%m-%dT%H:%MZ')
SAS=$(az storage blob generate-sas --account-name "$STG_ACCOUNT" -c managedapp -n edspace-managed-app.zip \
  --permissions r --expiry "$EXPIRY" --auth-mode login --as-user -o tsv)
PACKAGE_URI="https://${STG_ACCOUNT}.blob.core.windows.net/managedapp/edspace-managed-app.zip?${SAS}"

echo "== creating managed-app definition"
az managedapp definition create \
  -g "$DEF_RG" \
  -n edspace \
  --display-name "EdSpace" \
  --description "EdSpace AI learning platform (test definition)" \
  --lock-level ReadOnly \
  --authorizations "${PUBLISHER_GROUP_OBJECT_ID}:${OWNER_ROLE_ID}" \
  --package-file-uri "$PACKAGE_URI"

cat <<'EOF'

Definition created. Next steps (manual, to exercise createUiDefinition):
  1. Portal -> Service Catalog Managed Application -> create "edspace";
     walk through every UI step and confirm the outputs.
  2. Or CLI (bypasses the UI):
       az managedapp create -g <consumer-rg> -n edspace-test \
         --kind ServiceCatalog \
         --managed-rg-id /subscriptions/<sub>/resourceGroups/mrg-edspace-test \
         --managedapp-definition-id $(az managedapp definition show -g <def-rg> -n edspace --query id -o tsv) \
         --parameters @test/parameters.test.json
  3. Verify: deny assignment blocks your customer identity in the managed RG;
     the publisher group can run `az containerapp update`;
     https://<appFqdn>/health returns 200 and /version returns the sha;
     re-deploy mainTemplate with -p bootstrapSecrets=false and confirm
     /version unchanged AND sessions survive (proves no secret rotation).
EOF
