# Installing EdSpace on Kubernetes

## Prerequisites

- Kubernetes 1.27+ with an ingress controller (any nginx-compatible class works; others via `ingress.className` + `ingress.annotations`).
- PostgreSQL ≥ 16.3 with the `vector`, `citext` and `pg_trgm` extensions available — see [database.md](database.md). For evaluation you can use the bundled Postgres instead (`db.bundled.enabled=true`).
- Registry credentials from EdSpace (username + token). One credential covers image pulls and the chart itself.
- An LLM provider key.
- A way to send transactional email — a [MailPace](https://mailpace.com) API token or an SMTP relay — **or** a decision to run without it (`mailer.adapter: none`, see [configuration.md](configuration.md#transactional-email)).

## Install

```sh
helm registry login edspace.azurecr.io -u <user> -p <token>
```

Minimal evaluation values (`values.eval.yaml`):

```yaml
app:
  host: edspace.example.org

registryCredentials:
  enabled: true
  username: <user>
  password: <token>

db:
  bundled:
    enabled: true          # eval only — see database.md

llm:
  provider: azure
  apiKey: <llm-key>
  baseUrl: https://<your-endpoint>.cognitiveservices.azure.com/
  textDeployment: gpt-5.6-sol
  smallDeployment: gpt-5.6-luna
  embeddingDeployment: text-embedding-3-small

# MailPace. For an SMTP relay use `adapter: smtp` with `smtp.relay`/`smtp.password`
# instead, or `adapter: none` to run with email disabled — see
# configuration.md#transactional-email.
mailer:
  adapter: mailpace
  fromEmail: noreply@example.org
  mailpaceApiKey: <mailpace-token>

env:
  EDSPACE_SPEECH_ENABLED: "false"

# Evaluation without a pre-created TLS Secret. Put TLS in front before public use.
ingress:
  tls:
    enabled: false
```

```sh
helm install edspace oci://edspace.azurecr.io/edspace/charts/edspace \
  --version <chart-version> -n edspace --create-namespace -f values.eval.yaml \
  --wait --timeout 15m
helm test edspace -n edspace
```

`SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET` and the Erlang release cookie are auto-generated on first install and kept in the `<release>-generated` Secret (it survives uninstall). The install notes (`helm status edspace`) show how to retrieve them.

## Production checklist

- **Explicit secrets** — set `secrets.autoGenerate=false` and provide `secrets.*` or `secrets.existingSecret`. Auto-generation uses Helm `lookup`, which does not work under GitOps renderers (ArgoCD/Flux) and regenerates on every render there.
- **External Postgres** — `db.host/database/username` + `db.password`, or `db.existingSecret` (full URL key or password key; see [configuration.md](configuration.md)). Size `max_connections` per [database.md](database.md).
- **Durable file storage** — `storage.adapter=azure_blob` (or keep `local_disk` with `storage.localDisk.persistence` on a single replica / RWX storage class). Note: if any of the three `AZURE_STORAGE_*` settings is missing the app **silently falls back to local disk**.
- **TLS** — bring a certificate Secret (`ingress.tls.secretName`) or enable `ingress.tls.certManager` with your issuer.
- **Scaling** — `replicaCount>1` requires clustering (enabled by default) and non-local file storage; add `pdb.enabled=true` and optionally `autoscaling.enabled=true`.

## Upgrades

```sh
helm upgrade edspace oci://edspace.azurecr.io/edspace/charts/edspace \
  --version <new-version> -n edspace -f values.yaml
```

Database migrations run at app boot on first install. Upgrades run them in a
pre-upgrade hook Job before pods roll; a failed migration aborts the upgrade
while old pods keep serving. See [operations.md](operations.md).

## Seeding demo data

```sh
helm upgrade edspace ... --reuse-values --set seed.enabled=true
# after the Job succeeds, turn it off again — it re-runs on every
# install/upgrade while enabled:
helm upgrade edspace ... --reuse-values --set seed.enabled=false
```

## Uninstall

`helm uninstall edspace -n edspace`. The generated application Secret, bundled
Postgres password Secret, and PVCs are kept; delete them explicitly if you mean
to destroy the data. Registry and ordinary configuration Secrets are removed
with the release.
