// P7 M6: the storage lab codified. Written from the live export (infra/export/, gitignored), not from memory.
// Deploys: storage account, blob service (versioning + soft delete), containers, file service (SMB encryption
// in transit + share soft delete), file share, lifecycle policy, and OPTIONAL blob/file private endpoints with
// private DNS zones linked to the client VNet (M4 design; off by default because they bill hourly).
// Not deployed here: blob data, share snapshots, and personal RBAC assignments (documented in README).
targetScope = 'resourceGroup'

@description('Region for the storage account and private endpoints. Must match the client VNet when deployPrivateEndpoints is true.')
param location string

@description('Storage account name: globally unique, 3-24 lowercase letters and digits.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Tags applied to every resource.')
param tags object

@description('Blob containers to create. Access is always private (anonymous access is disabled on the account).')
param containerNames array

@description('File share name.')
param shareName string

@description('File share quota in GiB.')
@minValue(1)
param shareQuotaGiB int

@description('Soft delete retention in days for blobs, containers and file shares.')
@minValue(1)
@maxValue(365)
param softDeleteDays int = 7

@description('Allow account-key and key-signed SAS access. M3 (SMB with key) needs true; M2c showed false is the hardened setting.')
param allowSharedKeyAccess bool = true

@description('Public network access. Disabled also sets the firewall default action to Deny, matching what the portal does (M4h finding).')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('Deploy blob and file private endpoints with private DNS zones and VNet links (billed hourly; M4 design).')
param deployPrivateEndpoints bool = false

@description('Resource group of the client VNet (P1 hub-and-spoke).')
param peVnetResourceGroup string

@description('Client VNet name.')
param peVnetName string

@description('Subnet for the private endpoint NICs (private endpoint network policies must be Disabled).')
param peSubnetName string

resource sa 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: allowSharedKeyAccess
    defaultToOAuthAuthentication: false
    allowCrossTenantReplication: false
    allowedCopyScope: 'AAD' // same Entra tenant only
    dnsEndpointType: 'Standard'
    publicNetworkAccess: publicNetworkAccess
    // Both settings travel together. Re-enabling publicNetworkAccess alone left defaultAction=Deny (M4h).
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: publicNetworkAccess == 'Enabled' ? 'Allow' : 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: false
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-06-01' = {
  parent: sa
  name: 'default'
  properties: {
    isVersioningEnabled: true
    deleteRetentionPolicy: {
      enabled: true
      days: softDeleteDays
      allowPermanentDelete: false
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: softDeleteDays
    }
  }
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-06-01' = [
  for c in containerNames: {
    parent: blobService
    name: c
    properties: {
      publicAccess: 'None'
      // Declared to match what the API returns; otherwise what-if shows them as removals (M6c noise).
      defaultEncryptionScope: '$account-encryption-key'
      denyEncryptionScopeOverride: false
    }
  }
]

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2025-06-01' = {
  parent: sa
  name: 'default'
  properties: {
    protocolSettings: {
      smb: {
        encryptionInTransit: {
          required: true // M4g: SMB session showed dialect 3.1.1, encrypted=True
        }
      }
    }
    shareDeleteRetentionPolicy: {
      enabled: true
      days: softDeleteDays
    }
  }
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-06-01' = {
  parent: fileService
  name: shareName
  properties: {
    accessTier: 'TransactionOptimized'
    shareQuota: shareQuotaGiB
    enabledProtocols: 'SMB'
  }
  // No Azure Backup here on purpose (RCA-001): Bicep deploys only what is declared.
}

resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2025-06-01' = {
  parent: sa
  name: 'default'
  properties: {
    // Single source of truth: the same file applied from the CLI in M1e.
    policy: loadJsonContent('lifecycle-policy.json')
  }
  dependsOn: [
    blobService
  ]
}

resource peVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if (deployPrivateEndpoints) {
  name: peVnetName
  scope: resourceGroup(peVnetResourceGroup)
}

module privateEndpoints 'modules/private-endpoint.bicep' = [
  for groupId in ['blob', 'file']: if (deployPrivateEndpoints) {
    name: 'pe-${groupId}'
    params: {
      location: location
      tags: tags
      storageAccountId: sa.id
      storageAccountName: sa.name
      groupId: groupId
      subnetId: '${peVnet.id}/subnets/${peSubnetName}'
      vnetId: peVnet.id
    }
  }
]

output storageAccountId string = sa.id
output blobEndpoint string = sa.properties.primaryEndpoints.blob
output privateEndpointsDeployed bool = deployPrivateEndpoints
