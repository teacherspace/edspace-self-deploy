// EdSpace Container App.
//
// A module (not inline in mainTemplate) so every secret arrives as a
// @secure() parameter — either from keyVault.getSecret() or from listKeys()
// ternaries evaluated in mainTemplate. Secrets must never travel through
// module *outputs* (nested-deployment outputs are logged in deployment
// history); secure module *inputs* are not logged.

param location string
param tags object = {}
param environmentId string

param containerImage string

@allowed(['standard', 'large'])
@description('ACA enforces 1:2 vCPU:GiB pairs on Consumption; expose fixed sizes rather than free-form cpu/mem.')
param appSize string = 'standard'

// Public hostname (PHX_HOST). Computed in mainTemplate from the managed
// environment default domain, or the customer custom domain.
param phxHost string
// Comma-separated allowed WebSocket origins (PHX_CHECK_ORIGIN). Computed in
// mainTemplate: the custom domain plus the generated address during cutover.
param checkOrigin string

// --- registry ---
param registryServer string
param registryUsername string
@secure()
param registryPassword string

// --- database ---
param pgAdminLogin string
param pgFqdn string
param pgDatabaseName string
@secure()
param pgAdminPassword string

// --- app secrets ---
@secure()
param secretKeyBase string
@secure()
param tokenSigningSecret string
@secure()
param mailpaceApiKey string
@secure()
param mailSmtpPassword string = ''
@secure()
param microsoftClientSecret string = ''
// getSecret() cannot sit inside a ternary at the call site, so both sources
// arrive and the selection happens here.
@secure()
param llmApiKeyFromKv string
@secure()
param llmApiKeyFromAi string = ''
param useAiAccountKey bool
@secure()
param speechKey string = ''

// --- storage ---
param storageAccountName string
param storageContainerName string
@secure()
param storageAccountKey string

// --- LLM (plain) ---
param llmBaseUrl string
param llmTextDeployment string
param llmSmallDeployment string
param llmEmbeddingDeployment string
// Model IDs are set only on the managed-AI path, where we know which model each
// deployment serves. Leaving them empty (the BYO path) lets the app's own defaults
// apply, since a customer's endpoint may serve something else entirely. Setting the
// deployment without the matching ID is the bug this closes: the app would keep its
// default model ID, and capability gating, pricing and Langfuse telemetry would all
// be keyed to a model that never receives a request.
param llmTextModel string = ''
param llmSmallModel string = ''
param llmEmbeddingModel string = ''
param llmApiVersion string = ''

// --- speech (plain) ---
param speechEnabled bool
param speechRegion string = ''

// --- mailer (plain) ---
// 'none' is a first-class mode, not a degraded one: EdSpace only ever sends
// sign-in, password-reset and invitation mail, so a school whose users all
// arrive through SSO needs no mail provider. The app then offers a password
// form on /sign-in and hands invitation links to the inviting admin.
@allowed(['mailpace', 'smtp', 'none'])
param mailerAdapter string = 'mailpace'
param mailFromEmail string = ''
param mailFromName string = 'EdSpace'
param mailSmtpRelay string = ''
param mailSmtpPort int = 587
param mailSmtpSsl bool = false
param mailSmtpUsername string = ''

// --- Microsoft Entra ID SSO (plain) ---
// MICROSOFT_CLIENT_ID empty means "provider off" to the app, so every
// MICROSOFT_* var is emitted only when SSO is enabled: a half-set provider
// would render a sign-in button whose callback can never succeed.
param enableMicrosoftSso bool = false
param microsoftTenantId string = 'common'
param microsoftClientId string = ''

var sizes = {
  standard: { cpu: '1.0', memory: '2Gi' }
  large: { cpu: '2.0', memory: '4Gi' }
}

var llmApiKey = useAiAccountKey ? llmApiKeyFromAi : llmApiKeyFromKv

// uriComponent() guards against URL-reserved characters in the password;
// ?ssl=true because Azure PG enforces TLS (require_secure_transport=on).
var databaseUrl = 'ecto://${pgAdminLogin}:${uriComponent(pgAdminPassword)}@${pgFqdn}:5432/${pgDatabaseName}?ssl=true'

