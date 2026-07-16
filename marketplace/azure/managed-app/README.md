# EdSpace — Azure Managed Application

Marketplace package that provisions a complete EdSpace instance in a managed
resource group inside the customer's subscription: Container Apps environment
+ app, PostgreSQL Flexible Server, Blob storage, an instance Key Vault, and
(optionally) Azure AI Foundry with EdSpace's model deployments. EdSpace (the
publisher) retains operator access and rolls updates via the
[update train](../update-train/).

## Build

```sh
./build.sh            # dist/mainTemplate.json + createUiDefinition + view + zip
./build.sh --no-zip   # CI compile check
```

Also run before submission: ARM-TTK (`Test-AzTemplate -TemplatePath ./dist`),
the [createUiDefinition sandbox](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/SandboxBlade),
and the Service Catalog end-to-end test (`test/service-catalog-deploy.sh`).

## Secret model — read before touching anything

- On **first install** (`bootstrapSecrets=true`, pinned by createUiDefinition)
  the template generates `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET` and the PG
  admin password from `newGuid()` parameter defaults and persists them —
  along with the user-supplied MailPace key, registry token, and BYO LLM key —
  into the instance Key Vault (`kv-eds-<suffix>`).
- **Every consumer reads from the vault** via `getSecret()`; raw parameters
  are never used directly downstream.
- A Key Vault secret PUT always writes a new version, and `newGuid()` defaults
  re-evaluate on every deployment. Therefore:

| Operation | Mechanism | bootstrapSecrets |
|---|---|---|
| New install | Marketplace / Service Catalog | `true` (UI pins it) |
| Routine app update | `az containerapp update --image <tag>` (update train) | n/a — template untouched |
| Infra change to an existing instance | `az deployment group create` on the managed RG (update train) | **`false` — mandatory** |
| Marketplace definition version | New installs only — never pushed onto existing instances | — |

Re-deploying an existing instance with `bootstrapSecrets=true` **rotates every
generated secret** (all sessions/tokens invalidated, DB password changed).
Don't.

## Design notes

- `mainTemplate.bicep` is fully self-contained (marketplace requirement — no
  registry module references). Only two local modules exist, because
  `keyVault.getSecret()` is legal solely as a `@secure()` **module** parameter:
  `modules/postgres.bicep` (admin password) and `modules/containerApp.bicep`
  (all app secrets). Everything needing `listKeys()` on a *conditional*
  resource (AI account) stays top-level: a symbolic-name reference inside a
  ternary compiles to a lazily-evaluated ARM `if()`. Never route keys through
  module **outputs** — nested-deployment outputs land in deployment history.
- **Scale**: min=max=1 replica; scale vertically via `appSize`
  (standard 1 vCPU/2 GiB, large 2 vCPU/4 GiB — ACA enforces 1:2 pairs).
  Multi-replica needs Erlang clustering, out of scope on ACA (v1 limitation).
- **Probes**: startup `/health` with a 5-minute window (migrations run before
  the port binds), readiness `/health` (DB-coupled — correct traffic gate),
  liveness `tcpSocket` (a DB outage must not restart-loop the app).
- **Postgres**: v16, extensions allow-list `VECTOR,CITEXT,PG_TRGM`,
  `max_connections=100` (app pool: 30×2 + headroom). Network posture v1:
  public endpoint + `AllowAllAzureServicesAndResourcesWithinAzureIps` (ACA
  Consumption has no stable egress IP). Hardening path (v2, new instances
  only — PG network mode is immutable): VNet-integrated ACA + PG private
  access behind a `networkIsolation` parameter.
- **DATABASE_URL** is composed in `containerApp.bicep` with a
  `uriComponent()`-encoded password and `?ssl=true` (Azure PG enforces TLS).
  TODO(edspace): validate against the app's Postgrex TLS handling; fallback is
  a `require_secure_transport=off` server configuration until app-side DB TLS
  lands.
- **AI quota gotcha**: GlobalStandard model deployments draw on the
  *customer subscription's* quota in `aiLocation`. Deployment fails without
  quota — the UI warns and links the increase form; capacities are parameters.

## Custom domain runbook (publisher support)

`PHX_HOST` is set at install: the generated
`edspace.<env-default-domain>` FQDN, or the customer's `customDomain` if
supplied. Custom-domain *binding* can't complete in one ARM pass (async DNS
validation + the customer can't touch the managed RG):

1. Customer creates a CNAME `<domain> -> <appFqdn>` and TXT
   `asuid.<domain> -> <ACA custom domain verification id>`.
2. Support (publisher access):
   `az containerapp hostname add -g <managedRg> -n edspace --hostname <domain>`
   then bind an ACA managed certificate.

## Parameter ↔ app environment variable mapping

| Template parameter | App env var |
|---|---|
| `customDomain` (or generated FQDN) | `PHX_HOST`, `PHX_CHECK_ORIGIN` |
| `mailpaceApiKey` | `MAILPACE_API_KEY` |
| `mailFromEmail` / `mailFromName` | `MAILER_FROM_EMAIL` / `MAILER_FROM_NAME` |
| `byoLlmBaseUrl` / AI account endpoint | `EDSPACE_LLM_BASE_URL` |
| `byoLlmApiKey` / AI account key1 | `EDSPACE_LLM_API_KEY` |
| `byoLlm*Deployment` / fixed model names | `EDSPACE_LLM_{TEXT,SMALL,EMBEDDING}_DEPLOYMENT` |
| `byoLlmApiVersion` | `EDSPACE_LLM_API_VERSION` |
| `enableSpeech` (+ AI key/region) | `EDSPACE_SPEECH_ENABLED`, `AZURE_SPEECH_KEY`, `AZURE_SPEECH_REGION` |
| storage account (always deployed) | `AZURE_STORAGE_ACCOUNT`, `AZURE_STORAGE_CONTAINER`, `AZURE_STORAGE_KEY`, `EDSPACE_FILE_STORAGE_ADAPTER=azure_blob` |
| composed | `DATABASE_URL` |
| generated | `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET` |

Parameter names mirror the env vars (camelCase ↔ SCREAMING_SNAKE) so a future
`gen.py` check against `config/contract.yaml` stays mechanical.

## Open TODOs (grep `TODO(edspace)`)

- Publisher operations **group object id** (Key Vault access policy +
  definition authorizations) — use a group so operators rotate without
  republishing.
- **Partner Center**: account, Azure Application offer + Managed Application
  plan; upload the same zip; configure authorizations + notification endpoint
  (an Azure Function appending `{applicationId, tenantId, managedRg, plan,
  eventType}` to a storage table — feeds the update-train instance registry;
  required before GA).
- **Model catalog versions** for gpt-5.4 / gpt-5-mini / text-embedding-3-small
  (empty = platform default; pin before first publish).
- **Cross-tenant CI auth** for the update train — see update-train/README.
- Pin `containerImage` tag per definition version.
- Registry credential distribution flow to customers (welcome email vs
  automated provisioning).
