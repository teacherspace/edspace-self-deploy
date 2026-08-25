<!-- GENERATED FILE - edit config/contract.yaml and run `make gen`. -->

# Environment variable reference

Variables read by the app — plus the deployment-layer settings in the
final section — grouped by area. `Secret` variables belong in secret
storage (`envSecret` / Kubernetes Secrets / password fields), never in
plain config.

Variables marked *managed* are composed by the deployment packaging
(chart, compose, managed app) and should not be set by hand.

## Core Phoenix / HTTP

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `PHX_HOST` | yes |  |  | Public hostname the app is served on. Drives generated URLs and the default WebSocket origin check. |
| `SECRET_KEY_BASE` | yes |  | yes | Random string (64+ chars) used to sign/encrypt cookies and session data. Generate with scripts/generate-secrets.sh. Changing it invalidates all active sessions. |
| `TOKEN_SIGNING_SECRET` | yes |  | yes | Random string used to sign authentication tokens. Generate with scripts/generate-secrets.sh. Changing it invalidates issued tokens. |
| `PHX_CHECK_ORIGIN` | no |  |  | WebSocket origin check. Unset, the app allows "//" + PHX_HOST. Set to a comma-separated list of origins, or "false" to disable (not recommended). |

## Database

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `DATABASE_URL` | *managed* |  | yes | Ecto connection URL, ecto://USER:PASS@HOST:PORT/DB. Composed automatically by the chart/compose/managed app from structured database settings; do not set directly. |
| `ECTO_IPV6` | no | false |  | Set to "true" to connect to Postgres over IPv6. |
| `POOL_SIZE` | no | 30 |  | Ecto connections per pool. Effective connections per node = POOL_SIZE x POOL_COUNT (default 30x2 = 60). Keep replicas x POOL_SIZE x POOL_COUNT below Postgres max_connections. |
| `POOL_COUNT` | no | 2 |  | Number of Ecto pools per node (see POOL_SIZE). |

## File storage

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `EDSPACE_FILE_STORAGE_ADAPTER` | no | local_disk |  | Attachment storage backend. "local_disk" stores under EDSPACE_FILE_STORAGE_ROOT (needs a persistent volume); "azure_blob" requires AZURE_STORAGE_ACCOUNT/CONTAINER/KEY — if any of the three is missing the app silently falls back to local disk. One of: `local_disk`, `azure_blob`. |
| `EDSPACE_FILE_STORAGE_ROOT` | no | priv/uploads |  | Root directory for the local_disk adapter. |
| `AZURE_STORAGE_ACCOUNT` | no |  |  | Azure Blob storage account name (azure_blob adapter). |
| `AZURE_STORAGE_CONTAINER` | no |  |  | Azure Blob container for uploads (must already exist). |
| `AZURE_STORAGE_KEY` | no |  | yes | Azure Blob storage account access key (azure_blob adapter). |

## LLM provider

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `EDSPACE_LLM_PROVIDER` | no | azure |  | LLM provider used for chat, generation and embeddings. One of: `azure`, `openai`, `anthropic`, `google`, `groq`, `mistral`, `openrouter`, `deepseek`, `deepinfra`, `cerebras`, `xai`, `amazon_bedrock`. |
| `EDSPACE_LLM_API_KEY` | yes |  | yes | API key for the configured LLM provider. Effectively required — the product's core features depend on it. (The Azure-style fallbacks AZURE_OPENAI_API_KEY / AZURE_API_KEY are also honoured.) |
| `EDSPACE_LLM_BASE_URL` | no |  |  | Provider base URL. Required for azure (your Azure OpenAI / AI Foundry endpoint); usually left empty for public providers. |
| `EDSPACE_LLM_API_VERSION` | no |  |  | Azure OpenAI API version, when the provider is azure. |
| `EDSPACE_LLM_TEXT_MODEL` | no | azure:gpt-5.6-sol |  | Main text model, "provider:model" form. Precedence: a model saved on the backoffice Platform settings page (the `platform_settings` table) overrides this variable, and also pins the matching EDSPACE_LLM_TEXT_DEPLOYMENT from the model registry so a stale deployment name cannot pair with the newly selected model. Clear the setting there to fall back to this variable. |
| `EDSPACE_LLM_TEXT_DEPLOYMENT` | no |  |  | Azure deployment name serving the main text model (azure only). |
| `EDSPACE_LLM_SMALL_MODEL` | no | azure:gpt-5.6-luna |  | Small/fast model for lightweight tasks, "provider:model" form. Overridden by the backoffice Platform settings page in the same way as EDSPACE_LLM_TEXT_MODEL, pinning EDSPACE_LLM_SMALL_DEPLOYMENT with it. |
| `EDSPACE_LLM_SMALL_DEPLOYMENT` | no |  |  | Azure deployment name serving the small model (azure only). |
| `EDSPACE_LLM_EMBEDDING_MODEL` | no | azure:text-embedding-3-small |  | Embedding model for retrieval/RAG, "provider:model" form. Must produce 1536-dimension vectors (database schema is fixed to 1536). |
| `EDSPACE_LLM_EMBEDDING_DEPLOYMENT` | no |  |  | Azure deployment name serving the embedding model (azure only). |
| `AZURE_OPENAI_API_KEY` | no |  | yes | Fallback alias for EDSPACE_LLM_API_KEY (azure provider). Prefer EDSPACE_LLM_API_KEY; this alias exists for Azure-conventional setups. |
| `AZURE_OPENAI_BASE_URL` | no |  |  | Fallback alias for EDSPACE_LLM_BASE_URL (azure provider). Prefer EDSPACE_LLM_BASE_URL. |

