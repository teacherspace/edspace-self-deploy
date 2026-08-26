// EdSpace — Azure Managed Application main template.
//
// Deploys one complete EdSpace instance into the managed resource group:
// Log Analytics + Container Apps environment, the EdSpace container app,
// PostgreSQL Flexible Server, Blob storage, an instance Key Vault holding
// all generated/user secrets, and (optionally) an Azure AI Foundry account
// with the model deployments EdSpace needs.
//
// SECRET MODEL (read before editing — see README.md for the full runbook):
//   * First deploy runs with bootstrapSecrets=true (createUiDefinition pins
//     it): @secure() params defaulting to newGuid() are persisted into the
//     instance Key Vault.
//   * The container app binds every vault secret as an ACA Key Vault
//     reference (read at runtime by a user-assigned identity), and PostgreSQL
//     only receives its password at bootstrap — so re-deployments with
//     bootstrapSecrets=false are fully idempotent (nothing rotates, no secure
//     params need to be supplied).
//   * No keyVault.getSecret(): ARM resolves those during pre-flight
//     validation, before anything exists, so a fresh install would fail with
//     KeyVaultParameterReferenceNotFound.
//   * Vendor-operated redeploys MUST pass bootstrapSecrets=false. Marketplace
//     definition versions are for NEW installs only. Image-only updates use
//     `az containerapp update` and never touch this template.

targetScope = 'resourceGroup'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Extra tags applied to every deployed resource (merged with the publisher marker tag).')
param tags object = {}

// ---------------------------------------------------------------- app sizing
@allowed(['standard', 'large'])
@description('standard = 1 vCPU / 2 GiB, large = 2 vCPU / 4 GiB.')
param appSize string = 'standard'

@description('App image pinned by build.sh for each managed-app definition version; vendor-operated updates move instances forward.')
param containerImage string = '__EDSPACE_CONTAINER_IMAGE__'

// ------------------------------------------------------------------ database
@description('PostgreSQL Flexible Server compute SKU (e.g. Standard_B2s, Standard_D2ds_v5).')
param pgSkuName string = 'Standard_B2s'

@allowed(['Burstable', 'GeneralPurpose', 'MemoryOptimized'])
@description('PostgreSQL compute tier; must match pgSkuName\'s family.')
param pgSkuTier string = 'Burstable'

// Upper bound is the platform maximum, NOT the UI's: storage auto-grows, and
// vendor-operated template redeploys pass the server's CURRENT size back in.
@description('PostgreSQL storage in GiB. Auto-grow is enabled; redeploys must pass the server\'s current size.')
@minValue(32)
@maxValue(32767)
param pgStorageGB int = 32

@description('Days PostgreSQL daily backups are retained.')
@minValue(7)
@maxValue(35)
param pgBackupRetentionDays int = 7

// Create-time only: Azure does not allow toggling geo-redundancy on an
// existing flexible server, so redeploys must pass the original value.
@description('Replicate PostgreSQL backups to the paired Azure region for cross-region restore (adds backup cost; can only be chosen at first deployment).')
param pgGeoRedundantBackup bool = false

// ------------------------------------------------------------------- storage
@allowed(['Standard_LRS', 'Standard_GRS'])
@description('Redundancy for the uploads storage account (LRS = single region, GRS = geo-replicated).')
param storageSku string = 'Standard_LRS'

// ------------------------------------------------------------------------ AI
@description('Deploy an Azure AI Foundry account with EdSpace model deployments. When false, supply the byoLlm* parameters.')
param enableAzureAi bool = true

@description('Region for the AI account, decoupled from the app region for model availability.')
param aiLocation string = 'swedencentral'

// Model catalog versions are pinned inline on each entry in `modelDeployments`
// below, sourced from infrastructure/iac-ai-foundry (the same set EdSpace runs
// internally). They are deliberately NOT parameters: an unpinned deployment
// silently follows the platform default version, which drifts under customers
// between installs. Re-verify with
//     az cognitiveservices model list -l <aiLocation> -o table
// when a deploy reports an unknown version or SKU.

