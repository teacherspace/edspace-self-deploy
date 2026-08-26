# Operations

## Health endpoints and probes

- `GET /health` — `200 ok` when the app can reach the database, else `503`. Used as the **readiness** probe (a DB blip correctly removes pods from rotation) and the **startup** probe.
- `GET /version` — returns the build's git SHA. Used as the **liveness** probe on purpose: it has no DB dependency, so a database outage degrades the app instead of restart-looping it.

Startup allows up to 150 s because the server runs pending database migrations before it binds the port.

## Upgrades and rollouts

- Chart upgrades run migrations in a `pre-upgrade` hook Job first; if it fails, the upgrade aborts and the old pods keep serving. The boot-time migration in the new pods is then a no-op (Ecto advisory locks serialize concurrent attempts).
- Rolling deploys drain WebSockets gracefully in batches (~30 s budget); `lifecycle.terminationGracePeriodSeconds` (default 45) must stay above `SOCKET_DRAINER_SHUTDOWN_MS`.
- Config changes roll pods automatically via checksum annotations — no Reloader needed.
- **Rollback**: `helm rollback` restores the previous image, but migrations are forward-only. EdSpace releases keep the schema backward-compatible with the previous app version; skipping several versions and rolling back is not supported.
- **Azure (Container Apps, self-managed)**: use the "Update EdSpace" button in the root README (or `az containerapp update --image edspace.azurecr.io/edspace/edspace:<version>`). The app runs in single-revision mode: the new revision receives traffic only after its startup/readiness probes pass, and a failed one leaves the old revision serving. Rollback is `az containerapp revision activate --revision <previous>`, with the same one-version schema caveat. Registry tags are the bare version (`1.0.2`); the `v` is only on the git tag.

## Scaling and clustering

- Multiple replicas form a BEAM cluster via DNS (`clustering.enabled`, on by default): the chart runs a headless Service and sets `DNS_CLUSTER_QUERY`, `RELEASE_NODE` and a stable `RELEASE_COOKIE`. Without clustering, LiveView/PubSub events do not cross nodes — don't disable it above one replica.
- Verify cluster formation: `kubectl exec deploy/edspace -- /app/bin/edspace rpc 'IO.inspect(Node.list())'` — expect the other pods listed.
- `replicaCount>1` also requires non-local file storage (see [configuration.md](configuration.md)).
- CPU: the chart sets a request but **no CPU limit** by default — CFS throttling degrades BEAM latency badly. If your platform mandates limits, also pin schedulers: `env.ERL_FLAGS: "+S 2"` (match the limit).
- Memory: PDF export runs headless Chromium (`CHROMIC_PDF_POOL_SIZE`, default 4 sessions). Heavy PDF usage → raise the memory limit or lower the pool.

## File descriptors

The release wants a 262144 soft fd limit (`ULIMIT_NOFILE`). Compose grants it via `ulimits`; modern Kubernetes runtimes (containerd ≥ 1.6) default higher. Verify: `kubectl exec deploy/edspace -- sh -c 'ulimit -n'`.

## Backups

- Postgres: your provider's backups (managed) or `pg_dump` (bundled/compose).
- Uploads: Azure Blob (redundancy per storage account) or the uploads PVC/volume.
- The `<release>-generated` Secret (if auto-generated secrets are used) — losing it invalidates sessions and tokens; back it up or move to explicit secrets.

## Diagnostics

- `kubectl logs deploy/edspace` — structured app logs.
- `GET /version` — confirm which build is live after an upgrade.
- `helm test edspace` — in-cluster smoke check.
