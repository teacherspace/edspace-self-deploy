// PostgreSQL Flexible Server for one EdSpace managed-app instance.
//
// A module (not inline in mainTemplate) so the admin password arrives as a
// @secure() parameter — secure nested-deployment inputs are not logged.

param serverName string
param location string
param tags object = {}

param administratorLogin string = 'edspace'
// Empty on a bootstrapSecrets=false redeploy: the property is then omitted
// from the PUT, which leaves an existing server's password untouched (Azure
// only requires it at creation). Required, non-empty, on first install.
@secure()
param administratorLoginPassword string = ''

param skuName string = 'Standard_B2s'
param skuTier string = 'Burstable'

@minValue(32)
@maxValue(32767)
param storageSizeGB int = 32

@minValue(7)
@maxValue(35)
param backupRetentionDays int = 7

// Create-time only: Azure rejects toggling geo-redundancy on an existing
// flexible server, so redeploys must pass the value chosen at first install.
@allowed(['Enabled', 'Disabled'])
param geoRedundantBackup string = 'Disabled'

param databaseName string = 'edspace'

// The app's Ecto migrations run CREATE EXTENSION for these; they must be
// allow-listed on the server or migrations fail on first boot.
var allowedExtensions = 'VECTOR,CITEXT,PG_TRGM'

// max_connections is deliberately NOT overridden: it is a static parameter
// (needs a server restart to apply), and the offered SKUs' defaults (B2s 429,
// D2ds_v5 859) already clear the app's pool math — POOL_SIZE(30) x
// POOL_COUNT(2) = 60 per node plus headroom (see docs/database.md).

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' = {
  name: serverName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: '16' // platform provisions a current minor (app requires >= 16.3)
    administratorLogin: administratorLogin
    administratorLoginPassword: empty(administratorLoginPassword) ? null : administratorLoginPassword
    storage: {
      storageSizeGB: storageSizeGB
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: geoRedundantBackup
    }
    highAvailability: {
      mode: 'Disabled' // Burstable tier does not support HA
    }
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2025-08-01' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// v1 network posture: public endpoint restricted to Azure-internal traffic
// (ACA Consumption has no stable egress IP to pin). TLS is enforced by the
// server default (require_secure_transport=on); the app connects with
// ?ssl=true. VNet isolation is the documented v2 hardening path.
resource allowAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2025-08-01' = {
  parent: server
  name: 'AllowAllAzureServicesAndResourcesWithinAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
  dependsOn: [database] // flexible server allows one mutating operation at a time
}

resource extensionsConfig 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = {
  parent: server
  name: 'azure.extensions'
  properties: {
    value: allowedExtensions
    source: 'user-override'
  }
  dependsOn: [allowAzureServices]
}

output fqdn string = server.properties.fullyQualifiedDomainName
output adminLogin string = administratorLogin
output databaseName string = databaseName