// CAPACITY IS A PER-REQUEST CEILING, NOT JUST A THROUGHPUT KNOB. A deployment at
// capacity N cannot admit a single request larger than N*1,000 tokens — it is
// rate-limited however long it waits, and the chat streamer parks rather than
// surfacing an error. EdSpace production hit exactly this on 2026-07-31 with a
// text model at capacity 50: one turn carrying a 23 MB PDF was ~127 K tokens,
// 2.5x the whole per-minute budget, and hung silently.
//
// 800 is derived from the app's own prompt ceilings, not guessed. On a large-window
// model `Edspace.Chat.ContextRag.Budget` bounds one turn at 400,000 reference chars
// + 1,200,000 history chars + ~122,000 tool chars; at the module's conservative
// 2.7 chars/token that is ~638 K prompt tokens, ~654 K with the 16 K system
// reservation, and up to 128 K more reserved for output — ~780 K-TPM to admit a
// single worst-case turn. Anything lower narrows the hang window instead of closing
// it. Lower these ONLY if the subscription lacks quota, and expect very large chats
// to stall if you do.
//
// Headroom check (swedencentral, 2026-08-20): every model here had an unallocated
// GlobalStandard bucket of 10,000 K-TPM (30,000 for gpt-5.1) on both EdSpace
// subscriptions, so 800 is ~8% of one bucket, and buckets are per-model.
@description('TPM capacity (thousands) for each chat/text model. Draws on the CUSTOMER subscription quota in aiLocation; each model has its own quota bucket. Sized to admit one worst-case turn (~780) — lowering it can make very large chats hang.')
param textModelCapacity int = 800
@description('TPM capacity (thousands) for each small/background model (titles, classifiers, reranking).')
param smallModelCapacity int = 200
@description('TPM capacity (thousands) for the embedding model.')
param embeddingModelCapacity int = 100

@description('Enable voice features via Azure Speech on the AI account (only applies when enableAzureAi is true).')
param enableSpeech bool = true

// BYO LLM (used when enableAzureAi = false; expects an Azure OpenAI-compatible endpoint)
@description('Base URL of your Azure OpenAI-compatible endpoint. Required when enableAzureAi is false; ignored otherwise.')
param byoLlmBaseUrl string = ''

@secure()
@description('API key for the BYO LLM endpoint. Required when enableAzureAi is false.')
param byoLlmApiKey string = ''

@description('Deployment name serving chat/text models on the BYO endpoint.')
param byoLlmTextDeployment string = ''

@description('Deployment name serving small/background models on the BYO endpoint.')
param byoLlmSmallDeployment string = ''

@description('Deployment name serving the embedding model (1536 dimensions) on the BYO endpoint.')
param byoLlmEmbeddingDeployment string = ''

@description('API version query parameter for the BYO endpoint. Leave empty for the provider default.')
param byoLlmApiVersion string = ''

// --------------------------------------------------------------- application
@description('Custom public hostname. Leave empty to use the generated *.azurecontainerapps.io address. Custom domains are bound post-install by EdSpace support (see README).')
param customDomain string = ''

@description('Transactional-email backend. "none" disables email: sign-in then uses a password and/or SSO, and invitation links are shown to the inviting admin to pass on.')
@allowed(['mailpace', 'smtp', 'none'])
param mailerAdapter string = 'mailpace'

@secure()
@description('MailPace API key. Required when the mailer is MailPace.')
param mailpaceApiKey string = ''

@description('From address for all outgoing email, verified with your provider. Required unless the mailer is "none".')
param mailFromEmail string = ''

@description('Display name for outgoing email.')
param mailFromName string = 'EdSpace'

@description('SMTP relay hostname. Required when the mailer is SMTP.')
param mailSmtpRelay string = ''

@description('SMTP relay port. 587 is the STARTTLS submission port.')
@minValue(1)
@maxValue(65535)
param mailSmtpPort int = 587

@description('Implicit TLS from the first byte, paired with port 465. Leave false for the ordinary STARTTLS submission port.')
param mailSmtpSsl bool = false

@description('SMTP username. Leave empty for a relay that does not authenticate.')
param mailSmtpUsername string = ''

@secure()
@description('SMTP password for the username above.')
param mailSmtpPassword string = ''

// -------------------------------------------------------------------- sign-in
// Microsoft Entra ID single sign-on. Off by default: the app boots without any
// SSO provider and users sign in by magic link / password. Other providers
// (UniLogin, Praxis) stay CLI-only via the contract's MICROSOFT_/UNILOGIN_ vars.
@description('Offer "Sign in with Microsoft" (Entra ID, OIDC). Requires an app registration in your tenant whose redirect URI is https://<app host>/auth/microsoft/callback.')
param enableMicrosoftSso bool = false

