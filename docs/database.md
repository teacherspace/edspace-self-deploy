# Database requirements

## Version and extensions

- PostgreSQL **≥ 16.3**.
- Extensions: `vector` (pgvector), `citext`, `pg_trgm`, plus Ash's `ash-functions`. The app's migrations run `CREATE EXTENSION IF NOT EXISTS`, so the database user needs the privilege to create them (or an operator pre-installs them).
- Embeddings are stored as 1536-dimension `vector` columns with HNSW indexes.

Provider notes:

- **Azure Database for PostgreSQL Flexible Server**: allow-list the extensions in the `azure.extensions` server parameter (`VECTOR,CITEXT,PG_TRGM`). The managed-application package does this automatically.
- **Amazon RDS/Aurora**: pgvector is available on PG 16; `citext`/`pg_trgm` ship with contrib.
- **Self-managed / compose**: use the `pgvector/pgvector:pg16` image (bundled Postgres in both chart and compose already does).

## Connection math

Each app node opens `POOL_SIZE × POOL_COUNT` connections (default 30 × 2 = 60), plus a couple for migrations. Keep

```
replicas × POOL_SIZE × POOL_COUNT + ~10 < max_connections
```

Azure B-series defaults can be as low as 50 — raise `max_connections` to at least 100 (the managed app sets this), or lower the pool via `env.POOL_SIZE`/`env.POOL_COUNT`.

## TLS caveat

The app currently enables TLS to Postgres only when the composed URL carries `?ssl=true` (`db.sslMode: require`), and certificate verification options are not yet configurable ([limitations.md](limitations.md)). Verify connectivity against your provider's TLS policy on first deploy; native `DATABASE_SSL` support is planned app-side.

## Bundled Postgres (chart) — evaluation only

`db.bundled.enabled=true` runs a single-replica pgvector StatefulSet with **no backups, no replication, no PITR**. It exists so an evaluation can start with one command. Move to a managed/operated Postgres before real data arrives; there is no migration tooling beyond standard `pg_dump`/`pg_restore`.
