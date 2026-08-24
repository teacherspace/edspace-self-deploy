# EdSpace self-deploy — maintainer tasks.
# Customers do not need make; generated files are committed.

CHART := chart/edspace
CI_VALUES := $(wildcard $(CHART)/ci/*.yaml)

.PHONY: gen check lint test-validation template package bicep bicep-gen bicep-check compose-config clean

gen:
	uv run scripts/gen.py

check:
	uv run scripts/gen.py --check

lint:
	@for f in $(CI_VALUES); do \
		echo "== helm lint ($$f)"; \
		helm lint $(CHART) -f $$f || exit 1; \
	done

test-validation:
	bash scripts/test-chart-validation.sh

template:
	helm template edspace $(CHART) -f $(CHART)/ci/default-values.yaml

package: check lint
	mkdir -p dist
	helm package $(CHART) -d dist

bicep:
	cd marketplace/azure/managed-app && ./build.sh

bicep-gen:
	cd marketplace/azure/managed-app && ./gen-azuredeploy.sh

bicep-check:
	cd marketplace/azure/managed-app && ./gen-azuredeploy.sh --check

# Mirrors the CI compose job (.env from the example plus the two values the
# ${VAR:?} guards require), in a scratch dir so a real compose/.env is untouched.
compose-config:
	@tmp=$$(mktemp -d) && cp compose/compose.yaml $$tmp/ && cp compose/.env.example $$tmp/.env && \
		printf 'POSTGRES_PASSWORD=make-dummy\nEDSPACE_IMAGE_TAG=v0.0.0-make\n' >> $$tmp/.env; \
		docker compose -f $$tmp/compose.yaml --project-directory $$tmp config -q; rc=$$?; \
		rm -rf $$tmp; exit $$rc

clean:
	rm -rf dist marketplace/azure/managed-app/dist