// ACA secret names must match ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$
var baseSecrets = [
  { name: 'secret-key-base', value: secretKeyBase }
  { name: 'token-signing-secret', value: tokenSigningSecret }
  { name: 'database-url', value: databaseUrl }
  { name: 'azure-storage-key', value: storageAccountKey }
  { name: 'llm-api-key', value: llmApiKey }
  { name: 'registry-password', value: registryPassword }
]
// ACA rejects empty secret values, so every conditional credential is added
// only when the adapter that uses it is selected AND a value was supplied.
var mailerSecrets = concat(
  mailerAdapter == 'mailpace' && !empty(mailpaceApiKey) ? [{ name: 'mailpace-api-key', value: mailpaceApiKey }] : [],
  mailerAdapter == 'smtp' && !empty(mailSmtpPassword) ? [{ name: 'smtp-password', value: mailSmtpPassword }] : []
)
var secrets = concat(
  baseSecrets,
  mailerSecrets,
  enableMicrosoftSso && !empty(microsoftClientSecret) ? [{ name: 'microsoft-client-secret', value: microsoftClientSecret }] : [],
  empty(speechKey) ? [] : [{ name: 'azure-speech-key', value: speechKey }]
)

var plainEnv = [
  { name: 'PHX_HOST', value: phxHost }
  { name: 'PHX_CHECK_ORIGIN', value: checkOrigin }
  { name: 'EDSPACE_FILE_STORAGE_ADAPTER', value: 'azure_blob' }
  { name: 'AZURE_STORAGE_ACCOUNT', value: storageAccountName }
  { name: 'AZURE_STORAGE_CONTAINER', value: storageContainerName }
  { name: 'EDSPACE_LLM_PROVIDER', value: 'azure' }
  { name: 'EDSPACE_LLM_BASE_URL', value: llmBaseUrl }
  { name: 'EDSPACE_LLM_TEXT_DEPLOYMENT', value: llmTextDeployment }
  { name: 'EDSPACE_LLM_SMALL_DEPLOYMENT', value: llmSmallDeployment }
  { name: 'EDSPACE_LLM_EMBEDDING_DEPLOYMENT', value: llmEmbeddingDeployment }
  { name: 'EDSPACE_SPEECH_ENABLED', value: speechEnabled ? 'true' : 'false' }
  { name: 'MAILER_ADAPTER', value: mailerAdapter }
  // Chromium sessions cost ~250Mi each; the app default of 4 risks OOM on the
  // 2 GiB standard size, so cap PDF rendering concurrency here.
  { name: 'CHROMIC_PDF_POOL_SIZE', value: '2' }
]

var secretEnv = [
  { name: 'SECRET_KEY_BASE', secretRef: 'secret-key-base' }
  { name: 'TOKEN_SIGNING_SECRET', secretRef: 'token-signing-secret' }
  { name: 'DATABASE_URL', secretRef: 'database-url' }
  { name: 'AZURE_STORAGE_KEY', secretRef: 'azure-storage-key' }
  { name: 'EDSPACE_LLM_API_KEY', secretRef: 'llm-api-key' }
]

