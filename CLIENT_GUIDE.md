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
| **Mailer (MailPace)** | Yes | Transactional email (magic links, invitations, password resets) via the MailPace HTTP API. Currently the only supported provider — the app refuses to boot without an API key ([docs/limitations.md](docs/limitations.md)). |
| **Langfuse** | Yes (for AI features) | EdSpace's system prompts are managed in Langfuse and fetched at runtime (cached in-process; there is no bundled prompt fallback), so AI features need a reachable Langfuse with the EdSpace prompt set installed. The same connection provides LLM tracing and per-user cost visibility. Point it at a Langfuse instance you operate or Langfuse Cloud. |
| **File storage** | Yes (pick one) | `local_disk` (persistent volume, default) or `azure_blob` (Azure Blob Storage) for uploads, chat attachments and logos. S3-compatible storage is not available yet. |
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

Container images and the Helm chart are distributed from **`registry.edspace.io`**. You receive per-customer credentials (username + token) from EdSpace; the same token covers all three uses:

```sh
docker login registry.edspace.io -u <user> -p <token>          # Compose image pulls
helm registry login registry.edspace.io -u <user> -p <token>   # Chart pulls
# Kubernetes image pull secrets: set registryCredentials.* chart values
```

Always pin a release tag — never deploy `latest`. See [CHANGELOG.md](CHANGELOG.md) for release compatibility.

### Kubernetes

The Helm chart at `oci://registry.edspace.io/edspace/charts/edspace` is the production-grade path: rolling upgrades with a pre-upgrade migration job, multi-replica BEAM clustering, HPA/PDB support, and schema-validated configuration.

```sh
helm registry login registry.edspace.io -u <user> -p <token>
helm install edspace oci://registry.edspace.io/edspace/charts/edspace \
  --version <chart-version> -f values.yaml --wait --timeout 15m
```

You need Kubernetes 1.27+, an ingress controller, and an external PostgreSQL for production. A minimal `values.yaml` sets the hostname, registry credentials, database, LLM provider, and mailer — full walkthrough in [docs/install-kubernetes.md](docs/install-kubernetes.md).

### Docker Compose (simple)

The quickest way to evaluate EdSpace on a single host (≥ 4 CPU / 8 GiB). Postgres with pgvector is bundled; uploads go to a local volume.

```sh
docker login registry.edspace.io -u <user> -p <token>
cd compose
cp .env.example .env
../scripts/generate-secrets.sh >> .env   # SECRET_KEY_BASE, TOKEN_SIGNING_SECRET, POSTGRES_PASSWORD
$EDITOR .env                             # PHX_HOST, EDSPACE_IMAGE_TAG, LLM + MailPace settings
docker compose up -d
curl -fsS http://localhost:4000/health   # -> ok
```

Put a TLS-terminating reverse proxy in front before exposing it publicly. Full guide: [docs/install-compose.md](docs/install-compose.md).

### Azure Marketplace

For turnkey Azure customers, EdSpace is available as an **Azure Managed Application**: it deploys into your Azure subscription (Azure Container Apps + Azure Database for PostgreSQL), while EdSpace operates version updates through a managed update train. You provide the LLM and mailer credentials at deploy time through the marketplace UI.

Note: the managed application currently runs a single app replica and scales vertically ([docs/limitations.md](docs/limitations.md)).

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
| `EDSPACE_LLM_TEXT_MODEL` | Main text model, `provider:model` form | `azure:gpt-5.4` | no |
| `EDSPACE_LLM_TEXT_DEPLOYMENT` | Azure deployment name for the text model | — | azure only |
| `EDSPACE_LLM_SMALL_MODEL` | Small/fast model for lightweight tasks | `azure:gpt-5-mini` | no |
| `EDSPACE_LLM_SMALL_DEPLOYMENT` | Azure deployment name for the small model | — | azure only |
| `EDSPACE_LLM_EMBEDDING_MODEL` | Embedding model — must produce 1536-dim vectors | `azure:text-embedding-3-small` | no |
| `EDSPACE_LLM_EMBEDDING_DEPLOYMENT` | Azure deployment name for the embedding model | — | azure only |

### Mailer

| Name | Description | Default | Required |
|---|---|---|---|
| `MAILPACE_API_KEY` | MailPace API token (**secret**) — the app refuses to boot without it | — | yes |
| `MAILER_FROM_EMAIL` | From address (must be verified in MailPace) | — | yes |
| `MAILER_FROM_NAME` | From display name | `EdSpace` | no |

### Langfuse

| Name | Description | Default | Required |
|---|---|---|---|
| `LANGFUSE_PUBLIC_KEY` | Langfuse public key | — | yes |
| `LANGFUSE_SECRET_KEY` | Langfuse secret key (**secret**) | — | yes |
| `LANGFUSE_HOST` | Langfuse host — drives both prompt fetching and trace export | — | yes |
| `LANGFUSE_ENVIRONMENT` / `LANGFUSE_RELEASE` | Environment / version tags on emitted traces | — | no |
| `EDSPACE_OTEL_LLM_PAYLOADS` | `raw` includes prompt/completion text in traces; set `none` when traces leave your infrastructure | `raw` | no |

