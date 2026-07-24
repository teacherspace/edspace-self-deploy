#!/usr/bin/env bash
# Regression tests for install-time Helm validation. Every case here used to
# render a manifest that could not boot safely or could lose uploaded files.
set -euo pipefail

cd "$(dirname "$0")/.."
CHART=chart/edspace

VALID=(
  --set-string app.host=edspace.example.org
  --set-string db.host=postgres.internal
  --set-string db.password=ci-db-password
  --set-string llm.provider=openai
  --set-string llm.apiKey=ci-llm-key
  --set-string mailer.fromEmail=noreply@example.org
  --set-string mailer.mailpaceApiKey=ci-mail-key
)

expect_pass() {
  local name=$1
  shift
  if ! helm template edspace "$CHART" "$@" >/tmp/edspace-chart-test.log 2>&1; then
    echo "FAIL (expected pass): $name" >&2
    cat /tmp/edspace-chart-test.log >&2
    exit 1
  fi
  echo "ok - $name"
}

expect_fail() {
  local name=$1
  shift
  if helm template edspace "$CHART" "$@" >/tmp/edspace-chart-test.log 2>&1; then
    echo "FAIL (expected validation error): $name" >&2
    exit 1
  fi
  echo "ok - rejects $name"
}

trap 'rm -f /tmp/edspace-chart-test.log' EXIT

expect_pass "minimal external install" "${VALID[@]}"
expect_fail "missing database password" "${VALID[@]}" --set-string db.password=
expect_fail "missing LLM credential" "${VALID[@]}" --set-string llm.apiKey=
expect_fail "missing MailPace credential" "${VALID[@]}" --set-string mailer.mailpaceApiKey=
expect_fail "missing verified mail sender" "${VALID[@]}" --set-string mailer.fromEmail=
expect_fail "unknown structured value" "${VALID[@]}" --set-string llm.apKey=typo
expect_fail "unknown root value" "${VALID[@]}" --set typo=true
expect_fail "unknown probe value" "${VALID[@]}" --set probes.liveness.periodSecond=10
expect_fail "mutable latest image" "${VALID[@]}" --set-string image.tag=latest
expect_fail "duplicate structured env key" "${VALID[@]}" --set-string env.PHX_HOST=wrong.example
expect_fail "same key in env and envSecret" "${VALID[@]}" \
  --set-string env.LANGFUSE_ENVIRONMENT=production \
  --set-string envSecret.LANGFUSE_ENVIRONMENT=production
expect_fail "invalid boolean env value" "${VALID[@]}" --set-string env.DEBUG_AUTH_FAILURES=banana
expect_fail "Blob storage without a key source" "${VALID[@]}" \
  --set storage.adapter=azure_blob \
  --set-string storage.azureBlob.account=stedspace \
  --set-string storage.azureBlob.container=uploads
expect_fail "two replicas on ReadWriteOnce local storage" "${VALID[@]}" --set replicaCount=2
expect_fail "HPA scale-out on ReadWriteOnce local storage" "${VALID[@]}" --set autoscaling.enabled=true
expect_fail "surge rollout on ReadWriteOnce local storage" "${VALID[@]}" --set strategy.rollingUpdate.maxSurge=1
expect_fail "multiple replicas without clustering" "${VALID[@]}" \
  --set replicaCount=2 \
  --set clustering.enabled=false \
  --set storage.adapter=azure_blob \
  --set-string storage.azureBlob.account=stedspace \
  --set-string storage.azureBlob.container=uploads \
  --set-string storage.azureBlob.key=ci-blob-key
expect_fail "autoscaling minimum above maximum" "${VALID[@]}" \
  --set autoscaling.enabled=true \
  --set autoscaling.minReplicas=7 \
  --set autoscaling.maxReplicas=6 \
  --set storage.adapter=azure_blob \
  --set-string storage.azureBlob.account=stedspace \
  --set-string storage.azureBlob.container=uploads \
  --set-string storage.azureBlob.key=ci-blob-key
expect_fail "Azure provider without endpoint/deployments" "${VALID[@]}" --set-string llm.provider=azure
