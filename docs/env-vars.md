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
| `EDSPACE_LLM_TEXT_MODEL` | no | azure:gpt-5.4 |  | Main text model, "provider:model" form. |
| `EDSPACE_LLM_TEXT_DEPLOYMENT` | no |  |  | Azure deployment name serving the main text model (azure only). |
| `EDSPACE_LLM_SMALL_MODEL` | no | azure:gpt-5-mini |  | Small/fast model for lightweight tasks, "provider:model" form. |
| `EDSPACE_LLM_SMALL_DEPLOYMENT` | no |  |  | Azure deployment name serving the small model (azure only). |
| `EDSPACE_LLM_EMBEDDING_MODEL` | no | azure:text-embedding-3-small |  | Embedding model for retrieval/RAG, "provider:model" form. Must produce 1536-dimension vectors (database schema is fixed to 1536). |
| `EDSPACE_LLM_EMBEDDING_DEPLOYMENT` | no |  |  | Azure deployment name serving the embedding model (azure only). |
| `AZURE_OPENAI_API_KEY` | no |  | yes | Fallback alias for EDSPACE_LLM_API_KEY (azure provider). Prefer EDSPACE_LLM_API_KEY; this alias exists for Azure-conventional setups. |
| `AZURE_OPENAI_BASE_URL` | no |  |  | Fallback alias for EDSPACE_LLM_BASE_URL (azure provider). Prefer EDSPACE_LLM_BASE_URL. |

## Speech (Azure Cognitive Services)

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `EDSPACE_SPEECH_ENABLED` | no | true |  | Enables speech features (STT/TTS). Requires the AZURE_SPEECH_* settings when enabled; set to "false" when no Azure Speech resource is available. |
| `AZURE_SPEECH_KEY` | no |  | yes | Azure Cognitive Services Speech API key. |
| `AZURE_SPEECH_REGION` | no |  |  | Azure Speech resource region. |
| `AZURE_SPEECH_ENDPOINT` | no |  |  | Azure Speech endpoint override. |
| `EDSPACE_SPEECH_RECOGNITION_LANGUAGE` | no | da-DK |  | Primary speech-to-text language. |
| `EDSPACE_SPEECH_RECOGNITION_LANGUAGES` | no | da-DK,en-US,de-DE,fr-FR,es-ES,it-IT |  | Comma-separated set of languages offered for speech-to-text. |
| `EDSPACE_SPEECH_VOICE` | no | da-DK-ChristelNeural |  | Default text-to-speech voice. |

## Mailer

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `MAILER_FROM_EMAIL` | yes |  |  | From address for transactional email. Must be a sender verified in your MailPace account. |
| `MAILER_FROM_NAME` | no | EdSpace |  | From display name for transactional email. |
| `MAILPACE_API_KEY` | yes |  | yes | MailPace API token. Required — the app refuses to boot in production without it. MailPace is currently the only supported email provider (see docs/limitations.md). |

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
| `MICROSOFT_BASE_URL` | no |  |  | Microsoft identity platform base URL override. |
| `PRAXIS_CLIENT_ID` | no |  |  | Praxis/Egmont OIDC client id (PKCE public client). |
| `PRAXIS_REDIRECT_URI` | no |  |  | Praxis OIDC redirect URI. |
| `PRAXIS_BASE_URL` | no |  |  | Praxis OIDC base URL. |
| `PRAXIS_LICENSE_SERVICE_URL` | no |  |  | Praxis license service endpoint. |
| `PRAXIS_LICENSE_API_KEY` | no |  | yes | Praxis license service API key. |
| `PRAXIS_PRODUCT_URL` | no |  |  | Praxis product URL used in license redirects. |
| `DEBUG_AUTH_FAILURES` | no | false |  | Set to "true" to log detailed SSO failure reasons. WARNING - logs may then contain personal data; enable only while troubleshooting. |

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
| `LANGFUSE_BASE_URL` | no |  |  | Langfuse REST API base URL; defaults to LANGFUSE_HOST. |
| `LANGFUSE_ENVIRONMENT` | no |  |  | deployment.environment tag on emitted traces. |
| `LANGFUSE_RELEASE` | no |  |  | service.version tag on emitted traces. |
| `EDSPACE_OTEL_LLM_PAYLOADS` | no | raw |  | Whether prompt/completion text is included in telemetry spans. Set to "none" to strip payloads (recommended when traces leave your infrastructure). |

