{{/* Standard naming */}}
{{- define "edspace.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "edspace.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "edspace.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "edspace.labels" -}}
helm.sh/chart: {{ include "edspace.chart" . }}
{{ include "edspace.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "edspace.selectorLabels" -}}
app.kubernetes.io/name: {{ include "edspace.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
App-pod selector: selectorLabels alone also match the bundled Postgres and
hook Job pods (they add their own component label), so anything that must
target ONLY the app pods (Deployment, Services, PDB) selects on this.
*/}}
{{- define "edspace.appSelectorLabels" -}}
{{ include "edspace.selectorLabels" . }}
app.kubernetes.io/component: app
{{- end }}

{{- define "edspace.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "edspace.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "edspace.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}

{{/* imagePullSecrets: user-provided merged with the rendered registry secret */}}
{{- define "edspace.imagePullSecrets" -}}
{{- $secrets := list }}
{{- range .Values.imagePullSecrets }}
{{- $secrets = append $secrets . }}
{{- end }}
{{- if .Values.registryCredentials.enabled }}
{{- $secrets = append $secrets (dict "name" (printf "%s-registry" (include "edspace.fullname" .))) }}
{{- end }}
{{- with $secrets }}
imagePullSecrets:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* ---------------------------------------------------------------- database */}}

{{- define "edspace.dbUrlQuery" -}}
{{- if and (not .Values.db.bundled.enabled) (eq .Values.db.sslMode "require") }}?ssl=true{{- end }}
{{- end }}

{{/*
DATABASE_URL mode (a): external DB with a chart-known password.
Rendered into the chart-managed Secret. urlquery protects reserved characters.
*/}}
{{- define "edspace.databaseUrl" -}}
{{- $db := .Values.db -}}
ecto://{{ $db.username }}:{{ $db.password | urlquery }}@{{ $db.host }}:{{ $db.port }}/{{ $db.database }}{{ include "edspace.dbUrlQuery" . }}
{{- end }}

{{/*
Explicit env entries composing DATABASE_URL when the password is not known at
render time. Bundled PG and mode (c) use kubelet $(DB_PASSWORD) expansion;
mode (b) references a complete URL key. Mode (a) emits nothing (envFrom).
*/}}
{{- define "edspace.databaseEnv" -}}
{{- $db := .Values.db }}
{{- if $db.bundled.enabled }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "edspace.fullname" . }}-db
      key: postgres-password
- name: DATABASE_URL
  value: "ecto://{{ $db.bundled.username }}:$(DB_PASSWORD)@{{ include "edspace.fullname" . }}-db:5432/{{ $db.bundled.database }}"
{{- else if $db.existingSecret }}
{{- if $db.existingSecretKeys.url }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ $db.existingSecret }}
      key: {{ $db.existingSecretKeys.url }}
{{- else }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $db.existingSecret }}
      key: {{ $db.existingSecretKeys.password | default "password" }}
- name: DATABASE_URL
  value: "ecto://{{ $db.username }}:$(DB_PASSWORD)@{{ $db.host }}:{{ $db.port }}/{{ $db.database }}{{ include "edspace.dbUrlQuery" . }}"
{{- end }}
{{- end }}
{{- end }}

{{/* ----------------------------------------------------------------- secrets */}}

{{/*
Explicit env refs for SECRET_KEY_BASE / TOKEN_SIGNING_SECRET when they live in
the generated or a customer Secret. With explicit values (autoGenerate=false,
no existingSecret) they flow through the chart Secret via envFrom instead.
*/}}
{{- define "edspace.coreSecretEnv" -}}
{{- $s := .Values.secrets }}
{{- if $s.existingSecret }}
- name: SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: {{ $s.existingSecret }}
      key: {{ $s.existingSecretKeys.secretKeyBase }}
- name: TOKEN_SIGNING_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ $s.existingSecret }}
      key: {{ $s.existingSecretKeys.tokenSigningSecret }}
{{- else if $s.autoGenerate }}
- name: SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: {{ include "edspace.fullname" . }}-generated
      key: secret-key-base
- name: TOKEN_SIGNING_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "edspace.fullname" . }}-generated
      key: token-signing-secret
{{- end }}
{{- end }}

