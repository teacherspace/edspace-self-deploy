# Database requirements

## Version and extensions

- PostgreSQL **≥ 16.3**.
- Extensions: `vector` (pgvector), `citext`, `pg_trgm`. The app's migrations run `CREATE EXTENSION IF NOT EXISTS`, so the database user needs the privilege to create them (or an operator pre-installs them). The `ash-functions` helpers are plain SQL functions installed by the same migrations — not a Postgres extension, so no allow-listing is needed for them.
- Embeddings are stored as 1536-dimension `vector` columns with HNSW indexes.

Provider notes:

- **Azure Database for PostgreSQL Flexible Server**: allow-list the extensions in the `azure.extensions` server parameter (`VECTOR,CITEXT,PG_TRGM`). The managed-application package does this automatically.
- **Amazon RDS/Aurora**: pgvector is available on PG 16; `citext`/`pg_trgm` ship with contrib.
- **Self-managed / compose**: use a pinned `pgvector/pgvector` image (bundled Postgres in both chart and compose uses `0.8.5-pg16`).

## Connection math

Each app node opens `POOL_SIZE × POOL_COUNT` connections (default 30 × 2 = 60), plus a couple for migrations. Keep

```
replicas × POOL_SIZE × POOL_COUNT + ~10 < max_connections
```

Azure Flexible Server defaults scale with SKU memory; about 15 of the slots
are reserved, leaving as user connections: B1ms 35, B2s 414, D2ds_v5 844. The
managed app only offers B2s and up, whose defaults already clear the app's
needs; on smaller self-chosen SKUs raise `max_connections` (changing it
requires a server restart) or lower the pool via
`env.POOL_SIZE`/`env.POOL_COUNT`.

## TLS caveat

The app currently enables TLS to Postgres only when the composed URL carries `?ssl=true` (`db.sslMode: require`), and certificate verification options are not yet configurable ([limitations.md](limitations.md)). Verify connectivity against your provider's TLS policy on first deploy; native `DATABASE_SSL` support is planned app-side.

## Bundled Postgres (chart) — evaluation only

`db.bundled.enabled=true` runs a single-replica pgvector StatefulSet with **no backups, no replication, no PITR**. It exists so an evaluation can start with one command. Move to a managed/operated Postgres before real data arrives; there is no migration tooling beyond standard `pg_dump`/`pg_restore`.
