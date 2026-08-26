// EdSpace — update an existing self-managed Azure instance to a new release.
//
// This is the template behind the README's "Update EdSpace" button. It is
// deliberately NOT a redeploy of mainTemplate.bicep: that one needs every
// install parameter again and, with bootstrapSecrets left at its default,
// rotates every generated secret. A routine release changes exactly one thing
// — the container image — so this template changes exactly one thing.
//
// It does so the way the docs already tell operators to, `az containerapp
// update --image`, run inside a deployment script with a scoped identity, then
// waits for the new revision to pass its probes. ARM cannot express that as a
// resource: a PUT on Microsoft.App/containerApps is a full replacement, and
// reproducing the app's env/secret/probe block here would fork mainTemplate.
//
// Rollout semantics come from ACA itself: the app runs in Single revision
// mode, so traffic moves to the new revision only after its startup and
// readiness probes pass. A release that fails to boot leaves the previous
// revision serving; this template then fails, and the script output says why.
//
// Requirements on the person deploying it: Owner (or User Access
// Administrator) on the resource group — the template assigns a role. That
// is the same right the original install needed.
targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Release image. The default is the pin this template was built with; customers normally leave it alone.')
param containerImage string = '__EDSPACE_CONTAINER_IMAGE__'

@description('Name of the Container App created by the install template.')
param containerAppName string = 'edspace'

// A deployment script only re-runs when this changes. Defaulting it to the
// deployment time makes every click of the button a real update, including
// a retry of the same version.
param forceUpdateTag string = utcNow()

@description('Consistent with mainTemplate: one stable suffix per resource group.')
var suffix = uniqueString(resourceGroup().id)

// Same rule as build.sh: a floating tag would make the button install
// whatever the registry holds that day, not the release it was cut for.
var imageChecked = (endsWith(containerImage, ':latest') || !contains(containerImage, ':'))
  ? fail('containerImage must be an immutable release tag or digest, not ":latest" or untagged')
  : containerImage

resource app 'Microsoft.App/containerApps@2025-01-01' existing = {
  name: containerAppName
}

// Dedicated identity for the updater — the app's own identity has only a
// Key Vault access policy and must stay that way.
resource updaterIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-edspace-updater-${suffix}'
  location: location
}

// Container Apps Contributor, scoped to the resource group: `az containerapp
// update` reads the app and its environment and writes the app. Nothing
// else in the group (vault, database, storage) is reachable through it.
resource updaterRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, updaterIdentity.id, 'ContainerAppsContributor')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '358470bc-b998-42bd-ab17-a7e34c199c0f'
    )
    principalId: updaterIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource update 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'edspace-update'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${updaterIdentity.id}': {} }
  }
  dependsOn: [updaterRole]
  properties: {
    // Pin, do not float: the script below is tested against one CLI.
    azCliVersion: '2.86.0'
    forceUpdateTag: forceUpdateTag
    // bin/server runs migrations before binding the port and the startup
    // probe allows five minutes for that; add pull time and a margin.
    timeout: 'PT30M'
    retentionInterval: 'PT1H'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'APP', value: containerAppName }
      { name: 'RG', value: resourceGroup().name }
      { name: 'IMAGE', value: imageChecked }
    ]
    scriptContent: loadTextContent('update.sh')
  }
}

output previousImage string = update.properties.outputs.previousImage
output newImage string = update.properties.outputs.newImage
output revision string = update.properties.outputs.revision
output appUrl string = 'https://${app.properties.configuration.ingress.fqdn}'