{{/* RELEASE_COOKIE env entry (clustering only) */}}
{{- define "edspace.releaseCookieEnv" -}}
{{- $s := .Values.secrets }}
{{- if $s.existingSecret }}
- name: RELEASE_COOKIE
  valueFrom:
    secretKeyRef:
      name: {{ $s.existingSecret }}
      key: {{ $s.existingSecretKeys.releaseCookie }}
{{- else if $s.autoGenerate }}
- name: RELEASE_COOKIE
  valueFrom:
    secretKeyRef:
      name: {{ include "edspace.fullname" . }}-generated
      key: release-cookie
{{- else if not $s.releaseCookie }}
{{- fail "secrets.releaseCookie is required when clustering.enabled and secrets.autoGenerate=false without secrets.existingSecret" }}
{{- end }}
{{- end }}

{{/* Integration secrets referenced from customer-managed Secrets */}}
{{- define "edspace.integrationSecretEnv" -}}
{{- with .Values.llm }}
{{- if .existingSecret }}
- name: EDSPACE_LLM_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .existingSecretKey | default "llm-api-key" }}
{{- end }}
{{- end }}
{{/* The mailer credential is the MailPace API key or the SMTP password,
depending on the adapter; `none` has no credential at all. */}}
{{- with .Values.mailer }}
{{- if and .existingSecret (eq .adapter "mailpace") }}
- name: MAILPACE_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .existingSecretKey | default "mailpace-api-key" }}
{{- else if and .existingSecret (eq .adapter "smtp") }}
- name: MAILER_SMTP_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .existingSecretKey | default "smtp-password" }}
{{- end }}
{{- end }}
{{- if eq .Values.storage.adapter "azure_blob" }}
{{- with .Values.storage.azureBlob }}
{{- if .existingSecret }}
- name: AZURE_STORAGE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .existingSecretKey | default "azure-storage-key" }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/* Env entries shared by the app container and the hook Jobs */}}
{{- define "edspace.sharedEnv" -}}
{{- include "edspace.databaseEnv" . }}
{{- include "edspace.coreSecretEnv" . }}
{{- include "edspace.integrationSecretEnv" . }}
{{- end }}

{{/* --------------------------------------------------------- env data blocks */}}

{{/* Non-secret env data (ConfigMap); shared by main and hook copies */}}
{{- define "edspace.envConfigData" -}}
PHX_HOST: {{ required "app.host is required" .Values.app.host | quote }}
{{- with .Values.app.checkOrigin }}
PHX_CHECK_ORIGIN: {{ . | quote }}
{{- end }}
EDSPACE_FILE_STORAGE_ADAPTER: {{ .Values.storage.adapter | quote }}
{{- if eq .Values.storage.adapter "local_disk" }}
EDSPACE_FILE_STORAGE_ROOT: {{ .Values.storage.localDisk.root | quote }}
{{- end }}
{{- if eq .Values.storage.adapter "azure_blob" }}
AZURE_STORAGE_ACCOUNT: {{ required "storage.azureBlob.account is required with the azure_blob adapter" .Values.storage.azureBlob.account | quote }}
AZURE_STORAGE_CONTAINER: {{ required "storage.azureBlob.container is required with the azure_blob adapter" .Values.storage.azureBlob.container | quote }}
{{- end }}
EDSPACE_LLM_PROVIDER: {{ .Values.llm.provider | quote }}
{{- with .Values.llm.baseUrl }}
EDSPACE_LLM_BASE_URL: {{ . | quote }}
{{- end }}
{{- with .Values.llm.apiVersion }}
EDSPACE_LLM_API_VERSION: {{ . | quote }}
{{- end }}
{{- with .Values.llm.textModel }}
EDSPACE_LLM_TEXT_MODEL: {{ . | quote }}
{{- end }}
{{- with .Values.llm.textDeployment }}
EDSPACE_LLM_TEXT_DEPLOYMENT: {{ . | quote }}
{{- end }}
{{- with .Values.llm.smallModel }}
EDSPACE_LLM_SMALL_MODEL: {{ . | quote }}
{{- end }}
{{- with .Values.llm.smallDeployment }}
EDSPACE_LLM_SMALL_DEPLOYMENT: {{ . | quote }}
{{- end }}
{{- with .Values.llm.embeddingModel }}
EDSPACE_LLM_EMBEDDING_MODEL: {{ . | quote }}
{{- end }}
{{- with .Values.llm.embeddingDeployment }}
EDSPACE_LLM_EMBEDDING_DEPLOYMENT: {{ . | quote }}
{{- end }}
{{- with .Values.mailer }}
MAILER_ADAPTER: {{ .adapter | quote }}
{{- if ne .adapter "none" }}
MAILER_FROM_EMAIL: {{ required "mailer.fromEmail is required unless mailer.adapter is none" .fromEmail | quote }}
{{- end }}
{{- with .fromName }}
MAILER_FROM_NAME: {{ . | quote }}
{{- end }}
{{- if eq .adapter "smtp" }}
{{- with .smtp }}
MAILER_SMTP_RELAY: {{ required "mailer.smtp.relay is required with mailer.adapter=smtp" .relay | quote }}
MAILER_SMTP_PORT: {{ .port | toString | quote }}
MAILER_SMTP_SSL: {{ .ssl | toString | quote }}
MAILER_SMTP_TLS_VERIFY: {{ .tlsVerify | toString | quote }}
MAILER_SMTP_NO_MX_LOOKUPS: {{ .noMxLookups | toString | quote }}
{{- with .username }}
MAILER_SMTP_USERNAME: {{ . | quote }}
{{- end }}
{{/* Empty tls/auth mean "keep the app default", which is computed from
ssl/username - emitting the variable at all would override that. */}}
{{- with .tls }}
MAILER_SMTP_TLS: {{ . | quote }}
{{- end }}
{{- with .auth }}
MAILER_SMTP_AUTH: {{ . | quote }}
{{- end }}
{{- with .caCertFile }}
MAILER_SMTP_CACERTFILE: {{ . | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- range $k, $v := .Values.env }}
{{ $k }}: {{ $v | toString | quote }}
{{- end }}
{{- end }}

