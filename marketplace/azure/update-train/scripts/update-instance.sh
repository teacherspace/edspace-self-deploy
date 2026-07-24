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
# bootstrapSecrets=false (mandatory — true would rotate every secret); all
# other parameters are read back from the LIVE instance first, so a redeploy
# is a no-op apart from the intended template change.
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
MAIN_TEMPLATE=${EDSPACE_MAIN_TEMPLATE:-"$SCRIPT_DIR/../../managed-app/dist/mainTemplate.json"}
PARAMS_FILE=""

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  [ -z "$PARAMS_FILE" ] || rm -f "$PARAMS_FILE"
}
trap cleanup EXIT

die() {
  echo "error: $*" >&2
  exit 2
}

valid_guid() {
  [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] &&
    [ "$1" != "00000000-0000-0000-0000-000000000000" ]
}

# Marketplace managed-app deployments run in the publisher tenant. Partner
# Center projects the authorized publisher identity onto each customer MRG.
# Logging into customer tenants would use a different service principal and
# discard that managed-app authorization.
validate_publisher_session() {
  local expected=${EDSPACE_PUBLISHER_TENANT_ID:-}
  local current
  valid_guid "$expected" || die "EDSPACE_PUBLISHER_TENANT_ID must be a non-zero GUID"
  current=$(az account show --query tenantId -o tsv)
  [ "$current" = "$expected" ] || die \
    "Azure session tenant $current is not publisher tenant $expected"
}

# Value of one env var of the running app ("" when absent).
app_env() { # $1=app_json $2=var name
  jq -r --arg n "$2" \
    '[.properties.template.containers[0].env[] | select(.name == $n) | .value // ""][0] // ""' \
    <<<"$1"
}