@description('Entra tenant to accept sign-ins from: your Directory (tenant) ID, or "organizations" for any work/school account. "common" additionally admits personal Microsoft accounts. Read only when Microsoft SSO is enabled.')
param microsoftTenantId string = ''

@description('Application (client) ID of the Entra app registration. Required when Microsoft SSO is enabled.')
param microsoftClientId string = ''

@secure()
@description('Client secret of the Entra app registration. Required when Microsoft SSO is enabled.')
param microsoftClientSecret string = ''

// ------------------------------------------------------------------- license
@description('Container registry host serving the EdSpace image. Leave at the default unless EdSpace support directs otherwise.')
param registryServer string = 'edspace.azurecr.io'

@description('Per-customer registry username from your EdSpace welcome email.')
param registryUsername string

@secure()
@description('Per-customer registry password/token from your EdSpace welcome email.')
param registryPassword string = ''

// ------------------------------------------------------------------- secrets
@description('Persist generated + user-supplied secrets into the instance Key Vault. true on first install ONLY; vendor-operated redeploys MUST pass false.')
param bootstrapSecrets bool = true

// newGuid() is only legal in parameter defaults. Two GUIDs minus dashes =
// 64 chars, satisfying Phoenix's SECRET_KEY_BASE length requirement.
@secure()
@description('Entropy seed for the generated SECRET_KEY_BASE. Leave at the default; only read when bootstrapSecrets is true.')
param secretKeyBaseSeed string = '${newGuid()}${newGuid()}'

@secure()
@description('Entropy seed for the generated TOKEN_SIGNING_SECRET. Leave at the default; only read when bootstrapSecrets is true.')
param tokenSigningSeed string = newGuid()

@secure()
@description('Entropy seed for the generated PostgreSQL admin password. Leave at the default; only read when bootstrapSecrets is true.')
param pgPasswordSeed string = newGuid()

// ------------------------------------------------------------------- naming
var suffix = uniqueString(resourceGroup().id) // stable per instance -> idempotent re-deploys
// Exact, publisher-owned discovery marker. Customer-supplied tags are retained.
// No '/' in the key: ARM rejects it for non-hidden tags (InvalidTagNameCharacters).
var resourceTags = union(tags, { 'edspace-product': 'edspace' })

var logAnalyticsName = 'log-edspace-${suffix}'
var acaEnvName = 'cae-edspace-${suffix}'
var pgServerName = 'pg-edspace-${suffix}' // global DNS name -> suffix mandatory
var storageAccountName = 'stedspace${suffix}' // 22 chars, <= 24 limit
var keyVaultName = 'kv-eds-${suffix}' // 20 chars, <= 24 limit
var appIdentityName = 'id-edspace-${suffix}'
var aiAccountName = 'aif-edspace-${suffix}'
var storageContainerName = 'uploads'

// ------------------------------------------------------------ observability
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: logAnalyticsName
  location: location
  tags: resourceTags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource acaEnv 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: acaEnvName
  location: location
  tags: resourceTags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        #disable-next-line use-secure-value-for-secure-inputs // workspace shared key is write-only here; not exposed as an output
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    // Workload-profiles environment: per-replica ceiling 4 vCPU / 8 GiB
    // (plain consumption-only envs cap at 2 vCPU / 4 GiB).
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// ------------------------------------------------------------------- storage
resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  tags: resourceTags
  kind: 'StorageV2'
  sku: { name: storageSku }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true // the app authenticates with the account key
    encryption: {
      requireInfrastructureEncryption: true
      keySource: 'Microsoft.Storage'
      services: {
        blob: { enabled: true }
        file: { enabled: true }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storage
  name: 'default'
}

resource uploadsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: blobService
  name: storageContainerName
  properties: { publicAccess: 'None' }
}

// ------------------------------------------------------------------------ AI
// Top-level (NOT a module): listKeys() on a conditional resource referenced
// through its symbolic name compiles to a lazily-evaluated ARM if() — safe.
// Routing keys through module outputs would leak them into deployment history.
resource aiAccount 'Microsoft.CognitiveServices/accounts@2025-09-01' = if (enableAzureAi) {
  name: aiAccountName
  location: aiLocation
  tags: resourceTags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: aiAccountName // required for key-based endpoint auth
    publicNetworkAccess: 'Enabled'
  }
}