{{/* Secret env data (Secret stringData); shared by main and hook copies */}}
{{- define "edspace.envSecretData" -}}
{{- $db := .Values.db }}
{{- if and (not $db.bundled.enabled) (not $db.existingSecret) }}
DATABASE_URL: {{ include "edspace.databaseUrl" . | quote }}
{{- end }}
{{- $s := .Values.secrets }}
{{- if and (not $s.autoGenerate) (not $s.existingSecret) }}
SECRET_KEY_BASE: {{ $s.secretKeyBase | quote }}
TOKEN_SIGNING_SECRET: {{ $s.tokenSigningSecret | quote }}
{{- with $s.releaseCookie }}
RELEASE_COOKIE: {{ . | quote }}
{{- end }}
{{- end }}
{{- with .Values.mailer }}
{{- if not .existingSecret }}
{{- if and (eq .adapter "mailpace") .mailpaceApiKey }}
MAILPACE_API_KEY: {{ .mailpaceApiKey | quote }}
{{- end }}
{{- if and (eq .adapter "smtp") .smtp.password }}
MAILER_SMTP_PASSWORD: {{ .smtp.password | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- if and .Values.llm.apiKey (not .Values.llm.existingSecret) }}
EDSPACE_LLM_API_KEY: {{ .Values.llm.apiKey | quote }}
{{- end }}
{{- if and (eq .Values.storage.adapter "azure_blob") .Values.storage.azureBlob.key (not .Values.storage.azureBlob.existingSecret) }}
AZURE_STORAGE_KEY: {{ .Values.storage.azureBlob.key | quote }}
{{- end }}
{{- range $k, $v := .Values.envSecret }}
{{ $k }}: {{ $v | toString | quote }}
{{- end }}
{{- end }}

{{/*
Non-secret config as explicit migration-Job env entries. Pre-upgrade hooks run
before release resources are updated, so the Job cannot reference the release
ConfigMap/Secret (it would see the previous revision's values). Secret data
takes the same fresh-values route via the hook-scoped -migrate-env Secret
(secret-migrate-env.yaml) instead of inline values, keeping credentials out of
the pod spec.
*/}}
{{- define "edspace.migrationInlineConfigEnv" -}}
{{- $config := include "edspace.envConfigData" . | fromYaml | default dict }}
{{- range $name := keys $config | sortAlpha }}
{{- if not (has $name (list "PDF_ENABLED" "POOL_COUNT" "POOL_SIZE")) }}
- name: {{ $name }}
  value: {{ get $config $name | toString | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/* Cross-field checks JSON Schema cannot express. */}}
{{- define "edspace.validateValues" -}}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas)) }}
{{- fail "autoscaling.minReplicas must be less than or equal to autoscaling.maxReplicas" }}
{{- end }}
{{- $plain := .Values.env | default dict }}
{{- range $name := keys (.Values.envSecret | default dict) }}
{{- if hasKey $plain $name }}
{{- fail (printf "%s must not be set in both env and envSecret" $name) }}
{{- end }}
{{- end }}
{{- end }}
