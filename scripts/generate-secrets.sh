#!/usr/bin/env sh
# Prints the app's required random secrets in .env format.
# Usage: scripts/generate-secrets.sh >> compose/.env
set -eu

printf 'SECRET_KEY_BASE=%s\n' "$(openssl rand -base64 64 | tr -d '\n=' | cut -c1-64)"
printf 'TOKEN_SIGNING_SECRET=%s\n' "$(openssl rand -base64 48 | tr -d '\n=')"
printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 16)"
# Only needed for multi-node Kubernetes deployments (secrets.releaseCookie):
printf '# RELEASE_COOKIE=%s\n' "$(openssl rand -base64 32 | tr -d '\n=+/')"