// EVERY model a school admin can select in EdSpace's AI settings must exist here.
// The app carries a hardcoded registry (`Edspace.LLM.Models`) that populates the
// text-model dropdown and the backoffice small-model default; an admin picking a
// model with no deployment behind it gets an unknown-deployment failure on the
// next turn, with nothing in the install to hint at why. The list below is that
// registry — text models, small models and the embedding model — cross-checked
// against infrastructure/iac-ai-foundry, which deploys the same set internally.
//
// `gpt-5.6-terra` appears in both the text and small registries; it is ONE
// deployment serving both roles, hence 8 entries for 8 selectable models.
//
// Deliberately absent, though infrastructure deploys them: `gpt-5.5` and
// `text-embedding-3-large`. No app code path can reach either, and each would
// draw customer quota for nothing. Add them here if the app registry gains them.
//
// SKU: infrastructure uses DataZoneStandard (EU data zone). Marketplace installs
// land in the customer's own subscription and region, so GlobalStandard is the
// portable choice — per-entry, because SKU availability is per-model and per-region.
// A model that fails on SKU availability is a one-line change to its entry.
var modelDeployments = [
  {
    name: 'gpt-5.1'
    capacity: textModelCapacity
    sku: 'GlobalStandard'
    model: { format: 'OpenAI', name: 'gpt-5.1', version: '2025-11-13' }
  }
  {
    // The app's default text model — `EDSPACE_LLM_TEXT_MODEL` is unset on a
    // marketplace install, so every chat turn lands here unless an admin picks
    // otherwise. Keep its capacity at or above the others.
    name: 'gpt-5.4'
    capacity: textModelCapacity
    sku: 'GlobalStandard'
    model: { format: 'OpenAI', name: 'gpt-5.4', version: '2026-03-05' }
  }
  {
    name: 'gpt-5.6-sol'
    capacity: textModelCapacity
    sku: 'GlobalStandard'
    model: { format: 'OpenAI', name: 'gpt-5.6-sol', version: '2026-07-09' }
  }
  {
    // Selectable as a text model AND as the platform small-model default.
    name: 'gpt-5.6-terra'
    capacity: textModelCapacity
    sku: 'GlobalStandard'
    model: { format: 'OpenAI', name: 'gpt-5.6-terra', version: '2026-07-09' }
  }
  {
    // Small-model only. Sized like a text model anyway: the same worst-case
    // context reaches the reranker/classifier path.
    name: 'gpt-5.6-luna'
    capacity: smallModelCapacity
    sku: 'GlobalStandard'
    model: { format: 'OpenAI', name: 'gpt-5.6-luna', version: '2026-07-09' }
  }
  {
    // The app's default small model (`EDSPACE_LLM_SMALL_MODEL`).
    name: 'gpt-5-mini'
    capacity: smallModelCapacity
    sku: 'GlobalStandard'
    model: { format: 'OpenAI', name: 'gpt-5-mini', version: '2025-08-07' }
  }
  {
    // Sold directly by Azure — deploys on the AIServices account with no
    // Marketplace subscription. Note the non-OpenAI format string and the
    // case-sensitive deployment name: the app's registry routes
    // `azure:mistral-large-3` to deployment `Mistral-Large-3`, and Azure
    // deployment names are case-sensitive.
    name: 'Mistral-Large-3'
    capacity: textModelCapacity
    sku: 'GlobalStandard'
    model: { format: 'Mistral AI', name: 'Mistral-Large-3', version: '1' }
  }
  {
    // 1536 dimensions — matches the app's fixed vector schema.
    name: 'text-embedding-3-small'
    capacity: embeddingModelCapacity
    sku: 'GlobalStandard'
    model: { format: 'OpenAI', name: 'text-embedding-3-small', version: '1' }
  }
]

@batchSize(1) // one account only supports serial deployment creation
resource aiModelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2025-09-01' = [
  for d in modelDeployments: if (enableAzureAi) {
    parent: aiAccount
    name: d.name // deployment name == model name == EDSPACE_LLM_*_DEPLOYMENT value
    sku: {
      name: d.sku
      capacity: d.capacity
    }
    properties: {
      model: d.model
    }
  }
]

