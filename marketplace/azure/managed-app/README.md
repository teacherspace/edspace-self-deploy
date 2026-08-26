# EdSpace — Azure Managed Application

Marketplace package that provisions a complete EdSpace instance in a managed
resource group inside the customer's subscription: Container Apps environment
+ app, PostgreSQL Flexible Server, Blob storage, an instance Key Vault, and
(optionally) Azure AI Foundry with EdSpace's model deployments. EdSpace (the
publisher) retains operator access and rolls updates from its internal release
tooling.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fteacherspace%2Fedspace-self-deploy%2Fmain%2Fmarketplace%2Fazure%2Fmanaged-app%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fteacherspace%2Fedspace-self-deploy%2Fmain%2Fmarketplace%2Fazure%2Fmanaged-app%2FcreateUiDefinition.json)

The button deploys the committed [`azuredeploy.json`](azuredeploy.json)
directly into a customer-owned resource group (self-managed — no managed-app
wrapper, no publisher access, customer runs their own updates). See the
root README's "Quickstart (Azure — one-click)".

## Deploy from the CLI (self-managed)

The same template deploys without the portal.
[`azuredeploy.parameters.json`](azuredeploy.parameters.json) is a starting
point — copy it, fill in the `REPLACE-…` values (registry credentials,
MailPace key, from-address), and never commit the filled-in copy anywhere:

```sh
az group create -n rg-edspace -l westeurope
az deployment group create -g rg-edspace \
  -f azuredeploy.json -p @my.parameters.json
```

**Choosing a mailer.** `mailerAdapter` is `mailpace` (the default), `smtp`, or
`none`:

- `smtp` — drop `mailpaceApiKey` and set `mailSmtpRelay`, plus
  `mailSmtpUsername`/`mailSmtpPassword` if the relay authenticates. For
  implicit TLS set `mailSmtpSsl: true` and `mailSmtpPort: 465`; otherwise the
  defaults give STARTTLS on 587 with the relay's certificate verified.
- `none` — drop `mailpaceApiKey` and `mailFromEmail` entirely. EdSpace only
  ever emails about account access, so a school whose users all arrive through
  SSO needs no provider; the app then offers a password form on `/sign-in` and
  shows each invitation's link to the inviting admin. There is no self-service
  password recovery in this mode — see the root
  [docs/limitations.md](../../../docs/limitations.md).

  For the first platform admin, run `Edspace.Accounts.AdminReconciler.bootstrap/0`
  as described in the root quickstart. In `none` mode it returns the initial
  seven-day onboarding link directly; no email-only install is left waiting for
  a password it has no way to create.

A missing credential fails the deployment (Key Vault rejects the empty value)
rather than installing an app that cannot send.

**Microsoft Entra ID sign-in.** Off by default. To enable it, first create an
app registration in your tenant (Entra admin center → App registrations → New):

1. Platform **Web**, redirect URI `https://<app host>/auth/microsoft/callback`.
   The `microsoftRedirectUri` output shows the exact value in either case
   (custom domain or generated host); with a custom domain it is known up
   front, otherwise deploy first and copy it from the outputs.
2. **Certificates & secrets** → new client secret; copy its *Value*.
3. **Token configuration** → add the optional `email` claim; **API
   permissions** → `openid`, `profile`, `email` (Microsoft Graph, delegated).

Then pass `enableMicrosoftSso: true`, `microsoftTenantId` (your Directory
(tenant) ID, or `organizations` for any work/school account),
`microsoftClientId` and `microsoftClientSecret`. The template composes
`MICROSOFT_REDIRECT_URI` from the app host itself. An enabled SSO with an empty
secret fails the deployment the same way a missing mailer credential does.

Enabling it on an existing instance without redeploying the template:

```sh
az containerapp secret set -n edspace -g rg-edspace \
  --secrets microsoft-client-secret=<value>
az containerapp update -n edspace -g rg-edspace --set-env-vars \
  MICROSOFT_TENANT_ID=<tenant-id> MICROSOFT_CLIENT_ID=<client-id> \
  MICROSOFT_CLIENT_SECRET=secretref:microsoft-client-secret \
  MICROSOFT_REDIRECT_URI=https://<app host>/auth/microsoft/callback
```

A later `az deployment group create` with `enableMicrosoftSso=false` would
strip those vars again, so also record the choice in your parameters file.
Rotate the secret before its Entra expiry with the same `secret set` command
(the running revision picks it up on the next restart).

