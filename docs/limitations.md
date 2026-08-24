# Known limitations

Current limitations of the self-deploy packaging and the app, with their workarounds. Items marked *(app change planned)* are tracked against the application itself.

## No self-service password recovery without email

Resolved since the previous release: email is no longer MailPace-only. `MAILER_ADAPTER` now selects MailPace, any SMTP relay, or `none` — see [Transactional email](configuration.md#transactional-email).

What remains is a consequence of running with `MAILER_ADAPTER=none`. Magic links and password reset both need to send a message, so with email off a user who forgets their password needs a platform admin to set a new one from the backoffice (**Users → the user → Set password**), which is a staff-only action — a school admin cannot do it. Configuring an OIDC provider avoids the problem entirely.

Invitations in this mode are also delivered by hand: after inviting someone, the backoffice shows a single-use onboarding link, valid for 7 days, for you to pass on through a channel you already trust.

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

The marketplace managed application pins one replica and scales vertically; BEAM clustering across ACA replicas is not yet supported there. The Helm chart clusters fine on Kubernetes. (Applies equally to the Deploy-to-Azure button, which deploys the same template.)

## Azure template redeploys and Key Vault purge protection

The Azure template (managed application and Deploy-to-Azure button alike) creates an instance Key Vault named `kv-eds-<hash of the resource group id>` with purge protection enabled. If you delete a deployment and redeploy into a resource group with the **same name**, the new vault collides with the soft-deleted one for the retention period. Redeploy into a freshly named resource group instead. Relatedly, the portal form pins `bootstrapSecrets=true`, which is correct for fresh installs only — infra changes to an existing instance must run `az deployment group create` with `bootstrapSecrets=false` (see `marketplace/azure/managed-app/README.md`).
