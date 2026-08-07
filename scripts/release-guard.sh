#!/usr/bin/env bash
# Preconditions a tag must meet to be releasable, shared by the two pipelines
# that enforce them.
#
# The GitHub Actions release workflow validates the tag; azure-pipelines-chart.yml
# publishes the artifact. They run in different systems, on the same tag, and
# both need the same answer. Inlining the rules twice is how they drift — the
# workflow would go on rejecting an unpinned appVersion long after the pipeline
# that actually pushes stopped checking, and the pipeline is the one whose
# opinion reaches the registry. Same reasoning as, and deliberately the same
# shape as, iac-registry's scripts/guard-parameters.sh.
#
# Usage: scripts/release-guard.sh <tag>
# Prints `version=` and `appVersion=` on stdout for the caller to read; failures
# go to stderr with a non-zero exit.
set -euo pipefail

cd "$(dirname "$0")/.."
CHART_YAML=chart/edspace/Chart.yaml

[ $# -eq 1 ] || { echo "Usage: $0 <tag>" >&2; exit 2; }
TAG=$1

# First match only. A second `version:` at column 0 would be malformed YAML, but
# reading the last one silently is the failure that gets released.
CHART_VERSION=$(awk '/^version:/{print $2; exit}' "$CHART_YAML")
APP_VERSION=$(awk -F'"' '/^appVersion:/{print $2; exit}' "$CHART_YAML")

# The git tag IS the chart version — it is what customers pass to
# `helm install --version`. A tag that disagrees with Chart.yaml publishes a
# chart that cannot be addressed by the tag it was released under.
if [ "v${CHART_VERSION}" != "$TAG" ]; then
  echo "Chart.yaml version ${CHART_VERSION} != tag ${TAG}" >&2
  exit 1
fi

# appVersion is both the default image tag and the app version this chart was
# validated against. Unpinned, a customer install resolves to whatever `latest`
# happens to be on the day they run it.
case "$APP_VERSION" in
  ""|latest|*dev*)
    echo "Refusing release with unpinned appVersion: ${APP_VERSION:-<empty>}" >&2
    exit 1
    ;;
esac

echo "version=${CHART_VERSION}"
echo "appVersion=${APP_VERSION}"
