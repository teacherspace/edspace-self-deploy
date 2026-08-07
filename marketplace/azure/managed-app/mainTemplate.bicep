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
//   * Every consumer reads secrets from the vault via getSecret(), never the
//     raw params — so re-deployments with bootstrapSecrets=false are fully
//     idempotent (nothing rotates, no secure params need to be supplied).
//   * Vendor-operated redeploys MUST pass bootstrapSecrets=false. Marketplace
//     definition versions are for NEW installs only. Image-only updates use
//     `az containerapp update` and never touch this template.

targetScope = 'resourceGroup'

param location string = resourceGroup().location
param tags object = {}

// ---------------------------------------------------------------- app sizing
@allowed(['standard', 'large'])
@description('standard = 1 vCPU / 2 GiB, large = 2 vCPU / 4 GiB.')
param appSize string = 'standard'

@description('App image pinned by build.sh for each managed-app definition version; vendor-operated updates move instances forward.')
param containerImage string = '__EDSPACE_CONTAINER_IMAGE__'

// ------------------------------------------------------------------ database
param pgSkuName string = 'Standard_B2s'
param pgSkuTier string = 'Burstable'
// Upper bound is the platform maximum, NOT the UI's: storage auto-grows, and
// vendor-operated template redeploys pass the server's CURRENT size back in.
@minValue(32)
@maxValue(32767)
param pgStorageGB int = 32

// ------------------------------------------------------------------- storage
@allowed(['Standard_LRS', 'Standard_GRS'])
param storageSku string = 'Standard_LRS'

// ------------------------------------------------------------------------ AI
@description('Deploy an Azure AI Foundry account with EdSpace model deployments. When false, supply the byoLlm* parameters.')
param enableAzureAi bool = true

@description('Region for the AI account, decoupled from the app region for model availability.')
param aiLocation string = 'swedencentral'

// TODO(edspace): confirm current model catalog version strings before first
// publish; empty string lets the platform pick the default version.
param textModelVersion string = ''
param smallModelVersion string = ''
param embeddingModelVersion string = ''

@description('TPM capacity (thousands) for the text model. Draws on the CUSTOMER subscription quota in aiLocation.')
param textModelCapacity int = 50
param smallModelCapacity int = 50
param embeddingModelCapacity int = 100

param enableSpeech bool = true

// BYO LLM (used when enableAzureAi = false; expects an Azure OpenAI-compatible endpoint)
param byoLlmBaseUrl string = ''
@secure()
param byoLlmApiKey string = ''
param byoLlmTextDeployment string = ''
param byoLlmSmallDeployment string = ''
param byoLlmEmbeddingDeployment string = ''
param byoLlmApiVersion string = ''

// --------------------------------------------------------------- application
@description('Custom public hostname. Leave empty to use the generated *.azurecontainerapps.io address. Custom domains are bound post-install by EdSpace support (see README).')
param customDomain string = ''

@secure()
param mailpaceApiKey string = ''
param mailFromEmail string
param mailFromName string = 'EdSpace'

// ------------------------------------------------------------------- license
param registryServer string = 'registry.edspace.io'
param registryUsername string
@secure()
param registryPassword string = ''

// ------------------------------------------------------------------- secrets
@description('Persist generated + user-supplied secrets into the instance Key Vault. true on first install ONLY; vendor-operated redeploys MUST pass false.')
param bootstrapSecrets bool = true

// newGuid() is only legal in parameter defaults. Two GUIDs minus dashes =
// 64 chars, satisfying Phoenix's SECRET_KEY_BASE length requirement.
@secure()
param secretKeyBaseSeed string = '${newGuid()}${newGuid()}'
@secure()
param tokenSigningSeed string = newGuid()
@secure()
param pgPasswordSeed string = newGuid()

// ------------------------------------------------------------------- naming
var suffix = uniqueString(resourceGroup().id) // stable per instance -> idempotent re-deploys
// Exact, publisher-owned discovery marker. Customer-supplied tags are retained.
var resourceTags = union(tags, { 'edspace.io/product': 'edspace' })

var logAnalyticsName = 'log-edspace-${suffix}'
var acaEnvName = 'cae-edspace-${suffix}'
var pgServerName = 'pg-edspace-${suffix}' // global DNS name -> suffix mandatory
var storageAccountName = 'stedspace${suffix}' // 22 chars, <= 24 limit
var keyVaultName = 'kv-eds-${suffix}' // 20 chars, <= 24 limit
var aiAccountName = 'aif-edspace-${suffix}'
var storageContainerName = 'uploads'

// ------------------------------------------------------------ observability
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
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
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
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

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource uploadsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
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

var modelDeployments = [
  {
    name: 'gpt-5.4'
    capacity: textModelCapacity
    model: union({ format: 'OpenAI', name: 'gpt-5.4' }, empty(textModelVersion) ? {} : { version: textModelVersion })
  }
  {
    name: 'gpt-5-mini'
    capacity: smallModelCapacity
    model: union({ format: 'OpenAI', name: 'gpt-5-mini' }, empty(smallModelVersion) ? {} : { version: smallModelVersion })
  }
  {
    // 1536 dimensions — matches the app's fixed vector schema.
    name: 'text-embedding-3-small'
    capacity: embeddingModelCapacity
    model: union({ format: 'OpenAI', name: 'text-embedding-3-small' }, empty(embeddingModelVersion) ? {} : { version: embeddingModelVersion })
  }
]

