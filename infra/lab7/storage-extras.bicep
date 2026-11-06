// P7 Lab 7 (M5): the storage extras codified. Written from the live export (infra/export/lab7, gitignored), not from memory.
// Declares: source account (CMK, encryption scope, change feed, file share) and destination account (other region),
// object replication policy (destination first, then source with the same policyId), Key Vault + key, and
// Azure File Sync (sync service, sync group, cloud endpoint).
// Not declared on purpose: the sync VM and its network (lab scaffolding), the server endpoint and registered
// server (they need the File Sync agent on a server), personal RBAC, roles the portal granted the sync
// service in M4, and data.
//
// From a clean resource group CMK needs TWO deployments, because the storage account identity must hold a Key
// Vault role before the account can use the key (M3b planned failure: KeyVaultAuthenticationFailure):
//   1) useCmk=false, deployCmkRoleAssignment=true   -> account (Microsoft-managed keys) + identity + role
//   2) useCmk=true                                  -> account switches to the customer-managed key
targetScope = 'resourceGroup'

@description('Region for the source account, Key Vault and Storage Sync Service.')
param srcLocation string

@description('Region for the object replication destination account (a different region from the source).')
param dstLocation string

@description('Tags applied to every resource.')
param tags object

@description('Source storage account name (globally unique, 3-24 lowercase letters and digits).')
@minLength(3)
@maxLength(24)
param srcAccountName string

@description('Destination storage account name (globally unique, 3-24 lowercase letters and digits).')
@minLength(3)
@maxLength(24)
param dstAccountName string

@description('Key Vault name (globally unique; purge protection keeps it reserved after deletion).')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Key Vault key used as the storage customer-managed key.')
param cmkKeyName string = 'cmk-storage'

@description('Encrypt the source account with the Key Vault key. Needs the Key Vault role to exist first (see header).')
param useCmk bool = true

@description('Create the Key Vault Crypto Service Encryption User assignment for the source account identity. False when it already exists under another name (the portal created it in M3b).')
param deployCmkRoleAssignment bool = true

@description('Encryption scope name: alphanumeric only, 3-63 characters (M3a: a hyphen was rejected).')
param encryptionScopeName string = 'scopefinance'

@description('Object replication policy name on the destination: default for a new policy, or the existing policyId.')
param orPolicyName string = 'default'

@description('Existing object replication rule ID, or empty for a new policy (Azure generates it on the destination).')
param orRuleId string = ''

@description('Blob name prefix that object replication copies (M2: only inv- blobs replicated).')
param orPrefix string = 'inv-'

@description('Create the file share. False once File Sync owns it: a redeploy would remove the share metadata and the GhostedRecall stored access policy that File Sync wrote (lab7-05 run 1).')
param deployShare bool = true

@description('Azure file share used as the File Sync cloud endpoint.')
param shareName string = 'syncshare'

@description('File share quota in GiB.')
@minValue(1)
param shareQuotaGiB int = 102400

@description('Storage Sync Service name.')
param syncServiceName string = 'sss-lab7'

@description('Sync group name.')
param syncGroupName string = 'sg-lab7'

@description('Cloud endpoint name: the portal uses a GUID. A new one is derived from the resource group and sync group.')
param cloudEndpointName string = guid(resourceGroup().id, syncServiceName, syncGroupName)

// Built-in role: Key Vault Crypto Service Encryption User
var cryptoServiceEncryptionUserRoleId = 'e147488a-f6f5-4113-8e2d-b22465e65bf6'

var srcContainers = [
  { name: 'orders', scope: '$account-encryption-key', deny: false }
  { name: 'redundancy', scope: '$account-encryption-key', deny: false }
  // M3a: container default scope with override denied; an upload naming another scope was rejected.
  { name: 'finance', scope: encryptionScopeName, deny: true }
]

// ---------- Key Vault and key ----------
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: srcLocation
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true // required for storage CMK; cannot be turned off once on
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Allow'
    }
  }
}

resource cmkKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: kv
  name: cmkKeyName
  properties: {
    // Docs: an ARM PUT of an existing key is a no-op (no new version); rotation is a data-plane operation.
    kty: 'RSA'
    keySize: 2048
    keyOps: [
      'sign'
      'verify'
      'wrapKey'
      'unwrapKey'
      'encrypt'
      'decrypt'
    ]
    attributes: {
      enabled: true // M3b: disabling it made the account return 403 KeyVaultEncryptionKeyNotFound
    }
    // The portal default policy (lab7-05 run 1 showed it as a removal when undeclared).
    rotationPolicy: {
      lifetimeActions: [
        {
          action: {
            type: 'notify'
          }
          trigger: {
            timeBeforeExpiry: 'P30D'
          }
        }
      ]
    }
  }
}

