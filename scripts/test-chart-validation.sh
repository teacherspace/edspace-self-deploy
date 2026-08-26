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

expect_render_contains() {
  local name=$1
  local expected=$2
  shift 2
  if ! helm template edspace "$CHART" "$@" >/tmp/edspace-chart-test.log 2>&1; then
    echo "FAIL (expected render): $name" >&2
    cat /tmp/edspace-chart-test.log >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" /tmp/edspace-chart-test.log; then
    echo "FAIL (render missing '$expected'): $name" >&2
    exit 1
  fi
  echo "ok - $name"
}

expect_render_count() {
  local name=$1
  local expected_count=$2
  local expected=$3
  shift 3
  if ! helm template edspace "$CHART" "$@" >/tmp/edspace-chart-test.log 2>&1; then
    echo "FAIL (expected render): $name" >&2
    cat /tmp/edspace-chart-test.log >&2
    exit 1
  fi
  local actual_count
  actual_count=$(grep -Fc -- "$expected" /tmp/edspace-chart-test.log || true)
  if [ "$actual_count" -ne "$expected_count" ]; then
    echo "FAIL (expected $expected_count occurrences of '$expected', got $actual_count): $name" >&2
    exit 1
  fi
  echo "ok - $name"
}

trap 'rm -f /tmp/edspace-chart-test.log' EXIT

expect_pass "minimal external install" "${VALID[@]}"
expect_fail "missing database password" "${VALID[@]}" --set-string db.password=
expect_fail "missing LLM credential" "${VALID[@]}" --set-string llm.apiKey=
expect_fail "missing MailPace credential" "${VALID[@]}" --set-string mailer.mailpaceApiKey=
expect_fail "missing verified mail sender" "${VALID[@]}" --set-string mailer.fromEmail=

# Transactional email is optional (app docs/email.md): `none` must install with
# no credential and no sender, while `smtp` moves the credential requirement
# onto the relay rather than dropping it.
NO_MAIL=(
  --set-string app.host=edspace.example.org
  --set-string db.host=postgres.internal
  --set-string db.password=ci-db-password
  --set-string llm.provider=openai
  --set-string llm.apiKey=ci-llm-key
  --set-string mailer.adapter=none
)
SMTP=(
  --set-string app.host=edspace.example.org
  --set-string db.host=postgres.internal
  --set-string db.password=ci-db-password
  --set-string llm.provider=openai
  --set-string llm.apiKey=ci-llm-key
  --set-string mailer.adapter=smtp
  --set-string mailer.fromEmail=noreply@example.org
  --set-string mailer.smtp.relay=smtp.example.org
  --set-string mailer.smtp.username=teacher
  --set-string mailer.smtp.password=ci-smtp-password
)
expect_pass "email disabled without any mailer credential" "${NO_MAIL[@]}"
expect_pass "SMTP relay install" "${SMTP[@]}"
expect_pass "SMTP relay without authentication" "${SMTP[@]}" \
  --set-string mailer.smtp.username= --set-string mailer.smtp.password=
expect_pass "SMTP relay with a customer-managed password Secret" "${SMTP[@]}" \
  --set-string mailer.smtp.password= --set-string mailer.existingSecret=my-mailer
expect_fail "SMTP without a relay host" "${SMTP[@]}" --set-string mailer.smtp.relay=
expect_fail "SMTP without a verified sender" "${SMTP[@]}" --set-string mailer.fromEmail=
# The schema keeps extraEnv/extraEnvFrom as the escape hatch for the sender
# and relay (e.g. sourced from a customer-managed Secret), so the templates
# must not `required` them.
expect_pass "sender and relay supplied through extraEnv" "${SMTP[@]}" \
  --set-string mailer.fromEmail= --set-string mailer.smtp.relay= \
  --set-string 'extraEnv[0].name=MAILER_FROM_EMAIL' --set-string 'extraEnv[0].value=noreply@example.org' \
  --set-string 'extraEnv[1].name=MAILER_SMTP_RELAY' --set-string 'extraEnv[1].value=smtp.example.org'
# extraEnvFrom satisfies the same requirements, but only loosely: a schema
# cannot see inside a referenced Secret, so ANY non-empty list counts. An
# operator who uses extraEnvFrom for something unrelated therefore trades an
# install-time error for a boot failure -- documented in docs/configuration.md.
expect_pass "sender and relay assumed present behind extraEnvFrom" "${SMTP[@]}" \
  --set-string mailer.fromEmail= --set-string mailer.smtp.relay= \
  --set-string 'extraEnvFrom[0].secretRef.name=customer-mailer-env'