# mainTemplate.bicep has required parameters with no defaults (mailFromEmail,
# registryUsername) and defaults that would RESET customer choices if omitted
# (appSize, customDomain, AI setup, PG sizing, ...). Read the current values
# from the live instance and emit an ARM parameters object. @secure() seeds
# and byoLlmApiKey are NOT needed: with bootstrapSecrets=false nothing writes
# to the vault, and the app keeps reading the existing vault secrets.
template_parameters() { # $1=managed rg -> parameters JSON on stdout
  local rg=$1 app_json ai_json pg_json fqdn phx_host custom_domain app_size
  local registry_server registry_username mail_from mail_name speech_env
  local tags
  local pg_sku_name pg_sku_tier pg_storage_gb
  local storage_sku enable_ai='false' ai_location='swedencentral'
  local cap_text=50 cap_small=50 cap_embed=100
  local version_text='' version_small='' version_embed=''
  local byo_base_url='' byo_text='' byo_small='' byo_embed='' byo_api_version=''

  app_json=$(az containerapp show -g "$rg" -n edspace -o json)
  fqdn=$(jq -r '.properties.configuration.ingress.fqdn' <<<"$app_json")
  phx_host=$(app_env "$app_json" PHX_HOST)
  [ -n "$fqdn" ] && [ "$fqdn" != "null" ] || die "instance $rg has no Container App FQDN"
  [ -n "$phx_host" ] || die "instance $rg has no PHX_HOST"
  custom_domain=$([ "$phx_host" = "$fqdn" ] && echo "" || echo "$phx_host")
  app_size=$(jq -r 'if .properties.template.containers[0].resources.cpu >= 2
                    then "large" else "standard" end' <<<"$app_json")
  tags=$(jq -c '.tags // {}' <<<"$app_json")
  registry_server=$(jq -r '.properties.configuration.registries[0].server // ""' <<<"$app_json")
  registry_username=$(jq -r '.properties.configuration.registries[0].username // ""' <<<"$app_json")
  mail_from=$(app_env "$app_json" MAILER_FROM_EMAIL)
  mail_name=$(app_env "$app_json" MAILER_FROM_NAME)
  speech_env=$(app_env "$app_json" EDSPACE_SPEECH_ENABLED)

  ai_json=$(az cognitiveservices account list -g "$rg" \
    --query "[?kind=='AIServices' && starts_with(name, 'aif-edspace-')] | [0]" -o json)
  if [ "$ai_json" != "null" ] && [ -n "$ai_json" ]; then
    enable_ai='true'
    ai_location=$(jq -r '.location' <<<"$ai_json")
    local deployments
    deployments=$(az cognitiveservices account deployment list -g "$rg" \
      -n "$(jq -r '.name' <<<"$ai_json")" -o json)
    cap() { jq --arg n "$1" --argjson d "$2" \
      '[.[] | select(.name == $n) | .sku.capacity][0] // $d' <<<"$deployments"; }
    model_version() { jq -r --arg n "$1" \
      '[.[] | select(.name == $n) | .properties.model.version // ""][0] // ""' \
      <<<"$deployments"; }
    cap_text=$(cap 'gpt-5.4' 50)
    cap_small=$(cap 'gpt-5-mini' 50)
    cap_embed=$(cap 'text-embedding-3-small' 100)
    version_text=$(model_version 'gpt-5.4')
    version_small=$(model_version 'gpt-5-mini')
    version_embed=$(model_version 'text-embedding-3-small')
  else
    byo_base_url=$(app_env "$app_json" EDSPACE_LLM_BASE_URL)
    byo_text=$(app_env "$app_json" EDSPACE_LLM_TEXT_DEPLOYMENT)
    byo_small=$(app_env "$app_json" EDSPACE_LLM_SMALL_DEPLOYMENT)
    byo_embed=$(app_env "$app_json" EDSPACE_LLM_EMBEDDING_DEPLOYMENT)
    byo_api_version=$(app_env "$app_json" EDSPACE_LLM_API_VERSION)
  fi

  pg_json=$(az postgres flexible-server list -g "$rg" \
    --query "[?starts_with(name, 'pg-edspace-')] | [0]" -o json)
  storage_sku=$(az storage account list -g "$rg" \
    --query "[?starts_with(name, 'stedspace')] | [0].sku.name" -o tsv)
  [ "$pg_json" != "null" ] && [ -n "$pg_json" ] || die "instance $rg has no EdSpace PostgreSQL server"
  pg_sku_name=$(jq -r '.sku.name // ""' <<<"$pg_json")
  pg_sku_tier=$(jq -r '.sku.tier // ""' <<<"$pg_json")
  pg_storage_gb=$(jq -r '.storage.storageSizeGb // ""' <<<"$pg_json")
  [ -n "$pg_sku_name" ] || die "instance $rg PostgreSQL SKU name is missing"
  [ -n "$pg_sku_tier" ] || die "instance $rg PostgreSQL SKU tier is missing"
  [[ $pg_storage_gb =~ ^[0-9]+$ ]] || die "instance $rg PostgreSQL storage size is invalid"
  [ -n "$storage_sku" ] && [ "$storage_sku" != "null" ] || die "instance $rg has no EdSpace storage account"
  [ -n "$registry_server" ] || die "instance $rg has no configured registry server"
  [ -n "$registry_username" ] || die "instance $rg has no configured registry username"
  [ -n "$mail_from" ] || die "instance $rg has no configured MailPace sender"

  jq -n \
    --argjson tags "$tags" \
    --arg appSize "$app_size" \
    --arg customDomain "$custom_domain" \
    --arg registryServer "$registry_server" \
    --arg registryUsername "$registry_username" \
    --arg mailFromEmail "$mail_from" \
    --arg mailFromName "${mail_name:-EdSpace}" \
    --argjson enableAzureAi "$enable_ai" \
    --arg aiLocation "$ai_location" \
    --argjson textModelCapacity "$cap_text" \
    --argjson smallModelCapacity "$cap_small" \
    --argjson embeddingModelCapacity "$cap_embed" \
    --arg textModelVersion "$version_text" \
    --arg smallModelVersion "$version_small" \
    --arg embeddingModelVersion "$version_embed" \
    --argjson enableSpeech "$([ "$speech_env" = "true" ] && echo true || echo false)" \
    --arg byoLlmBaseUrl "$byo_base_url" \
    --arg byoLlmTextDeployment "$byo_text" \
    --arg byoLlmSmallDeployment "$byo_small" \
    --arg byoLlmEmbeddingDeployment "$byo_embed" \
    --arg byoLlmApiVersion "$byo_api_version" \
    --arg pgSkuName "$pg_sku_name" \
    --arg pgSkuTier "$pg_sku_tier" \
    --argjson pgStorageGB "$pg_storage_gb" \
    --arg storageSku "$storage_sku" \
    '[$ARGS.named | to_entries[] | {key: .key, value: {value: .value}}] | from_entries'
}

FAILED=0
COUNT=$(jq -r --arg ring "$RING" \
  '[.instances[] | select(.ring == $ring and (.name != null))] | length' "$INSTANCES")
echo "== ring '$RING': $COUNT instance(s)"
[ "$RING" != "canary" ] || [ "$COUNT" -gt 0 ] || die "canary ring is empty"

case "$IMAGE" in *:latest) die "refusing mutable image tag: $IMAGE" ;; esac
[[ $IMAGE =~ @sha256:[0-9a-fA-F]{64}$ || $IMAGE =~ :[^/]+$ ]] || die \
  "image must include a release tag or sha256 digest: $IMAGE"