// ---------- Source account (East US) ----------
resource src 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: srcAccountName
  location: srcLocation
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS' // M1 tested LRS -> RA-GRS -> LRS; it ends on LRS
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: false
    dnsEndpointType: 'Standard'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      ipRules: []
      virtualNetworkRules: []
    }
    encryption: {
      keySource: useCmk ? 'Microsoft.Keyvault' : 'Microsoft.Storage'
      // No key version: the account follows the latest key version (automatic rotation).
      keyvaultproperties: useCmk
        ? {
            keyname: cmkKey.name
            // Built from the name, not kv.properties.vaultUri: what-if cannot evaluate reference() (lab7-05 run 1)
            // and the live value has no trailing slash.
            keyvaulturi: 'https://${kv.name}${environment().suffixes.keyvaultDns}'
          }
        : null
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

resource cmkRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployCmkRoleAssignment) {
  scope: kv
  name: guid(kv.id, src.id, cryptoServiceEncryptionUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cryptoServiceEncryptionUserRoleId)
    principalId: src.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource srcBlob 'Microsoft.Storage/storageAccounts/blobServices@2025-06-01' = {
  parent: src
  name: 'default'
  properties: {
    isVersioningEnabled: true // object replication needs versioning on both sides (M2: RequiredFeatureDisabled)
    changeFeed: {
      enabled: true // object replication source needs change feed
      retentionInDays: 7
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 7
      allowPermanentDelete: false
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource scope 'Microsoft.Storage/storageAccounts/encryptionScopes@2025-06-01' = {
  parent: src
  name: encryptionScopeName
  properties: {
    source: 'Microsoft.Storage'
    state: 'Enabled' // M3a: Disabled took about 12 minutes to block reads; billed about $1/month while it exists
    requireInfrastructureEncryption: true // set at creation only
  }
}

resource srcContainerRes 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-06-01' = [
  for c in srcContainers: {
    parent: srcBlob
    name: c.name
    properties: {
      publicAccess: 'None'
      defaultEncryptionScope: c.scope
      denyEncryptionScopeOverride: c.deny
    }
    dependsOn: [
      scope
    ]
  }
]

resource srcFile 'Microsoft.Storage/storageAccounts/fileServices@2025-06-01' = {
  parent: src
  name: 'default'
  properties: {
    protocolSettings: {
      smb: {
        encryptionInTransit: {
          required: true
        }
      }
    }
    // Matches the live account: share soft delete was off (the portal wizard setting in M4).
    shareDeleteRetentionPolicy: {
      enabled: false
    }
  }
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-06-01' = if (deployShare) {
  parent: srcFile
  name: shareName
  properties: {
    accessTier: 'TransactionOptimized'
    shareQuota: shareQuotaGiB
    enabledProtocols: 'SMB'
  }
  // No Azure Backup here on purpose (RCA-001, RCA-003): Bicep deploys only what is declared.
}

// ---------- Destination account (West US) ----------
resource dst 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: dstAccountName
  location: dstLocation
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
    allowSharedKeyAccess: true
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: false
    dnsEndpointType: 'Standard'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
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

resource dstBlob 'Microsoft.Storage/storageAccounts/blobServices@2025-06-01' = {
  parent: dst
  name: 'default'
  properties: {
    isVersioningEnabled: true
    deleteRetentionPolicy: {
      enabled: true
      days: 7
      allowPermanentDelete: false
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource replica 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-06-01' = {
  parent: dstBlob
  name: 'replica'
  properties: {
    publicAccess: 'None'
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
  }
}

// ---------- Object replication: destination first, then source with the same policyId ----------
resource orDst 'Microsoft.Storage/storageAccounts/objectReplicationPolicies@2025-06-01' = {
  parent: dst
  name: orPolicyName
  properties: {
    sourceAccount: src.id
    destinationAccount: dst.id
    rules: [
      {
        ruleId: empty(orRuleId) ? null : orRuleId
        sourceContainer: 'orders'
        destinationContainer: replica.name
        filters: {
          prefixMatch: [
            orPrefix
          ]
        }
      }
    ]
  }
  dependsOn: [
    srcContainerRes
    srcBlob
  ]
}

module orSrc 'modules/or-source-policy.bicep' = {
  name: 'lab7-or-source'
  params: {
    sourceAccountName: src.name
    policyId: orDst.properties.policyId
    sourceAccountId: src.id
    destinationAccountId: dst.id
    rules: orDst.properties.rules
  }
}

// ---------- Azure File Sync (cloud side only) ----------
resource sss 'Microsoft.StorageSync/storageSyncServices@2022-09-01' = {
  name: syncServiceName
  location: srcLocation
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    incomingTrafficPolicy: 'AllowAllTraffic'
    useIdentity: true // managed identity mode (M4); undeclared, what-if showed it being removed
  }
}

resource syncGroup 'Microsoft.StorageSync/storageSyncServices/syncGroups@2022-09-01' = {
  parent: sss
  name: syncGroupName
  properties: {}
}

resource cloudEndpoint 'Microsoft.StorageSync/storageSyncServices/syncGroups/cloudEndpoints@2022-09-01' = {
  parent: syncGroup
  name: cloudEndpointName
  properties: {
    // From a clean start the sync service also needs access to the account and share, which the portal
    // granted in M4 (not declared here; see README limitations).
    storageAccountResourceId: src.id
    azureFileShareName: shareName
    storageAccountTenantId: tenant().tenantId
    friendlyName: shareName
  }
  dependsOn: [
    share
  ]
}

output srcAccountId string = src.id
output dstAccountId string = dst.id
output keyVaultUri string = kv.properties.vaultUri
output objectReplicationPolicyId string = orDst.properties.policyId
output cmkEnabled bool = useCmk
