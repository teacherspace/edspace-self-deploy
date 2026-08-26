#!/usr/bin/env sh
# Prints the app's required random secrets in .env format.
# Usage: scripts/generate-secrets.sh >> compose/.env
#
# Not idempotent: appending a second time adds duplicate keys (docker compose
# uses the last occurrence, so new values win — including POSTGRES_PASSWORD,
# which cannot be changed this way once the database volume is initialized;
# see docs/install-compose.md).
set -eu

printf 'SECRET_KEY_BASE=%s\n' "$(openssl rand -base64 64 | tr -d '\n=' | cut -c1-64)"
printf 'TOKEN_SIGNING_SECRET=%s\n' "$(openssl rand -base64 48 | tr -d '\n=')"
printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 16)"
# Only needed for multi-node Kubernetes deployments (secrets.releaseCookie):
printf '# RELEASE_COOKIE=%s\n' "$(openssl rand -base64 32 | tr -d '\n=+/')"
# First-run setup: open https://<PHX_HOST>/setup?token=<value> to create the first admin (valid 7 days)
printf 'EDSPACE_SETUP_TOKEN=%s\n' "$(date -u +%Y%m%d%H%M%S).$(openssl rand -hex 16)"