## Speech (Azure Cognitive Services)

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `EDSPACE_SPEECH_ENABLED` | no | true |  | Deployment default for the speech features (STT/TTS). Requires the AZURE_SPEECH_* settings when enabled; the packaging sets it to "false" until an Azure Speech resource is provided. A platform admin can switch speech on or off at runtime on the backoffice Platform settings page, which overrides this variable; the page also says when the credentials are missing. The voice and dictation languages are managed there only (see `excluded:`). |
| `AZURE_SPEECH_KEY` | no |  | yes | Azure Cognitive Services Speech API key. |
| `AZURE_SPEECH_REGION` | no |  |  | Azure Speech resource region. |
| `AZURE_SPEECH_ENDPOINT` | no |  |  | Azure Speech endpoint override. |

## Mailer

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `MAILER_ADAPTER` | no | mailpace |  | Transactional-email backend. "mailpace" uses the MailPace HTTP API, "smtp" any SMTP relay, "none" disables email entirely — sign-in then uses passwords and/or SSO, and invitation links are shown to the inviting admin to pass on by hand. The app also accepts "local" (Swoosh's in-memory /dev/mailbox), which is refused in production and therefore not offered here. One of: `mailpace`, `smtp`, `none`. |
| `MAILER_FROM_EMAIL` | conditional |  |  | From address for transactional email. Must be a sender address verified with the provider — MailPace rejects every message otherwise, and most relays refuse the envelope. **Required when** MAILER_ADAPTER is "mailpace" or "smtp" (blank counts as missing and fails at boot); not read with "none". |
| `MAILER_FROM_NAME` | no | EdSpace |  | Deployment default for the From display name on transactional email. Also editable at runtime on the backoffice Platform settings page, which overrides this variable. |
| `MAILPACE_API_KEY` | conditional |  | yes | MailPace API token. **Required when** MAILER_ADAPTER=mailpace (the default). |
| `MAILER_SMTP_RELAY` | conditional |  |  | SMTP relay hostname. Configured explicitly, so no MX lookup is done on it. **Required when** MAILER_ADAPTER=smtp. |
| `MAILER_SMTP_PORT` | no | 587 |  | SMTP relay port. 587 is the STARTTLS submission port; use 465 together with MAILER_SMTP_SSL=true for implicit TLS. |
| `MAILER_SMTP_USERNAME` | no |  |  | SMTP username. Setting it flips MAILER_SMTP_AUTH to "always" — a relay given credentials is expected to use them. |
| `MAILER_SMTP_PASSWORD` | conditional |  | yes | SMTP password for MAILER_SMTP_USERNAME. **Required when** MAILER_ADAPTER=smtp and MAILER_SMTP_USERNAME is set (blank counts as missing). |
| `MAILER_SMTP_SSL` | no | false |  | Implicit TLS from the first byte, usually on port 465. Leave false for the ordinary STARTTLS submission port. |
| `MAILER_SMTP_TLS` | no | always |  | STARTTLS policy. Mandatory by default: with "if_available" a relay that does not advertise STARTTLS — or anyone in the middle stripping the capability — gets the session in cleartext, credentials and sign-in links included. Set "never" only for a relay on a trusted network. The default flips to "never" when MAILER_SMTP_SSL=true, where the session is already encrypted and STARTTLS is never offered. One of: `always`, `never`, `if_available`. |
| `MAILER_SMTP_AUTH` | no | if_available |  | SMTP authentication policy. Defaults to "always" when MAILER_SMTP_USERNAME is set and "if_available" when it is not. One of: `always`, `never`, `if_available`. |
| `MAILER_SMTP_TLS_VERIFY` | no | true |  | Verify the relay's TLS certificate against the OS trust store. Setting it false disables verification entirely — only safe for a relay you control on a trusted network, never across the public internet. |
| `MAILER_SMTP_CACERTFILE` | no |  |  | Path to a PEM CA bundle to verify the relay against, for an internal CA or an image without an OS trust store. Boot fails if the path does not exist. |
| `MAILER_SMTP_NO_MX_LOOKUPS` | no | true |  | Skip the MX lookup on MAILER_SMTP_RELAY. Set false only if you really pointed it at a domain rather than a host. |

## Authentication / OIDC

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `UNILOGIN_CLIENT_ID` | no |  |  | UniLogin (Danish school SSO) OIDC client id. Leave empty to disable UniLogin sign-in. |
| `UNILOGIN_CLIENT_SECRET` | no |  | yes | UniLogin OIDC client secret. |
| `UNILOGIN_REDIRECT_URI` | no |  |  | UniLogin OIDC redirect URI (https://<PHX_HOST>/auth/unilogin/callback). |
| `UNILOGIN_BASE_URL` | no | https://et-broker.unilogin.dk/auth/realms/broker |  | UniLogin broker base URL. |
| `UNILOGIN_ID_CLAIM` | no | uniid |  | OIDC claim carrying the UniLogin user id. |
| `UNILOGIN_ROLE_CLAIM` | no | uniLoginRolle |  | OIDC claim carrying the UniLogin role. |
| `MICROSOFT_TENANT_ID` | no | common |  | Microsoft Entra ID tenant ("common" allows any tenant). |
| `MICROSOFT_CLIENT_ID` | no |  |  | Microsoft Entra ID application (client) id. Leave empty to disable Microsoft sign-in. |
| `MICROSOFT_CLIENT_SECRET` | no |  | yes | Microsoft Entra ID client secret. |
| `MICROSOFT_REDIRECT_URI` | no |  |  | Microsoft OIDC redirect URI (https://<PHX_HOST>/auth/microsoft/callback). |
| `MICROSOFT_BASE_URL` | no |  |  | Microsoft identity platform base URL. Unset, the app derives "https://login.microsoftonline.com/<MICROSOFT_TENANT_ID>/v2.0" from MICROSOFT_TENANT_ID; set this only for a cloud whose endpoint differs (US Gov, China 21Vianet) or an internal proxy. |
| `PRAXIS_CLIENT_ID` | no |  |  | Praxis/Egmont OIDC client id (PKCE public client). |
| `PRAXIS_REDIRECT_URI` | no |  |  | Praxis OIDC redirect URI. |
| `PRAXIS_BASE_URL` | no |  |  | Praxis OIDC base URL. |
| `PRAXIS_LICENSE_SERVICE_URL` | no |  |  | Praxis license service endpoint. |
| `PRAXIS_LICENSE_API_KEY` | no |  | yes | Praxis license service API key. |
| `PRAXIS_PRODUCT_URL` | no |  |  | Praxis product URL used in license redirects. |
| `EDSPACE_PLATFORM_ADMINS` | conditional |  |  | Comma-separated emails granted platform-admin on reconciliation. This is the first-admin bootstrap: a fresh install has no account that can reach the backoffice, so set this and then run `bin/edspace rpc 'Edspace.Accounts.AdminReconciler.bootstrap() \|> IO.inspect(pretty: true)'` inside the app container. With email disabled, the result contains onboarding links to hand over securely. Additive only — it never demotes an existing admin. Read on the serving node. **Required when** bootstrapping the first platform admin on a fresh install. |

## Member retention & purge

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `MEMBER_PURGE_ENABLED` | no | true |  | Deployment-side kill switch for the nightly member-purge sweep. Set "false" to stop it without a deploy — the worker then discards. The sweep runs only when neither this variable nor the backoffice Platform settings toggle disables it; a kill switch thrown in either place wins, and the backoffice cannot re-enable a sweep this variable disabled. |

## PDF export

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `PDF_ENABLED` | no | true |  | Enables the headless-Chromium PDF export subsystem. The packaging layer forces "false" in migration/seed jobs. |
| `CHROMIC_PDF_POOL_SIZE` | no | 4 |  | Concurrent Chromium sessions for PDF rendering. Each session costs memory; lower it on small instances. |

## Telemetry (Langfuse / OpenTelemetry)

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `LANGFUSE_PUBLIC_KEY` | no |  |  | Langfuse public key. LLM tracing activates only when LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY and LANGFUSE_HOST are all set; leave empty to disable tracing. |
| `LANGFUSE_SECRET_KEY` | no |  | yes | Langfuse secret key. |
| `LANGFUSE_HOST` | no |  |  | Langfuse host receiving OpenTelemetry traces (your own Langfuse instance). |
| `LANGFUSE_BASE_URL` | no | https://cloud.langfuse.com |  | Langfuse REST API base URL — the read/query side (prompt fetches, usage and fair-use lookups), separate from the OTLP span exporter. Falls back to LANGFUSE_HOST, so one host variable can drive both the push and pull paths, and then to Langfuse's public cloud: an install that sets LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY without either host variable sends its queries to cloud.langfuse.com. Point this at your own instance, or leave all three unset. Trace export is unaffected — it activates only when LANGFUSE_HOST is set alongside both keys. |
| `LANGFUSE_ENVIRONMENT` | no |  |  | deployment.environment tag on emitted traces. |
| `LANGFUSE_RELEASE` | no |  |  | service.version tag on emitted traces. |
| `EDSPACE_OTEL_LLM_PAYLOADS` | no | raw |  | Whether prompt/completion text is included in telemetry spans. Set to "none" to strip payloads (recommended when traces leave your infrastructure). |

## Deployment settings (not read by the app)

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `POSTGRES_PASSWORD` | compose |  | yes | Password for the bundled Postgres (compose only). Feeds the composed DATABASE_URL. Generate with scripts/generate-secrets.sh. |
| `EDSPACE_IMAGE` | no | edspace.azurecr.io/edspace/edspace |  | App image reference (compose only). |
| `EDSPACE_IMAGE_TAG` | compose |  |  | App image tag (compose only). Pin to a release tag. |
| `EDSPACE_PORT` | no | 4000 |  | Host port the app is published on (compose only). |

## Internal tuning variables

Set only under guidance from EdSpace support:

`PHX_SERVER`; `PORT`; `DNS_CLUSTER_QUERY`; `DB_QUEUE_TARGET_MS`; `DB_QUEUE_INTERVAL_MS`; `DB_TIMEOUT_MS`; `AZURE_API_KEY`; `AZURE_BASE_URL`; `REQ_LLM_POOL_SIZE`; `REQ_LLM_POOL_COUNT`; `REQ_LLM_STRUCTURED_POOL_SIZE`; `REQ_LLM_STRUCTURED_POOL_COUNT`; `REQ_LLM_BULK_POOL_SIZE`; `REQ_LLM_BULK_POOL_COUNT`; `MAX_CONCURRENT_STREAMS`; `MAX_CONCURRENT_CREATION_SESSIONS`; `MAX_CONCURRENT_BACKGROUND_TASKS`; `HISTORY_MESSAGE_WINDOW`; `EDSPACE_CHAT_MAX_TOTAL_CACHED_CHARS`; `EDSPACE_CHAT_MAX_HISTORY_CHARS`; `MAILER_SMTP_RETRIES`; `CHROMIC_PDF_TIMEOUT_MS`; `CHROMIC_PDF_INIT_TIMEOUT_MS`; `CHROMIC_PDF_CHROME_EXECUTABLE`; `LANGFUSE_BASEURL`; `LANGFUSE_TIMEOUT`; `OTEL_BSP_MAX_QUEUE_SIZE`; `OTEL_BSP_SCHEDULE_DELAY_MS`; `OTEL_BSP_EXPORT_TIMEOUT_MS`; `SOCKET_DRAINER_BATCH_SIZE`; `SOCKET_DRAINER_BATCH_INTERVAL_MS`; `SOCKET_DRAINER_SHUTDOWN_MS`; `ULIMIT_NOFILE`; `ERL_FLAGS`; `ERL_MAX_PORTS`; `ERL_MAX_PROCESSES`; `RELEASE_DISTRIBUTION`; `RELEASE_NODE`; `RELEASE_COOKIE`; `DISCARD_ASSISTANT_DRAFTS`