## Linear feedback integration

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `LINEAR_API_KEY` | no |  | yes | Linear API key for the in-app feedback integration. Leave empty to disable (feedback is then not forwarded anywhere). |
| `LINEAR_FEEDBACK_TEAM_ID` | no |  |  | Linear team receiving feedback issues. |
| `LINEAR_INTERNAL_CUSTOMER_ID` | no |  |  | Linear customer id attached to feedback issues. |
| `LINEAR_LABEL_BUG` | no |  |  | Linear label id applied to bug feedback. |
| `LINEAR_LABEL_IDEA` | no |  |  | Linear label id applied to idea feedback. |
| `LINEAR_LABEL_OTHER` | no |  |  | Linear label id applied to other feedback. |

## Deployment settings (not read by the app)

| Variable | Required | Default | Secret | Description |
|---|---|---|---|---|
| `POSTGRES_PASSWORD` | compose |  | yes | Password for the bundled Postgres (compose only). Feeds the composed DATABASE_URL. Generate with scripts/generate-secrets.sh. |
| `EDSPACE_IMAGE` | no | registry.edspace.io/edspace/edspace |  | App image reference (compose only). |
| `EDSPACE_IMAGE_TAG` | compose |  |  | App image tag (compose only). Pin to a release tag. |
| `EDSPACE_PORT` | no | 4000 |  | Host port the app is published on (compose only). |

## Internal tuning variables

Set only under guidance from EdSpace support:

`PHX_SERVER`; `PORT`; `DNS_CLUSTER_QUERY`; `DB_QUEUE_TARGET_MS`; `DB_QUEUE_INTERVAL_MS`; `DB_TIMEOUT_MS`; `AZURE_API_KEY`; `AZURE_BASE_URL`; `REQ_LLM_POOL_SIZE`; `REQ_LLM_POOL_COUNT`; `REQ_LLM_STRUCTURED_POOL_SIZE`; `REQ_LLM_STRUCTURED_POOL_COUNT`; `REQ_LLM_BULK_POOL_SIZE`; `REQ_LLM_BULK_POOL_COUNT`; `MAX_CONCURRENT_STREAMS`; `MAX_CONCURRENT_CREATION_SESSIONS`; `MAX_CONCURRENT_BACKGROUND_TASKS`; `HISTORY_MESSAGE_WINDOW`; `EDSPACE_CHAT_MAX_TOTAL_CACHED_CHARS`; `EDSPACE_CHAT_MAX_HISTORY_CHARS`; `CHROMIC_PDF_TIMEOUT_MS`; `CHROMIC_PDF_INIT_TIMEOUT_MS`; `CHROMIC_PDF_CHROME_EXECUTABLE`; `LANGFUSE_BASEURL`; `LANGFUSE_TIMEOUT`; `OTEL_BSP_MAX_QUEUE_SIZE`; `OTEL_BSP_SCHEDULE_DELAY_MS`; `OTEL_BSP_EXPORT_TIMEOUT_MS`; `LINEAR_BASE_URL`; `SOCKET_DRAINER_BATCH_SIZE`; `SOCKET_DRAINER_BATCH_INTERVAL_MS`; `SOCKET_DRAINER_SHUTDOWN_MS`; `ULIMIT_NOFILE`; `ERL_FLAGS`; `ERL_MAX_PORTS`; `ERL_MAX_PROCESSES`; `RELEASE_DISTRIBUTION`; `RELEASE_NODE`; `RELEASE_COOKIE`; `DISCARD_ASSISTANT_DRAFTS`