// ----------------------------------------------------------------- key vault
// The app reads its secrets from the vault at runtime through this identity.
// User-assigned rather than the app's own system identity: ACA resolves Key
// Vault references when the app is created, so the access policy must exist
// before the app does.
resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: appIdentityName
  location: location
  tags: resourceTags
}

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: keyVaultName
  location: location
  tags: resourceTags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableSoftDelete: true
    enablePurgeProtection: true // the vault holds every instance secret; purge would be unrecoverable
    softDeleteRetentionInDays: 90
    enableRbacAuthorization: false
    // The app identity is the ONLY data-plane principal. Publisher
    // authorization is control-plane access on the managed RG; do not grant a
    // publisher-tenant principal permanent customer-vault data access — Key
    // Vault callers must be registered in the vault's tenant.
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: appIdentity.properties.principalId
        permissions: { secrets: ['get'] }
      }
    ]
  }
}

// A vaults/secrets PUT always writes a new version, and secure-param defaults
// re-evaluate newGuid() on every deployment — hence the bootstrapSecrets gate:
// these resources exist ONLY on first install.
resource secretKeyBaseSecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'secret-key-base'
  properties: { value: replace(secretKeyBaseSeed, '-', '') }
}

resource tokenSigningSecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'token-signing-secret'
  properties: { value: replace(tokenSigningSeed, '-', '') }
}

// Prefix guarantees the 3-of-4 character classes Azure PG requires. Only read
// under bootstrapSecrets=true (both consumers gate on it), so the newGuid()
// default never rotates anything on a redeploy.
var pgAdminPassword = 'E1!${replace(pgPasswordSeed, '-', '')}'

resource pgAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'pg-admin-password'
  properties: { value: pgAdminPassword }
}

// The app binds DATABASE_URL straight from the vault, so the composed URL is
// persisted alongside the raw password. uriComponent() guards against
// URL-reserved characters; ?ssl=true because Azure PG enforces TLS
// (require_secure_transport=on). Depends on the server via its fqdn output.
resource databaseUrlSecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'database-url'
  properties: {
    value: 'ecto://${postgres.outputs.adminLogin}:${uriComponent(pgAdminPassword)}@${postgres.outputs.fqdn}:5432/${postgres.outputs.databaseName}?ssl=true'
  }
}

// Both mailer credentials are always created, with a placeholder when the
// selected adapter does not use them (Key Vault rejects an empty value). The
// container-app module only reads the one its adapter uses, but keeping every
// secret present means a later bootstrapSecrets=false redeploy that switches
// adapter or enables SSO finds its secret already in the vault.
// Instances installed before smtp-password / microsoft-client-secret existed
// must seed them by hand before such a redeploy — see README "Secret model".
resource mailpaceApiKeySecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'mailpace-api-key'
  // Placeholder ONLY when another adapter is selected; under 'mailpace' the
  // real key goes in unmodified. The *Checked variable carries the guard that
  // rejects an empty key outright, so this never writes a blank credential.
  properties: { value: mailerAdapter == 'mailpace' ? mailpaceApiKeyChecked : 'unused-mailer-adapter-${mailerAdapter}' }
}

// An SMTP relay on a trusted network may take no credentials at all, so the
// placeholder also stands in for "no authentication". Reading the *Checked
// variable here is what makes the username/password pairing guard reachable.
resource smtpPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'smtp-password'
  properties: { value: mailerAdapter == 'smtp' && !empty(mailSmtpUsernameChecked) ? mailSmtpPassword : 'unused-mailer-adapter-${mailerAdapter}' }
}

// Same always-created / placeholder-when-disabled pattern as the mailer
// credentials.
resource microsoftClientSecretSecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'microsoft-client-secret'
  properties: { value: enableMicrosoftSso ? microsoftClientSecretChecked : 'unused-microsoft-sso-disabled' }
}

resource registryPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'registry-password'
  properties: { value: registryPassword }
}

// Always present so a later redeploy that switches to BYO finds it; holds the
// BYO key, or a placeholder when Azure AI serves the key instead (the app
// module then binds the AI key and never reads this secret).
resource llmApiKeySecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'llm-api-key'
  properties: { value: enableAzureAi ? 'unused-azure-ai-enabled' : byoLlmApiKey }
}

