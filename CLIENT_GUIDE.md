# EdSpace — Self-Deploy Guide

This guide explains what EdSpace needs to run, the supported ways to deploy it in your own infrastructure, and how to configure, operate and monitor an installation. Step-by-step instructions live in [docs/](docs/); this document is the map.

## About EdSpace

EdSpace is a web platform that helps schools integrate their curriculum with modern AI. It ships as a single container image (an Elixir/Phoenix release) that serves the web application, runs background work, and applies database migrations automatically on start.

## Application Architecture

One stateless application container, horizontally scalable, in front of a PostgreSQL database. Everything else is an external service you point the app at.

### External dependencies

| Dependency | Required | Notes |
|---|---|---|
| **PostgreSQL** | Yes | ≥ 16.3 with the `vector` (pgvector), `citext`, and `pg_trgm` extensions. Embeddings are stored in Postgres — no separate vector database. Use managed Postgres in production; a bundled evaluation-only Postgres is available. See [docs/database.md](docs/database.md). |
| **LLM / embedding provider** | Yes | Azure OpenAI by default; OpenAI, Anthropic, Google, Mistral, and others are supported. The embedding model must produce **1536-dimension** vectors. |
| **Mailer** | Optional | Transactional email — magic links, invitations, password resets. `MAILER_ADAPTER` selects the MailPace HTTP API, any SMTP relay, or `none`. EdSpace sends nothing else, so a deployment whose users all arrive over SSO or a roster feed can run with email off; see [Mailer](#mailer) for what changes. |
| **File storage** | Yes (pick one) | `local_disk` (persistent volume, default) or `azure_blob` (Azure Blob Storage) for uploads, chat attachments and logos. S3-compatible storage is not available yet. |
| **Langfuse** | Optional | LLM tracing and per-user cost visibility. When configured, every LLM call is traced to a Langfuse instance you operate (or Langfuse Cloud); leave the `LANGFUSE_*` settings empty to run without tracing. |
| **Azure Speech** | Optional | Speech-to-text / text-to-speech. Self-deploy packaging defaults speech **off**; enable it when you have an Azure Cognitive Services Speech resource. |
| **SSO providers** | Optional | Microsoft Entra ID, UniLogin, and Praxis sign-in via OIDC — see [User Authentication](#user-authentication). |

## Self-Deploy

Three supported paths, by increasing operational involvement on your side:

| Path | Best for |
|---|---|
| [Azure Marketplace](#azure-marketplace) | Turnkey Azure customers — EdSpace operates updates |
| [Docker Compose](#docker-compose-simple) | Pilots, evaluations, small single-host installs |
| [Kubernetes (Helm)](#kubernetes) | Teams with a cluster (AKS, EKS, GKE, on-prem) |

### Registry

Container images and the Helm chart are distributed from **`edspace.azurecr.io`**. You receive per-customer credentials (username + token) from EdSpace; the same token covers all three uses:

```sh
docker login edspace.azurecr.io -u <user> -p <token>          # Compose image pulls
helm registry login edspace.azurecr.io -u <user> -p <token>   # Chart pulls
# Kubernetes image pull secrets: set registryCredentials.* chart values
```

Always pin a release tag — never deploy `latest`. See [CHANGELOG.md](CHANGELOG.md) for release compatibility.

### Kubernetes

The Helm chart at `oci://edspace.azurecr.io/edspace/charts/edspace` is the production-grade path: rolling upgrades with a pre-upgrade migration job, multi-replica BEAM clustering, HPA/PDB support, and schema-validated configuration.

```sh
helm registry login edspace.azurecr.io -u <user> -p <token>
helm install edspace oci://edspace.azurecr.io/edspace/charts/edspace \
  --version <chart-version> -f values.yaml --wait --timeout 15m
```

You need Kubernetes 1.27+, an ingress controller, and an external PostgreSQL for production. A minimal `values.yaml` sets the hostname, registry credentials, database, LLM provider, and mailer — full walkthrough in [docs/install-kubernetes.md](docs/install-kubernetes.md).

### Docker Compose (simple)

The quickest way to evaluate EdSpace on a single host (≥ 4 CPU / 8 GiB). Postgres with pgvector is bundled; uploads go to a local volume.

```sh
docker login edspace.azurecr.io -u <user> -p <token>
cd compose
cp .env.example .env
../scripts/generate-secrets.sh >> .env   # SECRET_KEY_BASE, TOKEN_SIGNING_SECRET, POSTGRES_PASSWORD
$EDITOR .env                             # PHX_HOST, EDSPACE_IMAGE_TAG, LLM + MailPace settings
docker compose up -d
curl -fsS http://localhost:4000/health   # -> ok
```

Put a TLS-terminating reverse proxy in front before exposing it publicly. Full guide: [docs/install-compose.md](docs/install-compose.md).

### Azure Marketplace

For turnkey Azure customers, EdSpace is available as an **Azure Managed Application**: it deploys into your Azure subscription (Azure Container Apps + Azure Database for PostgreSQL), while EdSpace operates version updates for you. You provide the LLM and mailer credentials at deploy time through the marketplace UI.

Note: the managed application currently runs a single app replica and scales vertically ([docs/limitations.md](docs/limitations.md)).

Prefer to own and operate the deployment yourself? The same stack can be deployed directly — without the marketplace — via the **Deploy to Azure** button:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fteacherspace%2Fedspace-self-deploy%2Fmain%2Fmarketplace%2Fazure%2Fmanaged-app%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fteacherspace%2Fedspace-self-deploy%2Fmain%2Fmarketplace%2Fazure%2Fmanaged-app%2FcreateUiDefinition.json)

It uses the same portal form (registry credentials, MailPace key, AI options), but everything lands in a resource group you control and version updates are self-service (`az containerapp update --image <new tag>`) rather than operated by EdSpace.

## Configuration

The single source of truth for all settings is [`config/contract.yaml`](config/contract.yaml); every deployment path is generated from it, and the chart validates your values against it at install time (typos and misplaced secrets are rejected).

- **Kubernetes**: structured chart values (`db.*`, `llm.*`, `mailer.*`, …) plus two passthrough maps — `env:` for plain variables, `envSecret:` for secrets. See [docs/configuration.md](docs/configuration.md).
- **Compose**: the same variables directly in `.env` (start from `compose/.env.example`).

Variables marked **Secret** belong in secret storage (`envSecret` / Kubernetes Secrets), never plain config. The tables below list the customer-facing variables; the exhaustive generated reference is [docs/env-vars.md](docs/env-vars.md).

### Core

| Name | Description | Default | Required |
|---|---|---|---|
| `PHX_HOST` | Public hostname the app is served on | — | yes |
| `SECRET_KEY_BASE` | Signs/encrypts cookies and sessions (**secret**; generate with `scripts/generate-secrets.sh`) | — | yes |
| `TOKEN_SIGNING_SECRET` | Signs authentication tokens (**secret**) | — | yes |
| `PHX_CHECK_ORIGIN` | WebSocket origin allowlist | `//` + `PHX_HOST` | no |

### Database

| Name | Description | Default | Required |
|---|---|---|---|
| `DATABASE_URL` | Composed automatically by the chart/compose from structured DB settings — do not set by hand | — | managed |
| `POOL_SIZE` | Ecto connections per pool (keep replicas × `POOL_SIZE` × `POOL_COUNT` below Postgres `max_connections`) | `30` | no |
| `POOL_COUNT` | Ecto pools per node | `2` | no |
| `ECTO_IPV6` | Connect to Postgres over IPv6 | `false` | no |

### File storage

| Name | Description | Default | Required |
|---|---|---|---|
| `EDSPACE_FILE_STORAGE_ADAPTER` | `local_disk` or `azure_blob` | `local_disk` | no |
| `EDSPACE_FILE_STORAGE_ROOT` | Root directory for `local_disk` | `priv/uploads` | no |
| `AZURE_STORAGE_ACCOUNT` | Blob storage account name | — | with `azure_blob` |
| `AZURE_STORAGE_CONTAINER` | Blob container (must exist) | — | with `azure_blob` |
| `AZURE_STORAGE_KEY` | Blob account access key (**secret**) | — | with `azure_blob` |

⚠️ If any of the three `AZURE_STORAGE_*` values is missing, the app **silently falls back to local disk** — verify after first deploy that uploads land in Blob.

### LLM provider

| Name | Description | Default | Required |
|---|---|---|---|
| `EDSPACE_LLM_PROVIDER` | `azure`, `openai`, `anthropic`, `google`, `groq`, `mistral`, `openrouter`, `deepseek`, `deepinfra`, `cerebras`, `xai`, `amazon_bedrock` | `azure` | no |
| `EDSPACE_LLM_API_KEY` | Provider API key (**secret**) | — | yes |
| `EDSPACE_LLM_BASE_URL` | Provider base URL (your Azure OpenAI endpoint; empty for public providers) | — | azure only |
| `EDSPACE_LLM_API_VERSION` | Azure OpenAI API version | — | no |
| `EDSPACE_LLM_TEXT_MODEL` | Main text model, `provider:model` form | `azure:gpt-5.6-sol` | no |
| `EDSPACE_LLM_TEXT_DEPLOYMENT` | Azure deployment name for the text model | — | azure only |
| `EDSPACE_LLM_SMALL_MODEL` | Small/fast model for lightweight tasks | `azure:gpt-5.6-luna` | no |
| `EDSPACE_LLM_SMALL_DEPLOYMENT` | Azure deployment name for the small model | — | azure only |
| `EDSPACE_LLM_EMBEDDING_MODEL` | Embedding model — must produce 1536-dim vectors | `azure:text-embedding-3-small` | no |
| `EDSPACE_LLM_EMBEDDING_DEPLOYMENT` | Azure deployment name for the embedding model | — | azure only |

#### Which model deployments to create

The three `*_DEPLOYMENT` settings above only pin the **defaults**. EdSpace also lets a
school admin switch the chat model from the in-app AI settings page, and the dropdown
is a fixed list — a model your provider doesn't serve appears in the menu but fails on
the next message. On Azure, create a deployment whose name matches each of these
exactly (names are case-sensitive):

| Deployment | Role | Notes |
|---|---|---|
| `gpt-5.6-sol` | chat (default) | |
| `gpt-5.6-terra` | chat, and selectable as the small model | |
| `gpt-5.1` | chat | |
| `gpt-5.4` | chat | |
| `Mistral-Large-3` | chat | text-only; no image attachments |
| `gpt-5.6-luna` | small / background (default) | titles, classification, reranking |
| `gpt-5-mini` | small / background | |
| `text-embedding-3-small` | embeddings | must be 1536-dimension |

Only the two defaults plus the embedding model are needed to run. Deploy the rest to
make every entry in the admin dropdown work. Size each chat deployment's capacity
against your **largest single turn**, not average load: on Azure a deployment rated
at N thousand tokens-per-minute cannot serve any single request larger than that, and
a long conversation with a large PDF attached will exceed a small quota outright.

### Mailer

EdSpace sends exactly three emails, all about getting into an account: magic-link sign-in, password reset, and invitations. There is no marketing or notification mail — which is why email is optional. Every mode validates its own settings and **fails at boot** naming the variable at fault, rather than silently dropping sign-in links.

| Name | Description | Default | Required |
|---|---|---|---|
| `MAILER_ADAPTER` | `mailpace`, `smtp`, or `none` | `mailpace` | no |
| `MAILER_FROM_EMAIL` | From address, verified with your provider | — | unless `none` |
| `MAILER_FROM_NAME` | From display name | `EdSpace` | no |
| `MAILPACE_API_KEY` | MailPace API token (**secret**) | — | with `mailpace` |
| `MAILER_SMTP_RELAY` | SMTP relay hostname | — | with `smtp` |
| `MAILER_SMTP_PORT` | Relay port; use `465` with `MAILER_SMTP_SSL=true` | `587` | no |
| `MAILER_SMTP_USERNAME` / `MAILER_SMTP_PASSWORD` | Relay credentials (password is a **secret**) | — | if the relay authenticates |
| `MAILER_SMTP_SSL` | Implicit TLS from the first byte | `false` | no |
| `MAILER_SMTP_TLS` | STARTTLS policy: `always` / `never` / `if_available` | `always`\* | no |
| `MAILER_SMTP_AUTH` | Auth policy: `always` / `never` / `if_available` | `always` when a username is set | no |
| `MAILER_SMTP_TLS_VERIFY` | Verify the relay certificate against the OS trust store | `true` | no |
| `MAILER_SMTP_CACERTFILE` | PEM bundle for an internal CA, or an image with no trust store | — | no |
| `MAILER_SMTP_NO_MX_LOOKUPS` | Skip the MX lookup on the relay host | `true` | no |

\* Flips to `never` under `MAILER_SMTP_SSL=true`, where the session is already encrypted and STARTTLS is never offered.

**SMTP defaults are the strict ones.** STARTTLS is mandatory rather than opportunistic, because a relay that does not advertise it — or anyone in the middle stripping the capability — would otherwise get your credentials and sign-in links in cleartext. The relay's certificate is verified, which gen_smtp does not do on its own. Relax either only for a relay you control on a network you trust.

**Running with `MAILER_ADAPTER=none`.** Nothing is queued and nothing is sent. `/sign-in` offers a password form alongside any SSO buttons, `/onboarding` asks an invitee to set a password as well as a name, and each invitation's single-use link (valid 7 days) is shown to the inviting admin to pass on by hand. The trade-off: there is no self-service password recovery — a user who forgets their password needs a platform admin to set a new one from the backoffice (**Users → the user → Set password**), a staff-only action. Configuring an OIDC provider avoids that entirely.

Ask a running node what it resolved — it reports the adapter and whether a credential is set, never the credential itself:

```sh
bin/edspace eval "Edspace.Mailer.summary() |> IO.inspect()"
```

### Langfuse (optional)

Tracing activates only when all three of `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, and `LANGFUSE_HOST` are set; leave them empty to run without tracing.

| Name | Description | Default | Required |
|---|---|---|---|
| `LANGFUSE_PUBLIC_KEY` | Langfuse public key | — | no |
| `LANGFUSE_SECRET_KEY` | Langfuse secret key (**secret**) | — | no |
| `LANGFUSE_HOST` | Langfuse host receiving OpenTelemetry traces | — | no |
| `LANGFUSE_ENVIRONMENT` / `LANGFUSE_RELEASE` | Environment / version tags on emitted traces | — | no |
| `EDSPACE_OTEL_LLM_PAYLOADS` | `raw` includes prompt/completion text in traces; set `none` when traces leave your infrastructure | `raw` | no |

### Speech (optional, Azure only)

| Name | Description | Default | Required |
|---|---|---|---|
| `EDSPACE_SPEECH_ENABLED` | Enable STT/TTS (self-deploy packaging defaults this **off**) | `false`* | no |
| `AZURE_SPEECH_KEY` | Azure Speech API key (**secret**) | — | when enabled |
| `AZURE_SPEECH_REGION` | Azure Speech resource region | — | when enabled |

\* Application default is `true`; the chart and compose packaging set it to `false` until Speech credentials are provided.

### SSO / OIDC (optional)

| Name | Description | Default | Required |
|---|---|---|---|
| `MICROSOFT_CLIENT_ID` / `MICROSOFT_CLIENT_SECRET` / `MICROSOFT_REDIRECT_URI` / `MICROSOFT_TENANT_ID` | Microsoft Entra ID sign-in; empty client id disables it | tenant `common` | no |
| `UNILOGIN_CLIENT_ID` / `UNILOGIN_CLIENT_SECRET` / `UNILOGIN_REDIRECT_URI` | UniLogin (Danish school SSO); empty client id disables it | — | no |
| `PRAXIS_CLIENT_ID` / `PRAXIS_REDIRECT_URI` / `PRAXIS_BASE_URL` + license service vars | Praxis/Egmont sign-in and licensing | — | no |

Publisher-brokered integrations that EdSpace configures during onboarding (`ALICE_*` for STIL roster sync, `ALINEA_*` for Alinea sign-in) are not part of the customer-facing contract, so they are not accepted under `env:`/`envSecret:` in the Helm chart. Supply them through `extraEnv` / `extraEnvFrom` — EdSpace provides the values and the exact shape.

Redirect URIs follow `https://<PHX_HOST>/auth/<provider>/callback`.

### Other

| Name | Description | Default | Required |
|---|---|---|---|
| `EDSPACE_PLATFORM_ADMINS` | Comma-separated emails granted platform-admin on reconciliation — used to bootstrap the first admin (see [Manual user creation](#manual-user-creation)) | — | first install |
| `PDF_ENABLED` | Headless-Chromium PDF export | `true` | no |
| `CHROMIC_PDF_POOL_SIZE` | Concurrent Chromium sessions (memory cost each) | `4` | no |

A further set of internal tuning variables (pool/timeout/BEAM settings, listed at the end of [docs/env-vars.md](docs/env-vars.md)) should only be changed under guidance from EdSpace support.

## Operation

### User Authentication

There is **no self-service signup**: every account is provisioned first (SCIM, roster sync, or manually) and users then sign in with one of:

- **Microsoft Entra ID** — OIDC sign-in (`MICROSOFT_*` vars). Accounts provisioned over SCIM are matched by their Entra object id.
- **UniLogin** — the Danish education federation's OIDC broker (`UNILOGIN_*` vars), including publisher-brokered variants (Praxis).
- **Email magic link** — passwordless sign-in for manually invited users; requires a configured mailer.
- **Password** — offered on the public sign-in page only when `MAILER_ADAPTER=none`, since magic links are unavailable in that mode. (A password login also exists at `/internal-login` for demo/internal accounts regardless of the mailer setting.)

Users managed by an identity provider are locked to it: an account provisioned via SCIM must use Microsoft sign-in, and a roster-synced account must use its UniLogin broker — magic links and password resets are refused for them, so a compromised mailbox cannot bypass the school's IdP. With a mailer configured, the public sign-in page offers SSO and magic links only; `/internal-login` covers demo/internal accounts, whose passwords staff set.

### User Sync

#### Microsoft Entra (SCIM)

EdSpace exposes a **SCIM 2.0** endpoint at `https://<PHX_HOST>/scim/v2`, so Microsoft Entra can push users into EdSpace — no Graph read permissions on your directory are needed.

- Setup is per school, in the EdSpace backoffice (School → SCIM tab): EdSpace staff enable provisioning for the school, and a **bearer token** is generated there (shown once — store it in your Entra provisioning configuration). The token identifies the school; everything it provisions is scoped to that school.
- **What syncs**: users — create, update, and deactivate (soft deprovision). Group *memberships* are not synced as groups; instead, per-school **role mappings** translate Entra group/app-role names to EdSpace roles (`student`, `teacher`, `admin`), with a configurable default role.
- Provisioned users are linked to their Entra object id, so their later Microsoft SSO sign-in lands on the same account.

#### STIL

For Danish schools, rosters flow from **STIL/UNI-Login institution data** — EdSpace does not require its own STIL data agreement. EdSpace reads the institutional roster nightly (02:30 Copenhagen time) through the publisher's license system (Alice/LSMS), which already ingests STIL rosters:

- Enrollment is per school in the backoffice: a roster-sync toggle plus the school's UNI-Login institution number. Without enrollment (or without the `ALICE_*` connection settings), the integration is inert.
- The sync upserts users on their UniLogin id, maintains roles and memberships, and tracks license state. Deactivation is guarded by safety brakes (absence/unlicensed thresholds and a max-deactivation percentage) so a bad upstream roster cannot mass-deactivate a school.
- Sync status is visible in the backoffice (Roster sync page) and at `GET /api/roster_sync/status`.

The `ALICE_*` connection settings are provided by EdSpace during onboarding for this integration.

#### Manual User creation

Schools, users, and invitations are managed in the **backoffice UI** by platform admins: create schools, create users directly (for SSO-backed accounts — no email is sent; the user simply signs in), or **invite** users by email (magic-link based).

**First admin bootstrap** — on a fresh install no admin exists yet, so no one can log into the backoffice. Set `EDSPACE_PLATFORM_ADMINS` to a comma-separated list of admin emails in the deployment environment, then run inside the app container:

```sh
bin/edspace rpc 'Edspace.Accounts.AdminReconciler.bootstrap() |> IO.inspect(pretty: true)'
```

This is additive only (it never demotes existing admins). With a mailer, enter that email on `/sign-in` to request a magic link. With `MAILER_ADAPTER=none`, copy the URL returned under `onboarding_links` over a trusted channel; it remains valid for seven days and asks the admin to set a first password.

## Monitoring

### Logs

The app writes structured JSON logs to stdout — collect them with your platform's usual tooling:

```sh
kubectl logs deploy/edspace          # Kubernetes
docker compose logs -f app           # Compose
```

The JSON shape follows Datadog's field conventions (`error.kind`, trace correlation ids); any JSON-capable log backend can ingest it.

Two HTTP endpoints support probes and diagnostics:

- `GET /health` — `200 ok` when the app can reach the database, `503` otherwise. Used as the readiness/startup probe.
- `GET /version` — returns the build's git SHA (no DB dependency; used as the liveness probe, and handy to confirm which build is live after an upgrade).

### Telemetry

#### Application metrics

The app instruments HTTP requests, database queries, background jobs, and BEAM VM internals via Erlang `:telemetry`. In self-deploy installs, monitor at the platform layer — container CPU/memory, Postgres metrics, and ingress/request metrics from your reverse proxy or ingress controller cover day-to-day operations. There is no Prometheus endpoint; if you run a Datadog Agent, in-app metrics and traces can be exported to it natively — contact EdSpace support for the settings. For other monitoring stacks, contact EdSpace support.

#### OpenTelemetry for Generative AI

Every LLM call emits OpenTelemetry spans following the [GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) (`gen_ai.client.inference`), with each chat turn grouped into a single trace — including retrieval, reranking, tool executions, and token/cost usage — and attributed to user and session.

Traces export to a **Langfuse** instance over OTLP when `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` / `LANGFUSE_HOST` are configured (optional — see [Langfuse](#langfuse-optional)). This gives you per-user and per-session cost, latency, and quality visibility into all generative AI usage.

Privacy note: by default traces include prompt and completion text (`EDSPACE_OTEL_LLM_PAYLOADS=raw`). Set it to `none` if traces leave your infrastructure or must not contain user content.

---

**Further reading**: [Kubernetes install](docs/install-kubernetes.md) · [Compose install](docs/install-compose.md) · [Configuration](docs/configuration.md) · [Env var reference](docs/env-vars.md) · [Database](docs/database.md) · [Operations](docs/operations.md) · [Limitations](docs/limitations.md)
