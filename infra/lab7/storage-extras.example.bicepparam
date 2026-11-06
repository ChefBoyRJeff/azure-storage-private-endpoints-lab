// Copy to storage-extras.local.bicepparam (gitignored) and fill in. From a clean resource group run it twice:
// first with useCmk = false, then with useCmk = true (see the header of storage-extras.bicep).
using 'storage-extras.bicep'

param srcLocation = 'eastus'
param dstLocation = 'westus'
param srcAccountName = '<source-account>'
param dstAccountName = '<dest-account>'
param keyVaultName = '<key-vault-name>'
param tags = {
  project: 'azure-storage-private-endpoints-lab'
  environment: 'lab'
  owner: '<owner>'
  costCenter: 'CC-1001'
  lab: 'lab7'
}
param useCmk = false
param deployCmkRoleAssignment = true
// Leave the next three at their defaults for a new deployment. For an existing deployment set the live values.
param deployShare = true // set false once File Sync owns the share
param orPolicyName = 'default'
param orRuleId = ''
// param cloudEndpointName = '<existing-cloud-endpoint-guid>'
