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

Both maps are validated against the generated `values.schema.json`: unknown variable names (typos), wrong types, and putting a secret variable in plain `env:` are all rejected at `helm lint`/install time. Variables outside the contract (e.g. a new app release ahead of the chart) go through `extraEnv`/`extraEnvFrom` instead.

For customer-managed secret machinery (External Secrets Operator, CSI driver), mount your own ConfigMaps/Secrets with `extraEnvFrom`, or raw `env` entries with `extraEnv`.

## Runtime platform settings (not env vars)

Not everything is deployment configuration. Product-behavior settings live on the backoffice **Platform settings** page (platform-admin only) and are stored in the database, so changing one needs no restart and applies to every node within moments:

- **Default AI models** — the platform-wide text and small models.
- **Assistant chat tools** — the master switch and per-tool kill switches (whiteboard drawing/editing, conversation export, assistant handover, share-code recognition, guidance, workspace awareness, builder tools).
- **Fair use** — the monthly LLM token allowance per user.
- **Member retention & purge** — the safeguards on the nightly purge sweep (global cap, roster-freshness window, notice floor, stale-run reclaim).

Each setting's precedence is *Platform settings page > deployment env var > compiled default*, and the page shows the currently effective value with its provenance. One deliberate exception: the member-purge sweep runs only when **neither** `MEMBER_PURGE_ENABLED` (env, still contracted as break-glass) **nor** the page's toggle disables it — a kill switch on an irreversible deletion works from wherever it was thrown.

The underlying env vars for these settings exist in the app but are outside the customer contract (see `excluded:` in `config/contract.yaml`); prefer the page. First set-up of the admin account that can reach the page is `EDSPACE_PLATFORM_ADMINS` — see [SSO / OIDC](#sso--oidc).

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

- `storage.adapter: local_disk` (default): uploads under `storage.localDisk.root` on a PVC (`storage.localDisk.persistence`). With `ReadWriteOnce` storage this limits you to one replica and a zero-surge rollout — the schema enforces both, avoiding a second pod that cannot safely attach the volume.
- `storage.adapter: azure_blob`: set `storage.azureBlob.account/container` and `key` (or `existingSecret`/`existingSecretKey`). **Warning**: the app silently falls back to local disk if any of the three is missing — the chart guards the common cases via schema, but verify after first deploy that uploads land in Blob.
- S3-compatible storage is not available yet (see [limitations.md](limitations.md)).

## LLM providers

`llm.provider` selects the backend (azure, openai, anthropic, google, mistral, and others — full list in [env-vars.md](env-vars.md)). For `azure`, set `llm.baseUrl` and the three deployment names; for public providers usually only `llm.apiKey` plus optional model overrides. The embedding model must produce **1536-dimension vectors** — the database schema is fixed to that size.

## Speech

The application default is on, but the Helm and Compose self-deploy packaging
defaults speech off until separate Azure Speech credentials are provided. To
enable it, set `env.EDSPACE_SPEECH_ENABLED: "true"`,
`envSecret.AZURE_SPEECH_KEY`, and `env.AZURE_SPEECH_REGION` (or supply those
last two through `extraEnv`/`extraEnvFrom`).

## Transactional email

EdSpace sends exactly three messages, all about getting into an account: magic-link sign-in, password reset, and invitations. There is no marketing or notification mail, which is why email is **optional**.

`mailer.adapter` picks the backend. Every mode validates its own inputs and **raises at boot** with the offending variable named — a silently misconfigured mailer drops sign-in links, which is the one failure worth refusing to defer.

- `mailpace` (default): set `mailer.mailpaceApiKey` (or `mailer.existingSecret`, default key `mailpace-api-key`) and a `mailer.fromEmail` on a MailPace-verified domain.
- `smtp`: set `mailer.smtp.relay` and `mailer.fromEmail`. The password goes in `mailer.smtp.password` or `mailer.existingSecret` (default key `smtp-password`). Defaults are the safe ones — port 587 with **mandatory** STARTTLS and certificate verification against the OS trust store, authentication required once `mailer.smtp.username` is set, and no MX lookup on a relay you named explicitly. Leave `mailer.smtp.tls`/`auth` empty to keep those defaults; setting them overrides. For implicit TLS use `ssl: true` with `port: 465`.
  - If the relay's certificate will not verify, boot fails naming the three ways out: install CA certificates in the image, point `mailer.smtp.caCertFile` at a PEM bundle for an internal CA, or set `mailer.smtp.tlsVerify: false` for a self-signed relay on a network you trust.
- `none`: nothing is queued and nothing is sent. `/sign-in` offers a password form alongside any SSO buttons, `/onboarding` asks an invitee to set a password as well as a name, and an invitation's single-use link is shown to the inviting admin to pass on by hand. Read the consequences in [limitations.md](limitations.md) before choosing it — there is no self-service password recovery in this mode.

Ask a running node what it resolved — it reports the adapter and whether a credential is set, never the credential itself:

```sh
bin/edspace eval "Edspace.Mailer.summary() |> IO.inspect()"
```

## SSO / OIDC

UniLogin, Microsoft Entra ID and Praxis are all optional and configured via passthrough vars (`UNILOGIN_*`, `MICROSOFT_*`, `PRAXIS_*`). Redirect URIs are `https://<app.host>/auth/<provider>/callback`.

**First admin.** A fresh install has no account that can reach the backoffice. Set `env.EDSPACE_PLATFORM_ADMINS` to a comma-separated list of admin emails, then run `bin/edspace rpc 'Edspace.Accounts.AdminReconcilerWorker.enqueue()'` in the app container. It is additive — it never demotes an existing admin. With `mailer.adapter: none` those admins sign in with a password rather than a magic link.

## LLM tracing (Langfuse)

Tracing activates only when `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_HOST` are all set — point them at **your own** Langfuse instance. Set `EDSPACE_OTEL_LLM_PAYLOADS: none` if traces leave your infrastructure and must not contain prompt text.
