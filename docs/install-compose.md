# Installing EdSpace with Docker Compose

For pilots, evaluations and small single-host installs. Postgres (with pgvector) is bundled; uploads are stored on a local volume.

## Prerequisites

- Docker Engine 24+ with the compose plugin, on a host with ≥ 4 CPU / 8 GiB.
- Registry credentials from EdSpace, an LLM provider key, a MailPace API token.

## Setup

```sh
docker login registry.edspace.io -u <user> -p <token>
cd compose
cp .env.example .env
../scripts/generate-secrets.sh >> .env   # SECRET_KEY_BASE, TOKEN_SIGNING_SECRET, POSTGRES_PASSWORD
$EDITOR .env                             # PHX_HOST, EDSPACE_LLM_*, MAILPACE_API_KEY, MAILER_FROM_EMAIL, EDSPACE_IMAGE_TAG
docker compose up -d
```

The default LLM provider is Azure. For that path, uncomment and fill
`EDSPACE_LLM_BASE_URL` plus the text, small, and embedding deployment names in
`.env`. For a public provider, set `EDSPACE_LLM_PROVIDER` and its model values
instead. Compose now requires an explicit `EDSPACE_IMAGE_TAG` so an install or
upgrade cannot drift onto `latest`.

Optional settings are commented out in `.env` — uncomment a line only when
giving it a value (the app treats a set-but-empty variable as set). Self-deploy
disables speech by default. To enable it, set `EDSPACE_SPEECH_ENABLED=true`
and provide `AZURE_SPEECH_KEY` and `AZURE_SPEECH_REGION`.

The app runs database migrations automatically on start, then listens on port `4000` (change with `EDSPACE_PORT`). Verify:

```sh
curl -fsS http://localhost:4000/health    # -> ok
curl -fsS http://localhost:4000/version   # -> build sha
```

## TLS / public exposure

Compose does not terminate TLS, and port 4000 is published as plaintext HTTP on
**all host interfaces**. Do not leave it reachable from untrusted networks: put
your reverse proxy (Caddy, nginx, Traefik) in front of port 4000, firewall
direct access to it, and set `PHX_HOST` to the public hostname. WebSockets must
be proxied (`Upgrade`/`Connection` headers).

## Demo data (optional, once)

Run only after the app has started at least once — migrations run at app boot,
and seeding needs the migrated schema:

```sh
docker compose --profile seed run --rm seed
```

## Upgrades

```sh
# set EDSPACE_IMAGE_TAG in .env to the new release tag, then:
docker compose pull app && docker compose up -d
```

Note: `POSTGRES_PASSWORD` only takes effect when the database volume is first
initialized. To change it later, run `ALTER ROLE edspace PASSWORD '...'` in
Postgres *and* update `.env` to match — re-generating it alone breaks the
composed `DATABASE_URL`.

## Backups

Two named volumes hold all state:

- `edspace_pgdata` — Postgres data. Prefer `docker compose exec db pg_dump -U edspace edspace > backup.sql`.
- `edspace_uploads` — uploaded files.

Snapshot both together for a consistent backup.