expect_fail "SMTP username without a password" "${SMTP[@]}" \
  --set-string mailer.smtp.username=teacher --set-string mailer.smtp.password=
# The mirror image. The app authenticates only when a username is set, so a
# lone password is dropped in silence -- the Azure template rejects the same
# pair (mainTemplate.bicep, mailSmtpUsernameChecked).
expect_fail "SMTP password without a username" "${SMTP[@]}" \
  --set-string mailer.smtp.username= --set-string mailer.smtp.password=ci-smtp-password
expect_fail "SMTP password Secret without a username" "${SMTP[@]}" \
  --set-string mailer.smtp.username= --set-string mailer.smtp.password= \
  --set-string mailer.existingSecret=my-mailer
expect_pass "SMTP username supplied through extraEnv" "${SMTP[@]}" \
  --set-string mailer.smtp.username= \
  --set-string 'extraEnv[0].name=MAILER_SMTP_USERNAME' --set-string 'extraEnv[0].value=teacher'
expect_render_count "SMTP CA Secret is mounted into app, migration, and seed pods" 3 \
  'secretName: customer-smtp-ca' "${SMTP[@]}" \
  --set seed.enabled=true \
  --set-string mailer.smtp.caCertSecret=customer-smtp-ca
expect_render_contains "SMTP CA Secret configures the mounted PEM path" \
  'MAILER_SMTP_CACERTFILE: "/etc/edspace/mailer-ca/ca.crt"' "${SMTP[@]}" \
  --set-string mailer.smtp.caCertSecret=customer-smtp-ca
expect_fail "two SMTP CA sources" "${SMTP[@]}" \
  --set-string mailer.smtp.caCertSecret=customer-smtp-ca \
  --set-string mailer.smtp.caCertFile=/custom/image/ca.pem
expect_fail "unknown mailer adapter" "${VALID[@]}" --set-string mailer.adapter=sendgrid
expect_fail "development-only local adapter" "${VALID[@]}" --set-string mailer.adapter=local
expect_fail "invalid SMTP TLS mode" "${SMTP[@]}" --set-string mailer.smtp.tls=maybe
expect_fail "unknown structured value" "${VALID[@]}" --set-string llm.apKey=typo
expect_fail "unknown root value" "${VALID[@]}" --set typo=true
expect_fail "unknown probe value" "${VALID[@]}" --set probes.liveness.periodSecond=10
expect_fail "mutable latest image" "${VALID[@]}" --set-string image.tag=latest
expect_fail "duplicate structured env key" "${VALID[@]}" --set-string env.PHX_HOST=wrong.example
expect_fail "same key in env and envSecret" "${VALID[@]}" \
  --set-string env.LANGFUSE_ENVIRONMENT=production \
  --set-string envSecret.LANGFUSE_ENVIRONMENT=production
# The seconds/milliseconds reinterpretation: 5000 was a valid ms timeout and is
# now 5000 seconds, i.e. effectively no timeout at all. Rejected in both the
# bare and the quoted spelling, since only the bare form sees minimum/maximum.
expect_pass "LANGFUSE_TIMEOUT in seconds" "${VALID[@]}" --set env.LANGFUSE_TIMEOUT=2.5
expect_pass "LANGFUSE_TIMEOUT in seconds, quoted" "${VALID[@]}" --set-string env.LANGFUSE_TIMEOUT=5
expect_fail "LANGFUSE_TIMEOUT carried over from milliseconds" "${VALID[@]}" \
  --set env.LANGFUSE_TIMEOUT=5000
expect_fail "LANGFUSE_TIMEOUT carried over from milliseconds, quoted" "${VALID[@]}" \
  --set-string env.LANGFUSE_TIMEOUT=5000
expect_fail "invalid boolean env value" "${VALID[@]}" --set-string env.EDSPACE_SPEECH_ENABLED=banana
# Settings managed inside the application are outside the contract on purpose
# (`excluded:` in config/contract.yaml); the env/envSecret schema must not
# quietly accept them.
expect_fail "in-app setting supplied as env" "${VALID[@]}" --set-string env.EDSPACE_SPEECH_VOICE=da-DK-ChristelNeural
expect_fail "in-app setting supplied as env (purge tuning)" "${VALID[@]}" --set-string env.MEMBER_PURGE_GLOBAL_CAP=100
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

python3 scripts/test-conditional-requirements.py
