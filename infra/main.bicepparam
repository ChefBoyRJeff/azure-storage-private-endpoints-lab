using './main.bicep'

// Values match the portal-built lab account (verified with what-if in M6c). No secrets or IDs here.
param location = 'eastus'
param storageAccountName = 'stpelabjj1103'
param tags = {
  project: 'azure-storage-private-endpoints-lab'
}
param containerNames = [
  'tiers'
  'lifecycle'
  'scratch'
  'transfer'
]
param shareName = 'labshare'
param shareQuotaGiB = 1
param softDeleteDays = 7
param allowSharedKeyAccess = true
param publicNetworkAccess = 'Enabled'

// M4 design, off by default (private endpoints bill hourly). Flip to true to rebuild blob + file private access.
param deployPrivateEndpoints = false
param peVnetResourceGroup = 'rg-hubspoke-lab'
param peVnetName = 'vnet-spoke1'
param peSubnetName = 'snet-workload'