var conditionalEnv = concat(
  empty(llmApiVersion) ? [] : [{ name: 'EDSPACE_LLM_API_VERSION', value: llmApiVersion }],
  empty(llmTextModel) ? [] : [{ name: 'EDSPACE_LLM_TEXT_MODEL', value: llmTextModel }],
  empty(llmSmallModel) ? [] : [{ name: 'EDSPACE_LLM_SMALL_MODEL', value: llmSmallModel }],
  empty(llmEmbeddingModel) ? [] : [{ name: 'EDSPACE_LLM_EMBEDDING_MODEL', value: llmEmbeddingModel }],
  empty(speechRegion) ? [] : [{ name: 'AZURE_SPEECH_REGION', value: speechRegion }],
  empty(speechKey) ? [] : [{ name: 'AZURE_SPEECH_KEY', secretRef: 'azure-speech-key' }],
  // Omitted when blank: a set-but-empty MAILER_FROM_NAME would override the
  // app's "EdSpace" default with an empty from-name.
  empty(mailFromName) ? [] : [{ name: 'MAILER_FROM_NAME', value: mailFromName }],
  // A blank MAILER_FROM_EMAIL counts as missing and fails the app's boot
  // check, so it is emitted only for the adapters that read it.
  mailerAdapter == 'none' ? [] : [{ name: 'MAILER_FROM_EMAIL', value: mailFromEmail }],
  mailerAdapter == 'mailpace' && !empty(mailpaceApiKey) ? [{ name: 'MAILPACE_API_KEY', secretRef: 'mailpace-api-key' }] : [],
  mailerAdapter == 'smtp' ? [
    { name: 'MAILER_SMTP_RELAY', value: mailSmtpRelay }
    { name: 'MAILER_SMTP_PORT', value: string(mailSmtpPort) }
    // Under implicit TLS the app flips its STARTTLS default to 'never' on its
    // own, so this one variable carries the whole choice.
    { name: 'MAILER_SMTP_SSL', value: mailSmtpSsl ? 'true' : 'false' }
  ] : [],
  mailerAdapter == 'smtp' && !empty(mailSmtpUsername) ? [{ name: 'MAILER_SMTP_USERNAME', value: mailSmtpUsername }] : [],
  mailerAdapter == 'smtp' && !empty(mailSmtpPassword) ? [{ name: 'MAILER_SMTP_PASSWORD', secretRef: 'smtp-password' }] : [],
  // Redirect URI is derived from PHX_HOST rather than asked for: it must match
  // the app registration byte-for-byte, and the host is the one thing the
  // customer cannot know before the environment exists.
  enableMicrosoftSso ? [
    { name: 'MICROSOFT_TENANT_ID', value: microsoftTenantId }
    { name: 'MICROSOFT_CLIENT_ID', value: microsoftClientId }
    { name: 'MICROSOFT_REDIRECT_URI', value: 'https://${phxHost}/auth/microsoft/callback' }
    { name: 'MICROSOFT_CLIENT_SECRET', secretRef: 'microsoft-client-secret' }
  ] : []
)

resource app 'Microsoft.App/containerApps@2025-01-01' = {
  // Fixed name: the env default domain is already unique per instance, and
  // `edspace.<defaultDomain>` gives customers a readable FQDN.
  name: 'edspace'
  location: location
  tags: tags
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 4000
        transport: 'auto' // keeps WebSockets (LiveView) working
        allowInsecure: false
      }
      registries: [
        {
          server: registryServer
          username: registryUsername
          passwordSecretRef: 'registry-password'
        }
      ]
      secrets: secrets
    }
    template: {
      containers: [
        {
          name: 'edspace'
          image: containerImage
          resources: {
            cpu: json(sizes[appSize].cpu)
            memory: sizes[appSize].memory
          }
          env: concat(plainEnv, secretEnv, conditionalEnv)
          probes: [
            {
              // bin/server runs Ecto migrations BEFORE binding the port;
              // large upgrades need the full 5-minute window.
              type: 'Startup'
              httpGet: { path: '/health', port: 4000 }
              periodSeconds: 5
              failureThreshold: 60
              timeoutSeconds: 3
            }
            {
              // /health is DB-coupled (SELECT 1) — correct traffic gate.
              type: 'Readiness'
              httpGet: { path: '/health', port: 4000 }
              periodSeconds: 30
              failureThreshold: 3
              timeoutSeconds: 5
            }
            {
              // Deliberately NOT /health: a DB outage must not restart-loop
              // the app (each restart re-runs migration checks).
              type: 'Liveness'
              tcpSocket: { port: 4000 }
              periodSeconds: 15
              failureThreshold: 3
            }
          ]
        }
      ]
      scale: {
        // v1: scale vertically via appSize. Multi-replica needs Erlang
        // clustering (DNS_CLUSTER_QUERY), which ACA does not provide.
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
