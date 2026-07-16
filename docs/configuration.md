# Configuration

How chart values (and compose `.env`) map to the app's environment. The complete variable list is in [env-vars.md](env-vars.md); the canonical definition is `config/contract.yaml`.

## The mapping convention

A setting gets a **structured chart value** only when the chart has to act on it — compose a value, create a resource, or route it into a Secret. Everything else passes through two maps:

```yaml
env:                       # non-secret → ConfigMap
  EDSPACE_SPEECH_VOICE: en-US-JennyNeural
  POOL_SIZE: "40"
envSecret:                 # secret → Secret
  UNILOGIN_CLIENT_SECRET: "..."
```

Both maps are validated against the generated `values.schema.json`: typos and unknown types are caught at `helm lint`/install time, and putting a secret variable in plain `env:` is rejected.

For customer-managed secret machinery (External Secrets Operator, CSI driver), mount your own ConfigMaps/Secrets with `extraEnvFrom`, or raw `env` entries with `extraEnv`.

## Database (three modes)

1. **Chart-known password** — `db.host/port/database/username` + `db.password` (or `db.bundled.enabled=true`). The chart composes `DATABASE_URL` into its Secret, URL-encoding the password.
2. **Existing Secret with a full URL** — `db.existingSecret` + `db.existingSecretKeys.url`: the deployment references that key directly as `DATABASE_URL`.
3. **Existing Secret with a password** — `db.existingSecret` + `db.existingSecretKeys.password`: the deployment composes the URL at pod start. The password must not contain URL-reserved characters (`@ : / ? #`) in this mode — or pre-encode it.

`db.sslMode: require` appends `?ssl=true` to composed URLs. See [database.md](database.md) for the TLS caveat.

`DATABASE_URL` is never set by hand in any mode.

## App secrets

`SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET` and the Erlang `RELEASE_COOKIE`:

- **Default** (`secrets.autoGenerate: true`): generated on first install, persisted in the `<release>-generated` Secret (`helm.sh/resource-policy: keep`, survives uninstall/reinstall).
- **Production/GitOps**: set `secrets.secretKeyBase`/`tokenSigningSecret`/`releaseCookie` explicitly, or point `secrets.existingSecret` at your own Secret (default keys `secret-key-base`, `token-signing-secret`, `release-cookie`). Auto-generation relies on Helm `lookup` and regenerates under ArgoCD/Flux-style rendering — sessions and tokens would be invalidated on every sync.

## File storage

- `storage.adapter: local_disk` (default): uploads under `storage.localDisk.root` on a PVC (`storage.localDisk.persistence`). With `ReadWriteOnce` storage this limits you to one replica — the schema enforces it.
- `storage.adapter: azure_blob`: set `storage.azureBlob.account/container` and `key` (or `existingSecret`/`existingSecretKey`). **Warning**: the app silently falls back to local disk if any of the three is missing — the chart guards the common cases via schema, but verify after first deploy that uploads land in Blob.
- S3-compatible storage is not available yet (see [limitations.md](limitations.md)).

## LLM providers

`llm.provider` selects the backend (azure, openai, anthropic, google, mistral, and others — full list in [env-vars.md](env-vars.md)). For `azure`, set `llm.baseUrl` and the three deployment names; for public providers usually only `llm.apiKey` plus optional model overrides. The embedding model must produce **1536-dimension vectors** — the database schema is fixed to that size.

## Speech

Speech features are on by default but require Azure Speech credentials (`AZURE_SPEECH_KEY`/`AZURE_SPEECH_REGION` via `env`/`envSecret`). Without Azure, set `env.EDSPACE_SPEECH_ENABLED: "false"`.

## SSO / OIDC

UniLogin, Microsoft Entra ID and Praxis are all optional and configured via passthrough vars (`UNILOGIN_*`, `MICROSOFT_*`, `PRAXIS_*`). Redirect URIs are `https://<app.host>/auth/<provider>/callback`.

## LLM tracing (Langfuse)

Tracing activates only when `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_HOST` are all set — point them at **your own** Langfuse instance. Set `EDSPACE_OTEL_LLM_PAYLOADS: none` if traces leave your infrastructure and must not contain prompt text.
