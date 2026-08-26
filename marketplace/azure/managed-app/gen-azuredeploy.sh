#!/usr/bin/env bash
# Generate (or verify) the committed azuredeploy.json and update.json that the
# README's "Deploy to Azure" and "Update EdSpace" buttons serve via
# raw.githubusercontent.com.
#
# Usage: ./gen-azuredeploy.sh [--check]
#
# Default: build the template (image pin from container-image.txt) and copy
# it to azuredeploy.json for committing. --check rebuilds and fails if the
# committed copy is stale — same convention as scripts/gen.py --check.
#
# The diff is semantic (sorted keys, metadata._generator stripped at every
# nesting level): bicep stamps its own version and a templateHash into
# _generator, both at the top level and inside each module's nested
# deployment, so a byte comparison would fail on every bicep upgrade even
# when the template is unchanged.
set -euo pipefail
cd "$(dirname "$0")"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

./build.sh --no-zip >/dev/null

normalize() {
  jq -S 'walk(if type == "object" then del(._generator) else . end)' "$1"
}

if [ "$CHECK" = 1 ]; then
  if ! diff <(normalize dist/mainTemplate.json) <(normalize azuredeploy.json); then
    echo "azuredeploy.json is stale — run 'make bicep-gen' and commit the result" >&2
    exit 1
  fi
  if ! diff <(normalize dist/update.json) <(normalize update.json); then
    echo "update.json is stale — run 'make bicep-gen' and commit the result" >&2
    exit 1
  fi
  echo "azuredeploy.json and update.json are current"
else
  cp dist/mainTemplate.json azuredeploy.json
  cp dist/update.json update.json
  echo "wrote azuredeploy.json ($(jq -r '.parameters.containerImage.defaultValue' azuredeploy.json))"
  echo "wrote update.json ($(jq -r '.parameters.containerImage.defaultValue' update.json))"
fi
