// Source side of an object replication policy. It lives in a module because its name must be the policyId
// that Azure generates on the destination policy, which is only known at deployment time.
targetScope = 'resourceGroup'

@description('Source storage account name.')
param sourceAccountName string

@description('policyId returned by the destination policy.')
param policyId string

@description('Source storage account resource ID.')
param sourceAccountId string

@description('Destination storage account resource ID.')
param destinationAccountId string

@description('Rules as returned by the destination policy (they carry the generated ruleIds).')
param rules array

resource srcAccount 'Microsoft.Storage/storageAccounts@2025-06-01' existing = {
  name: sourceAccountName
}

resource orSrc 'Microsoft.Storage/storageAccounts/objectReplicationPolicies@2025-06-01' = {
  parent: srcAccount
  name: policyId
  properties: {
    sourceAccount: sourceAccountId
    destinationAccount: destinationAccountId
    rules: rules
  }
}