// ------------------------------------------------------------------ database
module postgres 'modules/postgres.bicep' = {
  name: 'edspace-postgres'
  params: {
    serverName: pgServerName
    location: location
    tags: resourceTags
    skuName: pgSkuName
    skuTier: pgSkuTier
    storageSizeGB: pgStorageGB
    backupRetentionDays: pgBackupRetentionDays
    geoRedundantBackup: pgGeoRedundantBackup ? 'Enabled' : 'Disabled'
    // Empty on a redeploy: the module then omits the property and the
    // existing server keeps the password the vault already holds.
    administratorLoginPassword: bootstrapSecrets ? pgAdminPassword : ''
  }
}

// ----------------------------------------------------------------------- app
// PHX_HOST is resolvable before the app exists: the app's fixed name is
// `edspace`, so its FQDN is edspace.<environment default domain>.
var generatedHost = 'edspace.${acaEnv.properties.defaultDomain}'
var phxHost = empty(customDomain) ? generatedHost : customDomain
// A custom domain is bound post-install (see the README runbook), so until
// then the app is only reachable at the generated address. Allowing both
// origins keeps the instance usable — WebSockets included — during that
// cutover; the generated host stays valid afterwards, which is harmless.
var checkOrigin = empty(customDomain)
  ? 'https://${generatedHost}'
  : 'https://${customDomain},https://${generatedHost}'

// The portal form enforces these per adapter (createUiDefinition), but a CLI
// or parameters-file deployment can omit them and would otherwise install an
// app that fails its boot check on an empty MAILER_FROM_EMAIL / relay. ARM's
// if() is lazy, so fail() only evaluates when the condition holds.
//
// A credential that is written into Key Vault gets its check gated on
// bootstrapSecrets: under bootstrapSecrets=false the vault already holds the
// value and the matching parameter is expected to arrive empty.
var mailFromEmailChecked = mailerAdapter != 'none' && empty(mailFromEmail)
  ? fail('mailFromEmail is required unless mailerAdapter is "none".')
  : mailFromEmail
var mailSmtpRelayChecked = mailerAdapter == 'smtp' && empty(mailSmtpRelay)
  ? fail('mailSmtpRelay is required when mailerAdapter is "smtp".')
  : mailSmtpRelay
// A password without a username would be silently dropped (the vault gets the
// placeholder and no MAILER_SMTP_PASSWORD is emitted), so reject the pair.
// The other order is just as broken: the app authenticates as soon as a
// username is set, so a username with no password writes an empty Key Vault
// value and the deployment dies on an opaque BadRequest after the vault,
// database and environment already exist.
var mailSmtpUsernameChecked = mailerAdapter == 'smtp' && empty(mailSmtpUsername) && !empty(mailSmtpPassword)
  ? fail('mailSmtpPassword was supplied without mailSmtpUsername; set both, or neither for an unauthenticated relay.')
  : mailerAdapter == 'smtp' && bootstrapSecrets && !empty(mailSmtpUsername) && empty(mailSmtpPassword)
      ? fail('mailSmtpUsername was supplied without mailSmtpPassword; set both, or neither for an unauthenticated relay.')
      : mailSmtpUsername
// The remaining credentials used to rely on Key Vault rejecting an empty
// secret value. That does stop the install, but only on the bootstrap path
// and only with an ARM BadRequest that names neither the parameter nor the
// feature; these say which one is missing, before anything is created.
var mailpaceApiKeyChecked = mailerAdapter == 'mailpace' && bootstrapSecrets && empty(mailpaceApiKey)
  ? fail('mailpaceApiKey is required when mailerAdapter is "mailpace".')
  : mailpaceApiKey
// Not a secret, and so not covered by the Key Vault backstop at all: an empty
// client ID reads as "provider off" to the app (see containerApp.bicep), which
// would hand back a successful deployment with the sign-in button missing.
var microsoftClientIdChecked = enableMicrosoftSso && empty(microsoftClientId)
  ? fail('microsoftClientId is required when enableMicrosoftSso is true.')
  : microsoftClientId
var microsoftClientSecretChecked = enableMicrosoftSso && bootstrapSecrets && empty(microsoftClientSecret)
  ? fail('microsoftClientSecret is required when enableMicrosoftSso is true.')
  : microsoftClientSecret