Fresh installs use the default `bootstrapSecrets=true`. Infra changes to an
**existing** instance must add `-p bootstrapSecrets=false` — see the secret
model below; forgetting it rotates every generated secret.

## Build

```sh
./build.sh            # dist/mainTemplate.json + createUiDefinition + view + zip
./build.sh --no-zip   # compile/package check without the zip
```

The image baked into the template defaults to the pin in
[`container-image.txt`](container-image.txt); export
`EDSPACE_CONTAINER_IMAGE` to override it for a one-off build. Either way the
build refuses mutable `latest` or untagged references. Customers are never
asked for the image value.

Committed artifact: `azuredeploy.json` is the compiled, image-patched copy of
`mainTemplate.bicep` that the Deploy-to-Azure button serves from
raw.githubusercontent.com. Regenerate it with `make bicep-gen` after changing
the Bicep or `container-image.txt`; CI (`make bicep-check`) and the release
workflow enforce freshness, and `scripts/release-guard.sh` refuses tags with a
dev/floating pin.

ARM-TTK (the test suite marketplace certification runs) is enforced in CI on
every change, against both the built template and `createUiDefinition.json` —
one test is skipped there ("URIs Should Be Properly Constructed", a false
positive on the composed `appUrl`/`DATABASE_URL` values). Run it locally with
`Test-AzTemplate -TemplatePath ./dist`.

Also run before submission:
the [createUiDefinition sandbox](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/SandboxBlade),
and the Service Catalog end-to-end test (`test/service-catalog-deploy.sh`). The
test requires `PUBLISHER_GROUP_OBJECT_ID` for the publisher-tenant group that
will be authorized on the test definition; it rejects missing/zero values.

## Secret model — read before touching anything

- On **first install** (`bootstrapSecrets=true`, pinned by createUiDefinition)
  the template generates `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET` and the PG
  admin password from `newGuid()` parameter defaults and persists them —
  along with the user-supplied mailer credential, registry token, and BYO LLM
  key — into the instance Key Vault (`kv-eds-<suffix>`).
- `mailpace-api-key`, `smtp-password` and `microsoft-client-secret` are always
  created, holding an `unused-…` placeholder when their feature is not chosen
  (Key Vault rejects an empty value). The container app reads and binds only
  the ones its adapter / SSO choice uses.
- All three are created only under `bootstrapSecrets=true`, yet a redeploy
  with `bootstrapSecrets=false` still reads whichever its features need. An
  instance installed **before `smtp-password` / `microsoft-client-secret`
  existed** therefore has to seed them before a redeploy that enables SMTP
  authentication or Microsoft SSO, or the deployment fails with
  `SecretNotFound`:

  ```sh
  az keyvault secret set --vault-name kv-eds-<suffix> -n smtp-password --value '<smtp password>'
  az keyvault secret set --vault-name kv-eds-<suffix> -n microsoft-client-secret --value '<client secret>'
  ```

  (Pass an `unused-…` placeholder for a secret whose feature stays off.)
- The same applies, more quietly, to a secret that **exists but still holds
  its `unused-…` placeholder** — the state of any instance whose feature was
  off at install. A `bootstrapSecrets=false` redeploy does not rewrite
  secrets, so turning the feature on binds the placeholder as though it were
  the real credential: there is no `SecretNotFound`, the deployment succeeds,
  and SMTP authentication or the Entra token exchange then fails at runtime
  against a plausible-looking value. **Enabling SMTP authentication or
  Microsoft SSO on an existing instance therefore means setting the secret
  first**, with the same `az keyvault secret set` calls above, whether or not
  it already exists.
