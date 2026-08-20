# EdSpace Self-Deploy

Deployment packaging for the EdSpace application, for customers running EdSpace in their own infrastructure.

There are three supported paths:

| Path | Audience | Where |
|---|---|---|
| **Helm chart** | Teams with a Kubernetes cluster (AKS, EKS, GKE, on-prem) | [`chart/edspace`](chart/edspace) — [install guide](docs/install-kubernetes.md) |
| **Azure Managed Application** | Turnkey Azure customers via the Azure Marketplace; EdSpace operates updates | [`marketplace/azure`](marketplace/azure) |
| **Docker Compose** | Pilots, evaluations, small single-host installs | [`compose/`](compose) — [install guide](docs/install-compose.md) |

## Requirements

- **Kubernetes**: 1.27+, an ingress controller, PostgreSQL ≥ 16.3 with the `vector` (pgvector), `citext`, and `pg_trgm` extensions available (or the bundled eval-only Postgres). See [docs/database.md](docs/database.md).
- **Compose**: a Docker host with ≥ 4 CPU / 8 GiB; Postgres is bundled.
- Registry access: images and the Helm chart are pulled from `edspace.azurecr.io` with the per-customer credentials you received from EdSpace (one token covers `docker login`, `helm registry login`, and Kubernetes pull secrets).

## Quickstart (Kubernetes)

```sh
helm registry login edspace.azurecr.io -u <customer-user> -p <token>
helm install edspace oci://edspace.azurecr.io/edspace/charts/edspace \
  --version <chart-version> \
  --set app.host=edspace.example.org \
  --set registryCredentials.enabled=true \
  --set registryCredentials.username=<customer-user> \
  --set registryCredentials.password=<token> \
  --set db.bundled.enabled=true \
  --set llm.apiKey=<llm-api-key> \
  --set llm.baseUrl=https://<your-endpoint>.cognitiveservices.azure.com/ \
  --set llm.textDeployment=gpt-5.6-sol \
  --set llm.smallDeployment=gpt-5.6-luna \
  --set llm.embeddingDeployment=text-embedding-3-small \
  --set mailer.mailpaceApiKey=<mailpace-key> \
  --set mailer.fromEmail=noreply@example.org \
  --set ingress.tls.enabled=false \
  --wait --timeout 15m
```

This evaluation command uses HTTP ingress. Configure TLS, external Postgres,
and explicit secrets before production — see [docs/install-kubernetes.md](docs/install-kubernetes.md).

## Quickstart (Compose)

```sh
cd compose
cp .env.example .env
../scripts/generate-secrets.sh >> .env   # fills SECRET_KEY_BASE, POSTGRES_PASSWORD etc.
$EDITOR .env                              # set PHX_HOST, EDSPACE_IMAGE_TAG, LLM + MailPace keys
docker compose up -d
```

## Documentation

- [Kubernetes install](docs/install-kubernetes.md)
- [Compose install](docs/install-compose.md)
- [Configuration](docs/configuration.md) — how values map to app settings
- [Environment variable reference](docs/env-vars.md) *(generated)*
- [Database requirements](docs/database.md)
- [Operations](docs/operations.md) — upgrades, scaling, probes, backups
- [Known limitations](docs/limitations.md)

## Repository layout

```
config/contract.yaml     Single source of truth for all app environment variables.
scripts/gen.py           Generates .env.example, values.schema.json, docs/env-vars.md from the contract.
chart/edspace/           Customer-facing Helm chart (published as OCI).
compose/                 Docker Compose deployment.
marketplace/azure/       Azure Marketplace Managed Application (vendor-operated).
docs/                    Install and operations documentation.
```

## For maintainers

Generated files are committed; regenerate with `make gen` and CI enforces freshness (`make check`).

```sh
make gen              # regenerate .env.example / values.schema.json / docs/env-vars.md
make check            # verify generated files are current (CI)
make lint             # helm lint against all ci/ value sets
make test-validation  # chart value-guard test suite
make template         # render chart with default ci values
make package          # helm package to dist/
make bicep            # build the Azure managed-app template
make compose-config   # validate compose.yaml with example env
```

Versioning: the repo git tag equals the chart version (semver). `Chart.yaml`'s `appVersion` records the app image tag the release was validated against and is the chart's default image tag. See `CHANGELOG.md` for per-release app compatibility.
