// PostgreSQL Flexible Server for one EdSpace managed-app instance.
//
// A module (not inline in mainTemplate) so the admin password can arrive as a
// @secure() parameter fed by keyVault.getSecret() — the only place Bicep
// permits that call.

param serverName string
param location string
param tags object = {}

param administratorLogin string = 'edspace'
@secure()
param administratorLoginPassword string

param skuName string = 'Standard_B2s'
param skuTier string = 'Burstable'

@minValue(32)
@maxValue(1024)
param storageSizeGB int = 32

param databaseName string = 'edspace'

// The app's Ecto migrations run CREATE EXTENSION for these; they must be
// allow-listed on the server or migrations fail on first boot.
var allowedExtensions = 'VECTOR,CITEXT,PG_TRGM'

// App pool math: POOL_SIZE(30) x POOL_COUNT(2) = 60 per node, plus
// migrations/Oban/operator headroom (see docs/database.md in this repo).
var maxConnections = '100'

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
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
    administratorLoginPassword: administratorLoginPassword
    storage: {
      storageSizeGB: storageSizeGB
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
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

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
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
resource allowAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: server
  name: 'AllowAllAzureServicesAndResourcesWithinAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
  dependsOn: [database] // flexible server allows one mutating operation at a time
}

resource extensionsConfig 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: server
  name: 'azure.extensions'
  properties: {
    value: allowedExtensions
    source: 'user-override'
  }
  dependsOn: [allowAzureServices]
}

resource maxConnectionsConfig 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: server
  name: 'max_connections'
  properties: {
    value: maxConnections
    source: 'user-override'
  }
  dependsOn: [extensionsConfig]
}

output fqdn string = server.properties.fullyQualifiedDomainName
output adminLogin string = administratorLogin
output databaseName string = databaseName
