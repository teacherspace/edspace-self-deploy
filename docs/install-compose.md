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

The app runs database migrations automatically on start, then listens on port `4000` (change with `EDSPACE_PORT`). Verify:

```sh
curl -fsS http://localhost:4000/health    # -> ok
curl -fsS http://localhost:4000/version   # -> build sha
```

## TLS / public exposure

Compose does not terminate TLS. Put your reverse proxy (Caddy, nginx, Traefik) in front of port 4000 and set `PHX_HOST` to the public hostname. WebSockets must be proxied (`Upgrade`/`Connection` headers).

## Demo data (optional, once)

```sh
docker compose --profile seed run --rm seed
```

## Upgrades

```sh
# set EDSPACE_IMAGE_TAG in .env to the new release tag, then:
docker compose pull app && docker compose up -d
```

## Backups

Two named volumes hold all state:

- `edspace_pgdata` — Postgres data. Prefer `docker compose exec db pg_dump -U edspace edspace > backup.sql`.
- `edspace_uploads` — uploaded files.

Snapshot both together for a consistent backup.