- **The container app reads every secret from the vault at runtime**, as ACA
  Key Vault references resolved by the instance's user-assigned identity
  (`id-edspace-<suffix>`, the vault's only data-plane principal). `DATABASE_URL`
  is therefore persisted as a composed `database-url` secret at bootstrap, next
  to the raw `pg-admin-password`. PostgreSQL receives the generated password
  directly on first install; a `bootstrapSecrets=false` redeploy omits it and
  the server keeps what it has. No `keyVault.getSecret()` anywhere: ARM resolves
  those at pre-flight validation, before the vault exists, so a fresh install
  would fail with `KeyVaultParameterReferenceNotFound`.
- Parameter combinations the portal form cannot produce, but a CLI or
  parameters-file deployment can, are rejected up front by `fail()` guards in
  `mainTemplate.bicep` (the `…Checked` variables): a missing sender, relay,
  MailPace key, Entra client ID or client secret, and an SMTP username and
  password supplied without each other. Guards on a credential that is written
  into the vault are gated on `bootstrapSecrets`, since a `false` redeploy is
  expected to leave that parameter empty.
- A Key Vault secret PUT always writes a new version, and `newGuid()` defaults
  re-evaluate on every deployment. Therefore:

| Operation | Mechanism | bootstrapSecrets |
|---|---|---|
| New install | Marketplace / Service Catalog | `true` (UI pins it) |
| Routine app update | `az containerapp update --image <tag>` | n/a — template untouched |
| Infra change to an existing instance | `az deployment group create` on the managed RG | **`false` — mandatory** |
| Marketplace definition version | New installs only — never pushed onto existing instances | — |

Re-deploying an existing instance with `bootstrapSecrets=true` **rotates every
generated secret** (all sessions/tokens invalidated, DB password changed).
Don't.

## Design notes

- `mainTemplate.bicep` is fully self-contained (marketplace requirement — no
  registry module references). Two local modules exist so that secret values
  cross into them only as `@secure()` inputs, which are not logged:
  `modules/postgres.bicep` (admin password) and `modules/containerApp.bicep`
  (storage / Azure AI keys; vault secrets are bound as Key Vault references
  and never enter the template). Everything needing `listKeys()` on a
  *conditional* resource (AI account) stays top-level: a symbolic-name
  reference inside a ternary compiles to a lazily-evaluated ARM `if()`. Never
  route keys through module **outputs** — nested-deployment outputs land in
  deployment history.
- **Scale**: min=max=1 replica; scale vertically via `appSize`
  (standard 1 vCPU/2 GiB, large 2 vCPU/4 GiB — ACA enforces 1:2 pairs).
  Multi-replica needs Erlang clustering, out of scope on ACA (v1 limitation).
- **Probes**: startup `/health` with a 5-minute window (migrations run before
  the port binds), readiness `/health` (DB-coupled — correct traffic gate),
  liveness `tcpSocket` (a DB outage must not restart-loop the app).
- **Postgres**: v16, extensions allow-list `VECTOR,CITEXT,PG_TRGM`.
  `max_connections` is left at the SKU default (B2s 429, D2ds_v5 859 — both
  clear the app pool's 30×2 + headroom; it's also a static parameter that
  would sit pending-restart if overridden). Network posture v1:
  public endpoint + `AllowAllAzureServicesAndResourcesWithinAzureIps` (ACA
  Consumption has no stable egress IP). Hardening path (v2, new instances
  only — PG network mode is immutable): VNet-integrated ACA + PG private
  access behind a `networkIsolation` parameter.
- **DATABASE_URL** is composed in `containerApp.bicep` with a
  `uriComponent()`-encoded password and `?ssl=true` (Azure PG enforces TLS).
  TODO(edspace): validate against the app's Postgrex TLS handling; fallback is
  a `require_secure_transport=off` server configuration until app-side DB TLS
  lands.
- **Model set is driven by the app, not by this template**: `Edspace.LLM.Models`
  (`lib/edspace/llm/models.ex`) is a hardcoded registry populating the school-admin
  text-model dropdown and the backoffice small-model default. Every deployment name
  in it must exist on the account, or an admin selecting it gets an
  unknown-deployment failure with nothing in the install explaining why. The
  template deploys all 8: `gpt-5.1`, `gpt-5.4`, `gpt-5.6-sol`, `gpt-5.6-terra`
  (text + small), `gpt-5.6-luna`, `gpt-5-mini`, `Mistral-Large-3`,
  `text-embedding-3-small`. Adding a model to the app registry means adding it here.
  `infrastructure/iac-ai-foundry` deploys the same set plus `gpt-5.5` and
  `text-embedding-3-large`; both are omitted here because no app code path reaches
  them and each would draw customer quota for nothing.
- **AI quota gotcha**: GlobalStandard model deployments draw on the
  *customer subscription's* quota in `aiLocation`. Deployment fails without
  quota — the UI warns and links the increase form; capacities are parameters.
  Quota is per-model, so 8 deployments means 8 buckets, not one shared pool.
  All 8 have a GlobalStandard bucket in `swedencentral`, verified live on
  2026-08-20 against both EdSpace subscriptions with
  `az cognitiveservices usage list -l swedencentral`. Note `Mistral-Large-3`
  quota lives under the `AIServices.` family, not `OpenAI.` — consistent with its
  `Mistral AI` format string. Observed limits there were 10,000 K-TPM per model
  (30,000 for `gpt-5.1`), all unallocated, which is what the template's modest
  per-model asks are sized against. A customer subscription may differ; SKU stays
  per-entry in `modelDeployments` so a region/SKU miss is a one-line fix.
- **Capacity is a per-request ceiling**, not only a throughput knob. A deployment
  at capacity N rejects any single request over N*1,000 tokens however long it
  waits, and the chat streamer parks instead of erroring. Internal production hit
  this on 2026-07-31 at capacity 50 (a turn with a 23 MB PDF was ~127 K tokens).
  Defaults are 800 K-TPM chat / 200 small / 100 embedding. 800 is derived, not
  guessed: `ContextRag.Budget` bounds one turn at 400 K reference + 1.2 M history
  + ~122 K tool chars, which at its 2.7 chars/token ratio is ~654 K input tokens
  plus up to 128 K reserved output — ~780 K-TPM for a single worst-case turn.
  Lower values narrow the hang window rather than closing it.
- **Publisher access** is configured as a Partner Center plan authorization,
  not as a customer Key Vault policy. Managed-app operations use the
  publisher-tenant identity's projected control-plane access to the managed
  resource group. The vault intentionally grants no permanent publisher data-
  plane access; its only access policy is `secrets/get` for the app's
  user-assigned identity.

## Custom domain runbook (publisher support)

`PHX_HOST` is set at install: the generated
`edspace.<env-default-domain>` FQDN, or the customer's `customDomain` if
supplied. With a custom domain, `PHX_CHECK_ORIGIN` allows **both** hosts, so
the instance stays usable (WebSockets included) at the generated address —
the `appFqdn` output — until the domain is bound; only links the app
generates itself (emails, the Microsoft redirect URI, `appUrl`) use the custom
domain from the start. Custom-domain *binding* can't complete in one ARM pass
(async DNS validation + the customer can't touch the managed RG):

1. Customer creates a CNAME `<domain> -> <appFqdn>` and TXT
   `asuid.<domain> -> <ACA custom domain verification id>`.
2. Support (publisher access):
   `az containerapp hostname add -g <managedRg> -n edspace --hostname <domain>`
   then bind an ACA managed certificate.

## Parameter ↔ app environment variable mapping

| Template parameter | App env var |
|---|---|
| `customDomain` (or generated FQDN) | `PHX_HOST`; `PHX_CHECK_ORIGIN` (custom domain **and** generated FQDN when a custom domain is set) |
| `mailerAdapter` | `MAILER_ADAPTER` |
| `mailpaceApiKey` | `MAILPACE_API_KEY` (adapter `mailpace` only) |
| `mailFromEmail` / `mailFromName` | `MAILER_FROM_EMAIL` / `MAILER_FROM_NAME` (omitted under adapter `none`) |
| `mailSmtpRelay` / `mailSmtpPort` / `mailSmtpSsl` | `MAILER_SMTP_RELAY` / `MAILER_SMTP_PORT` / `MAILER_SMTP_SSL` (adapter `smtp` only) |
| `mailSmtpUsername` / `mailSmtpPassword` | `MAILER_SMTP_USERNAME` / `MAILER_SMTP_PASSWORD` (adapter `smtp` only) |
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

- **Partner Center**: account, Azure Application offer + Managed Application
  plan; upload the same zip; configure authorizations + notification endpoint
  (an Azure Function appending `{applicationId, tenantId, managedRg, plan,
  eventType}` to a storage table — feeds the instance registry used by the
  internal release tooling; required before GA).
- **Model catalog versions**: RESOLVED — every entry in `modelDeployments` pins an
  explicit version, taken from `infrastructure/iac-ai-foundry` (verified against the
  live swedencentral catalog; gpt-5.6-* on 2026-07-20, gpt-5-mini on 2026-07-23,
  text-embedding-3-small on 2026-07-27). Still unverified for `westeurope` /
  `eastus`, which the UI also offers — re-check with
  `az cognitiveservices model list -l <region> -o table` before first publish.
- Registry credential distribution flow to customers (welcome email vs
  automated provisioning).