validate_publisher_session

# NOTE: read from process substitution, NOT a pipe — a piped `while` runs in
# a subshell and FAILED would silently reset to 0 at the final exit.
while read -r inst; do
  name=$(jq -r '.name' <<<"$inst")
  tenant=$(jq -r '.tenantId' <<<"$inst")
  sub=$(jq -r '.subscriptionId' <<<"$inst")
  rg=$(jq -r '.managedRg' <<<"$inst")
  fqdn=$(jq -r '.fqdn' <<<"$inst")

  echo "== [$name] tenant=$tenant rg=$rg mode=$MODE"

  valid_guid "$sub" || die "[$name] invalid subscription id: $sub"
  [ -n "$rg" ] && [ "$rg" != "null" ] || die "[$name] managedRg is required"
  [ -n "$fqdn" ] && [ "$fqdn" != "null" ] || die "[$name] fqdn is required"
  valid_guid "$tenant" || die "[$name] invalid customer tenant id: $tenant"
  az account set --subscription "$sub"

  previous=$(az containerapp show -g "$rg" -n edspace \
    --query 'properties.template.containers[0].image' -o tsv)
  echo "   current image: $previous"

  if [ "$MODE" = "image" ]; then
    az containerapp update -g "$rg" -n edspace --image "$IMAGE" >/dev/null
  else
    [ -f "$MAIN_TEMPLATE" ] || { echo "build managed-app dist first"; exit 1; }
    PARAMS_FILE=$(mktemp)
    template_parameters "$rg" > "$PARAMS_FILE"
    # bootstrapSecrets=false is MANDATORY here — see managed-app/README.md.
    az deployment group create -g "$rg" \
      --template-file "$MAIN_TEMPLATE" \
      --parameters @"$PARAMS_FILE" \
      --parameters bootstrapSecrets=false containerImage="$IMAGE" >/dev/null
    rm -f "$PARAMS_FILE"
    PARAMS_FILE=""
  fi

  if ! "$SCRIPT_DIR/health-gate.sh" "$fqdn" "${EXPECTED_SHA:-}"; then
    echo "!! [$name] health gate FAILED — rolling back to $previous" >&2
    az containerapp update -g "$rg" -n edspace --image "$previous" >/dev/null || true
    FAILED=1
    break # halt the ring on first failure
  fi
  echo "   [$name] OK"
done < <(jq -c --arg ring "$RING" \
  '.instances[] | select(.ring == $ring and (.name != null))' "$INSTANCES")

exit "$FAILED"
