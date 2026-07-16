# Known limitations

Current limitations of the self-deploy packaging and the app, with their workarounds. Items marked *(app change planned)* are tracked against the application itself.

## Email is MailPace-only *(app change planned)*

Transactional email uses the MailPace HTTP API exclusively — the app refuses to boot in production without `MAILPACE_API_KEY`, and generic SMTP is not yet supported. Every install therefore needs a MailPace account with a verified sender.

## No S3-compatible storage yet *(app change planned)*

Supported adapters are `local_disk` and `azure_blob`. An S3 adapter (AWS S3, MinIO, GCS interop) exists in the underlying library but is not yet wired into the app configuration. Until it lands, non-Azure installs use `local_disk` with persistent volumes.

Also note: with `azure_blob`, the app **silently falls back to local disk** if any of `AZURE_STORAGE_ACCOUNT/CONTAINER/KEY` is missing — verify uploads land in Blob after first deploy.

## Database TLS is coarse *(app change planned)*

TLS to Postgres can be enabled via the composed URL (`db.sslMode: require` → `?ssl=true`), but CA/verification options are not configurable. Depending on your Postgres provider's certificate setup this may be insufficient; test on first deploy.

## Bundled Postgres is evaluation-only

No backups, no replication, single replica. See [database.md](database.md).

## Speech requires Azure

Speech features (STT/TTS) are Azure Cognitive Services only. Off-Azure installs set `EDSPACE_SPEECH_ENABLED=false`.

## Langfuse is not bundled

LLM tracing integrates with a Langfuse instance you operate; the chart only exposes the `LANGFUSE_*` settings. (A bundled option is under consideration.)

## Horizontal scaling on Azure Container Apps (managed application)

The marketplace managed application pins one replica and scales vertically; BEAM clustering across ACA replicas is not yet supported there. The Helm chart clusters fine on Kubernetes.