module app 'modules/containerApp.bicep' = {
  name: 'edspace-app'
  params: {
    location: location
    tags: resourceTags
    environmentId: acaEnv.id
    containerImage: containerImage
    appSize: appSize
    phxHost: phxHost
    checkOrigin: checkOrigin

    keyVaultUri: keyVault.properties.vaultUri
    identityId: appIdentity.id

    registryServer: registryServer
    registryUsername: registryUsername

    // BCP422: lazy if() — listKeys only evaluates when enableAzureAi is true,
    // so the conditional resource is guaranteed to exist at call time.
    #disable-next-line BCP422 use-secure-value-for-secure-inputs
    llmApiKeyFromAi: enableAzureAi ? aiAccount.listKeys().key1 : ''
    useAiAccountKey: enableAzureAi
    #disable-next-line BCP422 use-secure-value-for-secure-inputs // same lazy-if pattern as above
    speechKey: enableAzureAi && enableSpeech ? aiAccount.listKeys().key1 : ''

    storageAccountName: storage.name
    storageContainerName: storageContainerName
    #disable-next-line use-secure-value-for-secure-inputs // secure module param, not logged
    storageAccountKey: storage.listKeys().keys[0].value

    // TODO(edspace): confirm the endpoint shape the app expects
    // (account endpoint vs .openai.azure.com) against internal App Config.
    #disable-next-line BCP318 // lazy if(): only dereferenced when enableAzureAi is true
    llmBaseUrl: enableAzureAi ? aiAccount.properties.endpoint : byoLlmBaseUrl
    // Install defaults mirror the app's own (config/runtime.exs): gpt-5.6-sol for
    // chat, gpt-5.6-luna for background work. Model ID and deployment name are set
    // as a pair so they can never disagree — school admins can still switch to any
    // other deployed model from AI settings.
    llmTextModel: enableAzureAi ? 'azure:gpt-5.6-sol' : ''
    llmTextDeployment: enableAzureAi ? 'gpt-5.6-sol' : byoLlmTextDeployment
    llmSmallModel: enableAzureAi ? 'azure:gpt-5.6-luna' : ''
    llmSmallDeployment: enableAzureAi ? 'gpt-5.6-luna' : byoLlmSmallDeployment
    llmEmbeddingModel: enableAzureAi ? 'azure:text-embedding-3-small' : ''
    llmEmbeddingDeployment: enableAzureAi ? 'text-embedding-3-small' : byoLlmEmbeddingDeployment
    llmApiVersion: byoLlmApiVersion

    speechEnabled: enableAzureAi && enableSpeech
    speechRegion: enableAzureAi && enableSpeech ? aiLocation : ''

    mailerAdapter: mailerAdapter
    mailFromEmail: mailFromEmailChecked
    mailFromName: mailFromName
    mailSmtpRelay: mailSmtpRelayChecked
    mailSmtpPort: mailSmtpPort
    mailSmtpSsl: mailSmtpSsl
    mailSmtpUsername: mailSmtpUsernameChecked

    enableMicrosoftSso: enableMicrosoftSso
    // The app itself defaults to "common"; an explicit fallback here keeps the
    // CLI path from emitting an empty MICROSOFT_TENANT_ID.
    microsoftTenantId: empty(microsoftTenantId) ? 'common' : microsoftTenantId
    microsoftClientId: microsoftClientIdChecked
  }
  // ACA fetches every Key Vault reference when the app is created, so each
  // bound secret must already exist (no-ops when bootstrapSecrets=false).
  dependsOn: [
    secretKeyBaseSecret
    tokenSigningSecret
    databaseUrlSecret
    mailpaceApiKeySecret
    smtpPasswordSecret
    microsoftClientSecretSecret
    registryPasswordSecret
    llmApiKeySecret
    aiModelDeployments
    uploadsContainer
  ]
}

// ------------------------------------------------------------------- outputs
// appUrl is where the customer signs in: the custom domain once it is
// bound, or the generated address. appFqdn is always the generated ACA
// address — it is the CNAME target of the custom-domain runbook, and the
// fallback URL while the custom domain is still being bound.
output appUrl string = 'https://${phxHost}'
output appFqdn string = app.outputs.fqdn
output postgresFqdn string = postgres.outputs.fqdn
output storageAccountName string = storage.name
output keyVaultName string = keyVault.name
output aiAccountName string = enableAzureAi ? aiAccountName : ''
// Always emitted so a customer enabling SSO later knows the exact URI to
// register; MICROSOFT_REDIRECT_URI in the app is set from the same host, so
// the two can never disagree (with a custom domain this is the custom host).
output microsoftRedirectUri string = 'https://${phxHost}/auth/microsoft/callback'
