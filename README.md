# EdSpace Self-Deploy

Deployment packaging for the EdSpace application, for customers running EdSpace in their own infrastructure.

There are three supported paths:

| Path | Audience | Where |
|---|---|---|
| **Helm chart** | Teams with a Kubernetes cluster (AKS, EKS, GKE, on-prem) | [`chart/edspace`](chart/edspace) — [install guide](docs/install-kubernetes.md) |
| **Azure Managed Application** | Turnkey Azure customers via the Azure Marketplace; EdSpace operates updates | [`marketplace/azure`](marketplace/azure) |
| **Deploy to Azure button** | Azure customers who deploy the same stack themselves and self-manage updates | [Quickstart (Azure — one-click)](#quickstart-azure--one-click) |
| **Docker Compose** | Pilots, evaluations, small single-host installs | [`compose/`](compose) — [install guide](docs/install-compose.md) |

## Requirements

- **Kubernetes**: 1.27+, an ingress controller, PostgreSQL ≥ 16.3 with the `vector` (pgvector), `citext`, and `pg_trgm` extensions available (or the bundled eval-only Postgres). See [docs/database.md](docs/database.md).
- **Compose**: a Docker host with ≥ 4 CPU / 8 GiB; Postgres is bundled.
- Registry access: images and the Helm chart are pulled from `edspace.azurecr.io` with the per-customer credentials you received from EdSpace (one token covers `docker login`, `helm registry login`, and Kubernetes pull secrets).

## Quickstart (Azure — one-click)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fteacherspace%2Fedspace-self-deploy%2Fmain%2Fmarketplace%2Fazure%2Fmanaged-app%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fteacherspace%2Fedspace-self-deploy%2Fmain%2Fmarketplace%2Fazure%2Fmanaged-app%2FcreateUiDefinition.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg)](http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Fteacherspace%2Fedspace-self-deploy%2Fmain%2Fmarketplace%2Fazure%2Fmanaged-app%2Fazuredeploy.json)

Deploys the same stack as the marketplace offer (Container Apps, PostgreSQL
Flexible Server, Key Vault, storage, optional Azure AI Foundry) into a resource
group **you** own — unlike the managed application, EdSpace does not operate
updates for you (update with `az containerapp update --image <new tag>`).

You will need:

- the `edspace.azurecr.io` registry credentials from your EdSpace welcome email,
- a way to send transactional email, or the decision not to: a [MailPace](https://mailpace.com) API key (default), an SMTP relay, or *Email backend: none* — all three are offered by the form and the template alike; see [docs/configuration.md](docs/configuration.md#transactional-email) for what each mode means,
- if enabling Azure AI: available Azure OpenAI GlobalStandard quota in the AI region you pick.
- if enabling Microsoft sign-in: an Entra app registration (tenant ID, client ID, client secret) — the form's *Sign-in* step explains the redirect URI to register; details in [marketplace/azure/managed-app/README.md](marketplace/azure/managed-app/README.md#deploy-from-the-cli-self-managed).

What gets deployed into your resource group:

- **Container Apps**: a workload-profiles environment and the `edspace` app (single replica, sized by *App size*)
- **PostgreSQL Flexible Server**: v16 with the extensions EdSpace needs; daily backups (retention and geo-redundancy are template parameters)
- **Key Vault** (`kv-eds-<suffix>`): holds all generated and supplied secrets — purge protection on, see [docs/limitations.md](docs/limitations.md) before deleting/redeploying
- **Storage account**: private `uploads` blob container for file storage
- **Log Analytics**: receives the app's console logs (30-day retention)
- **Azure AI Foundry** *(optional)*: AI account plus the 8 model deployments selectable in EdSpace's AI settings

After deployment succeeds:

1. Open the deployment's **Outputs** tab — `appUrl` is your instance's address (verify `GET /health` returns `ok`). If you set a custom domain, use `https://<appFqdn>` until EdSpace support has bound the domain; both addresses are accepted.
2. Bootstrap the first admin (no self-service signup exists — a fresh install has no account that can log in):

   ```sh
   az containerapp update -n edspace -g <resource-group> \
     --set-env-vars "EDSPACE_PLATFORM_ADMINS=admin@your-school.example"
   az containerapp exec -n edspace -g <resource-group> \
     --command 'bin/edspace rpc "Edspace.Accounts.AdminReconciler.bootstrap() |> IO.inspect(pretty: true)"'
   ```

   Then sign in at `appUrl` with that email. With MailPace or SMTP configured,
   enter the address on `/sign-in` to request a magic link. With **No email**,
   copy the returned `onboarding_links` URL over a trusted channel; it is valid
   for seven days and asks the admin to set a password. Full onboarding details:
   [CLIENT_GUIDE.md](CLIENT_GUIDE.md#manual-user-creation).
3. If you enabled Microsoft sign-in, make sure the `microsoftRedirectUri` output is registered in the Entra app registration's redirect URIs — the button will not work until it matches.
4. To update later: `az containerapp update -n edspace -g <resource-group> --image edspace.azurecr.io/edspace/edspace:<new tag>`.

Prefer the CLI over the portal? See "Deploy from the CLI" in
[`marketplace/azure/managed-app/README.md`](marketplace/azure/managed-app/README.md),
which ships an example parameters file.

The portal form is defined by
[`marketplace/azure/managed-app/createUiDefinition.json`](marketplace/azure/managed-app/createUiDefinition.json);
the template source is
[`mainTemplate.bicep`](marketplace/azure/managed-app/mainTemplate.bicep), and
[`azuredeploy.json`](marketplace/azure/managed-app/azuredeploy.json) is its
committed compiled copy (CI enforces freshness).

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
$EDITOR .env                              # set PHX_HOST, EDSPACE_IMAGE_TAG, LLM key, MAILER_*
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
make bicep-gen        # regenerate the committed azuredeploy.json (Deploy button)
make bicep-check      # verify azuredeploy.json is current (CI)
make compose-config   # validate compose.yaml with example env
```

Versioning: the repo git tag equals the chart version (semver). `Chart.yaml`'s `appVersion` records the app image tag the release was validated against and is the chart's default image tag. See `CHANGELOG.md` for per-release app compatibility.