### Speech (optional, Azure only)

| Name | Description | Default | Required |
|---|---|---|---|
| `EDSPACE_SPEECH_ENABLED` | Enable STT/TTS (self-deploy packaging defaults this **off**) | `false`* | no |
| `AZURE_SPEECH_KEY` | Azure Speech API key (**secret**) | — | when enabled |
| `AZURE_SPEECH_REGION` | Azure Speech resource region | — | when enabled |
| `EDSPACE_SPEECH_RECOGNITION_LANGUAGE` | Primary speech-to-text language | `da-DK` | no |
| `EDSPACE_SPEECH_RECOGNITION_LANGUAGES` | Languages offered for speech-to-text | `da-DK,en-US,de-DE,fr-FR,es-ES,it-IT` | no |
| `EDSPACE_SPEECH_VOICE` | Default text-to-speech voice | `da-DK-ChristelNeural` | no |

\* Application default is `true`; the chart and compose packaging set it to `false` until Speech credentials are provided.

### SSO / OIDC (optional)

| Name | Description | Default | Required |
|---|---|---|---|
| `MICROSOFT_CLIENT_ID` / `MICROSOFT_CLIENT_SECRET` / `MICROSOFT_REDIRECT_URI` / `MICROSOFT_TENANT_ID` | Microsoft Entra ID sign-in; empty client id disables it | tenant `common` | no |
| `UNILOGIN_CLIENT_ID` / `UNILOGIN_CLIENT_SECRET` / `UNILOGIN_REDIRECT_URI` | UniLogin (Danish school SSO); empty client id disables it | — | no |
| `PRAXIS_CLIENT_ID` / `PRAXIS_REDIRECT_URI` / `PRAXIS_BASE_URL` + license service vars | Praxis/Egmont sign-in and licensing | — | no |

Redirect URIs follow `https://<PHX_HOST>/auth/<provider>/callback`.

### Other

| Name | Description | Default | Required |
|---|---|---|---|
| `EDSPACE_PLATFORM_ADMINS` | Comma-separated emails granted platform-admin on reconciliation — used to bootstrap the first admin (see [Manual user creation](#manual-user-creation)) | — | first install |
| `PDF_ENABLED` | Headless-Chromium PDF export | `true` | no |
| `CHROMIC_PDF_POOL_SIZE` | Concurrent Chromium sessions (memory cost each) | `4` | no |
| `LINEAR_API_KEY` + `LINEAR_*` | Forward in-app feedback to a Linear team (**secret** key); empty disables | — | no |
| `DEBUG_AUTH_FAILURES` | Log detailed SSO failure reasons — may log personal data, troubleshooting only | `false` | no |

A further set of internal tuning variables (pool/timeout/BEAM settings, listed at the end of [docs/env-vars.md](docs/env-vars.md)) should only be changed under guidance from EdSpace support.

## Operation

### User Authentication

There is **no self-service signup**: every account is provisioned first (SCIM, roster sync, or manually) and users then sign in with one of:

- **Microsoft Entra ID** — OIDC sign-in (`MICROSOFT_*` vars). Accounts provisioned over SCIM are matched by their Entra object id.
- **UniLogin** — the Danish education federation's OIDC broker (`UNILOGIN_*` vars), including publisher-brokered variants (Praxis).
- **Email magic link** — passwordless sign-in for manually invited users; requires only the mailer.

Users managed by an identity provider are locked to it: an account provisioned via SCIM must use Microsoft sign-in, and a roster-synced account must use its UniLogin broker — magic links and password resets are refused for them, so a compromised mailbox cannot bypass the school's IdP. A password login also exists at `/internal-login` for demo/internal accounts only; staff set those passwords, and it is not offered on the public sign-in page.

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
bin/edspace rpc 'Edspace.Accounts.AdminReconcilerWorker.enqueue()'
```

This is additive only (it never demotes existing admins).

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

Traces export to your **Langfuse** instance over OTLP using the same `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` / `LANGFUSE_HOST` settings the app already needs for prompts. This gives you per-user and per-session cost, latency, and quality visibility into all generative AI usage.

Privacy note: by default traces include prompt and completion text (`EDSPACE_OTEL_LLM_PAYLOADS=raw`). Set it to `none` if traces leave your infrastructure or must not contain user content.

---

**Further reading**: [Kubernetes install](docs/install-kubernetes.md) · [Compose install](docs/install-compose.md) · [Configuration](docs/configuration.md) · [Env var reference](docs/env-vars.md) · [Database](docs/database.md) · [Operations](docs/operations.md) · [Limitations](docs/limitations.md)