@batchSize(1) // one account only supports serial deployment creation
resource aiModelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2025-09-01' = [
  for d in modelDeployments: if (enableAzureAi) {
    parent: aiAccount
    name: d.name // deployment name == model name == EDSPACE_LLM_*_DEPLOYMENT value
    sku: {
      name: 'GlobalStandard'
      capacity: d.capacity
    }
    properties: {
      model: d.model
    }
  }
]

// ----------------------------------------------------------------- key vault
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: resourceTags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enabledForTemplateDeployment: true // required for getSecret() below
    enableSoftDelete: true
    enablePurgeProtection: true // the vault holds every instance secret; purge would be unrecoverable
    softDeleteRetentionInDays: 90
    enableRbacAuthorization: false
    // Publisher authorization is control-plane access on the managed RG.
    // Do not grant a publisher-tenant principal permanent customer-vault data
    // access: Key Vault callers must be registered in the vault's tenant.
    accessPolicies: []
  }
}

// A vaults/secrets PUT always writes a new version, and secure-param defaults
// re-evaluate newGuid() on every deployment — hence the bootstrapSecrets gate:
// these resources exist ONLY on first install.
resource secretKeyBaseSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'secret-key-base'
  properties: { value: replace(secretKeyBaseSeed, '-', '') }
}

resource tokenSigningSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'token-signing-secret'
  properties: { value: replace(tokenSigningSeed, '-', '') }
}

resource pgAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'pg-admin-password'
  // Prefix guarantees the 3-of-4 character classes Azure PG requires.
  properties: { value: 'E1!${replace(pgPasswordSeed, '-', '')}' }
}

resource mailpaceApiKeySecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'mailpace-api-key'
  properties: { value: mailpaceApiKey }
}

resource registryPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (bootstrapSecrets) {
  parent: keyVault
  name: 'registry-password'
  properties: { value: registryPassword }
}

// Always present so the container-app module can bind it unconditionally;
// holds the BYO key, or a placeholder when Azure AI serves the key instead.
resource llmApiKeySecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (bootstrapSecrets) {
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
    administratorLoginPassword: keyVault.getSecret('pg-admin-password')
  }
  // getSecret() adds a dependency on the VAULT, not the secret — make the
  // ordering explicit (ignored when bootstrapSecrets=false skips the resource).
  dependsOn: [pgAdminPasswordSecret]
}

// ----------------------------------------------------------------------- app
// PHX_HOST is resolvable before the app exists: the app's fixed name is
// `edspace`, so its FQDN is edspace.<environment default domain>.
var phxHost = empty(customDomain) ? 'edspace.${acaEnv.properties.defaultDomain}' : customDomain

module app 'modules/containerApp.bicep' = {
  name: 'edspace-app'
  params: {
    location: location
    tags: resourceTags
    environmentId: acaEnv.id
    containerImage: containerImage
    appSize: appSize
    phxHost: phxHost

    registryServer: registryServer
    registryUsername: registryUsername
    registryPassword: keyVault.getSecret('registry-password')

    pgAdminLogin: postgres.outputs.adminLogin
    pgFqdn: postgres.outputs.fqdn
    pgDatabaseName: postgres.outputs.databaseName
    pgAdminPassword: keyVault.getSecret('pg-admin-password')

    secretKeyBase: keyVault.getSecret('secret-key-base')
    tokenSigningSecret: keyVault.getSecret('token-signing-secret')
    mailpaceApiKey: keyVault.getSecret('mailpace-api-key')
    llmApiKeyFromKv: keyVault.getSecret('llm-api-key')
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
    llmTextDeployment: enableAzureAi ? 'gpt-5.4' : byoLlmTextDeployment
    llmSmallDeployment: enableAzureAi ? 'gpt-5-mini' : byoLlmSmallDeployment
    llmEmbeddingDeployment: enableAzureAi ? 'text-embedding-3-small' : byoLlmEmbeddingDeployment
    llmApiVersion: byoLlmApiVersion

    speechEnabled: enableAzureAi && enableSpeech
    speechRegion: enableAzureAi && enableSpeech ? aiLocation : ''

    mailFromEmail: mailFromEmail
    mailFromName: mailFromName
  }
  dependsOn: [
    secretKeyBaseSecret
    tokenSigningSecret
    pgAdminPasswordSecret
    mailpaceApiKeySecret
    registryPasswordSecret
    llmApiKeySecret
    aiModelDeployments
    uploadsContainer
  ]
}

// ------------------------------------------------------------------- outputs
output appUrl string = 'https://${app.outputs.fqdn}'
output appFqdn string = app.outputs.fqdn
output postgresFqdn string = postgres.outputs.fqdn
output storageAccountName string = storage.name
output keyVaultName string = keyVault.name
output aiAccountName string = enableAzureAi ? aiAccountName : ''
