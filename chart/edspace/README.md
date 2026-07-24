# edspace

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.0.0-dev](https://img.shields.io/badge/AppVersion-0.0.0--dev-informational?style=flat-square)

EdSpace — self-hosted deployment chart

**Homepage:** <https://edspace.dk>

## Requirements

Kubernetes: `>=1.27.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| app.checkOrigin | string | `""` | WebSocket origin check override (PHX_CHECK_ORIGIN). Empty = derived from host. |
| app.host | string | `""` | Public hostname the app is served on (PHX_HOST). Required. |
| autoscaling.behavior | object | `{}` |  |
| autoscaling.enabled | bool | `false` |  |
| autoscaling.maxReplicas | int | `6` |  |
| autoscaling.minReplicas | int | `2` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `75` |  |
| autoscaling.targetMemoryUtilizationPercentage | string | `nil` |  |
| clusterDomain | string | `"cluster.local"` | Cluster DNS domain, used for the DNS_CLUSTER_QUERY value. |
| clustering.enabled | bool | `true` | Wire Erlang clustering (headless service + DNS_CLUSTER_QUERY + RELEASE_NODE/RELEASE_COOKIE). Required for replicaCount > 1. |
| containerSecurityContext.allowPrivilegeEscalation | bool | `false` |  |
| containerSecurityContext.capabilities.drop[0] | string | `"ALL"` |  |
| db.bundled.database | string | `"edspace"` |  |
| db.bundled.enabled | bool | `false` | Run an in-cluster Postgres (pgvector). EVALUATION ONLY — no backups, no replication. Use an external managed Postgres in production. |
| db.bundled.image | string | `"pgvector/pgvector:0.8.5-pg16"` | Postgres image; must provide the pgvector extension. Pinned to a released pgvector version — keep the pin when overriding. |
| db.bundled.password | string | `""` | Superuser password for first install. Empty = generated. The retained Secret wins on upgrades/reinstalls so changing this cannot desync the DB. |
| db.bundled.persistence.size | string | `"10Gi"` |  |
| db.bundled.persistence.storageClass | string | `""` |  |
| db.bundled.resources.limits.memory | string | `"1Gi"` |  |
| db.bundled.resources.requests.cpu | string | `"250m"` |  |
| db.bundled.resources.requests.memory | string | `"512Mi"` |  |
| db.bundled.username | string | `"edspace"` |  |
| db.database | string | `"edspace"` |  |
| db.existingSecret | string | `""` | Existing Secret with database credentials (modes b/c); takes precedence over db.password. |
| db.existingSecretKeys.password | string | `""` | Key holding only the password (mode c; composed with db.host etc.). Passwords containing URL-reserved characters must be pre-encoded. |
| db.existingSecretKeys.url | string | `""` | Key holding a complete ecto:// URL (mode b). |
| db.host | string | `""` |  |
| db.password | string | `""` | Database password rendered into the chart-managed Secret (mode a). |
| db.port | int | `5432` |  |
| db.sslMode | string | `""` | "require" appends ?ssl=true to the composed DATABASE_URL. See docs/database.md for the app's current TLS limitations. |
| db.username | string | `"edspace"` |  |
| env | object | `{"EDSPACE_SPEECH_ENABLED":"false"}` | Extra non-secret env vars (validated against the app contract). Speech is disabled by default in self-deploy because it needs separate Azure Speech credentials; set true plus AZURE_SPEECH_KEY/REGION to enable it. |
| envSecret | object | `{}` | Extra secret env vars (validated; rendered into the app Secret). |
| extraEnv | list | `[]` | Raw corev1.EnvVar entries appended to the app container. |
| extraEnvFrom | list | `[]` | Raw envFrom entries (customer-managed ConfigMaps/Secrets, ESO, CSI...). |
| fullnameOverride | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"registry.edspace.io/edspace/edspace"` | App image. Overridable for air-gapped mirrors. |
| image.tag | string | `""` | Image tag; defaults to the chart appVersion. |
| imagePullSecrets | list | `[]` | Pre-created image pull secrets, e.g. [{name: my-pull-secret}]. |
| ingress.annotations | object | `{}` | Extra ingress annotations; the chart adds none by default. |
| ingress.className | string | `"nginx"` |  |
| ingress.enabled | bool | `true` |  |
| ingress.host | string | `""` | Ingress host; defaults to app.host. |
| ingress.path | string | `"/"` |  |
| ingress.pathType | string | `"Prefix"` |  |
| ingress.tls.certManager.enabled | bool | `false` | Add the cert-manager issuer annotation and let it populate the TLS secret. |
| ingress.tls.certManager.issuer | string | `""` |  |
| ingress.tls.certManager.issuerKind | string | `"ClusterIssuer"` |  |
| ingress.tls.enabled | bool | `true` |  |
| ingress.tls.secretName | string | `""` | Existing TLS Secret name (used verbatim). Empty + certManager off = <fullname>-tls (bring your own contents). |
| lifecycle.terminationGracePeriodSeconds | int | `45` | Must exceed the app's socket-drain budget (SOCKET_DRAINER_SHUTDOWN_MS, 30s). |
| llm.apiKey | string | `""` | API key; prefer existingSecret. |
| llm.apiVersion | string | `""` | Azure OpenAI API version. |
| llm.baseUrl | string | `""` | Provider endpoint (EDSPACE_LLM_BASE_URL); required for azure. |
| llm.embeddingDeployment | string | `""` |  |
| llm.embeddingModel | string | `""` |  |
| llm.existingSecret | string | `""` |  |
| llm.existingSecretKey | string | `"llm-api-key"` |  |
| llm.provider | string | `"azure"` | LLM provider (EDSPACE_LLM_PROVIDER): azure, openai, anthropic, ... |
| llm.smallDeployment | string | `""` |  |
| llm.smallModel | string | `""` |  |
| llm.textDeployment | string | `""` | Azure deployment name for the text model. |
| llm.textModel | string | `""` | provider:model overrides; empty = app defaults. |
| mailer.existingSecret | string | `""` |  |
| mailer.existingSecretKey | string | `"mailpace-api-key"` |  |
| mailer.fromEmail | string | `""` | Verified MailPace sender address (MAILER_FROM_EMAIL). |
| mailer.fromName | string | `""` |  |
| mailer.mailpaceApiKey | string | `""` | MailPace API token — the app requires it in production. Prefer existingSecret. |
| migrate.activeDeadlineSeconds | int | `600` |  |
| migrate.backoffLimit | int | `3` |  |
| migrate.enabled | bool | `true` | Run migrations as a pre-upgrade Job so a failed migration aborts before pods roll. First install migrates at app boot. |
| migrate.resources.limits.memory | string | `"512Mi"` |  |
| migrate.resources.requests.cpu | string | `"100m"` |  |
| migrate.resources.requests.memory | string | `"256Mi"` |  |
| nameOverride | string | `""` |  |
| nodeSelector | object | `{}` |  |
| pdb.enabled | bool | `false` |  |
| pdb.minAvailable | int | `1` |  |
| podAnnotations | object | `{}` |  |
| podLabels | object | `{}` |  |
| podSecurityContext.runAsNonRoot | bool | `true` |  |
| podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| priorityClassName | string | `""` |  |
| probes.liveness.enabled | bool | `true` |  |
| probes.liveness.failureThreshold | int | `6` |  |
| probes.liveness.initialDelaySeconds | int | `10` |  |
| probes.liveness.path | string | `"/version"` |  |
| probes.liveness.periodSeconds | int | `10` |  |
| probes.liveness.timeoutSeconds | int | `5` |  |
| probes.readiness.enabled | bool | `true` |  |
| probes.readiness.failureThreshold | int | `3` |  |
| probes.readiness.initialDelaySeconds | int | `5` |  |
| probes.readiness.path | string | `"/health"` |  |
| probes.readiness.periodSeconds | int | `10` |  |
| probes.readiness.timeoutSeconds | int | `5` |  |
| probes.startup.enabled | bool | `true` |  |
| probes.startup.failureThreshold | int | `30` |  |
| probes.startup.path | string | `"/health"` |  |
| probes.startup.periodSeconds | int | `5` |  |
| registryCredentials.enabled | bool | `false` | Render a dockerconfigjson pull Secret from the credentials below. |
| registryCredentials.password | string | `""` | Per-customer registry token. |
| registryCredentials.registry | string | `"registry.edspace.io"` | Registry host the credentials apply to. |
| registryCredentials.username | string | `""` | Per-customer registry username. |
| replicaCount | int | `1` | Number of app replicas. >1 requires clustering.enabled (default on) and non-local file storage (see storage.adapter). |
| resources.limits.memory | string | `"2Gi"` |  |
| resources.requests.cpu | string | `"500m"` |  |
| resources.requests.memory | string | `"1Gi"` |  |
| secrets.autoGenerate | bool | `true` | Generate SECRET_KEY_BASE / TOKEN_SIGNING_SECRET / RELEASE_COOKIE on first install and keep them across upgrades AND uninstalls. Fine for pilots; for GitOps (Argo/Flux) or production set explicit values or existingSecret — template-only rendering cannot reuse generated values. |
| secrets.existingSecret | string | `""` | Existing Secret holding the three keys below. |
| secrets.existingSecretKeys.releaseCookie | string | `"release-cookie"` |  |
| secrets.existingSecretKeys.secretKeyBase | string | `"secret-key-base"` |  |
| secrets.existingSecretKeys.tokenSigningSecret | string | `"token-signing-secret"` |  |
| secrets.releaseCookie | string | `""` | Erlang distribution cookie; only used when clustering.enabled. |
| secrets.secretKeyBase | string | `""` |  |
| secrets.tokenSigningSecret | string | `""` |  |
| seed.activeDeadlineSeconds | int | `900` |  |
| seed.enabled | bool | `false` | Demo/seed data Job (post-install AND post-upgrade). Re-runs on every upgrade while enabled — disable again after seeding. |
| seed.resources.limits.memory | string | `"2Gi"` |  |
| seed.resources.requests.cpu | string | `"250m"` |  |
| seed.resources.requests.memory | string | `"1Gi"` |  |
| service.port | int | `80` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automount | bool | `false` | The app never calls the Kubernetes API. |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| storage.adapter | string | `"local_disk"` | Attachment storage backend: local_disk (needs persistence) or azure_blob. |
| storage.azureBlob.account | string | `""` | Storage account name (AZURE_STORAGE_ACCOUNT). |
| storage.azureBlob.container | string | `""` | Blob container, must already exist (AZURE_STORAGE_CONTAINER). |
| storage.azureBlob.existingSecret | string | `""` |  |
| storage.azureBlob.existingSecretKey | string | `"azure-storage-key"` |  |
| storage.azureBlob.key | string | `""` | Account key; prefer existingSecret. |
| storage.localDisk.persistence.accessModes | list | `["ReadWriteOnce"]` | ReadWriteOnce restricts to replicaCount 1 (schema-enforced); use an RWX class or azure_blob for multiple replicas. |
| storage.localDisk.persistence.enabled | bool | `true` | Persist uploads in a PVC. Disabling loses uploads on restart. |
| storage.localDisk.persistence.existingClaim | string | `""` |  |
| storage.localDisk.persistence.size | string | `"20Gi"` |  |
| storage.localDisk.persistence.storageClass | string | `""` |  |
| storage.localDisk.root | string | `"/app/uploads"` | Mount path / EDSPACE_FILE_STORAGE_ROOT. |
| strategy.rollingUpdate.maxSurge | int | `0` | Zero surge is required by the default ReadWriteOnce uploads PVC. Blob/RWX installs can override to maxSurge: 1, maxUnavailable: 0. |
| strategy.rollingUpdate.maxUnavailable | int | `1` |  |
| strategy.type | string | `"RollingUpdate"` |  |
| tolerations | list | `[]` |  |

