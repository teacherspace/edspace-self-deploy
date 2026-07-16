# EdSpace self-deploy — maintainer tasks.
# Customers do not need make; generated files are committed.

CHART := chart/edspace
CI_VALUES := $(wildcard $(CHART)/ci/*.yaml)

.PHONY: gen check lint template package bicep compose-config clean

gen:
	uv run scripts/gen.py

check:
	uv run scripts/gen.py --check

lint:
	@for f in $(CI_VALUES); do \
		echo "== helm lint ($$f)"; \
		helm lint $(CHART) -f $$f || exit 1; \
	done

template:
	helm template edspace $(CHART) -f $(CHART)/ci/default-values.yaml

package: check lint
	mkdir -p dist
	helm package $(CHART) -d dist

bicep:
	cd marketplace/azure/managed-app && ./build.sh

compose-config:
	cd compose && cp -n .env.example .env.ci 2>/dev/null || true; \
		docker compose --env-file .env.ci config -q && rm -f .env.ci

clean:
	rm -rf dist marketplace/azure/managed-app/dist
