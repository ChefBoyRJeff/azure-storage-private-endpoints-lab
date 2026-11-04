// One storage sub-resource (blob or file): private endpoint + private DNS zone + VNet link + DNS zone group.
// The zone and its VNet link are declared together, so a client VNet cannot silently lose the link (RCA-002).
targetScope = 'resourceGroup'

@description('Region of the private endpoint (same as the client VNet).')
param location string

@description('Tags applied to every resource.')
param tags object

@description('Resource ID of the storage account.')
param storageAccountId string

@description('Storage account name, used for resource naming.')
param storageAccountName string

@description('Storage sub-resource: blob or file.')
@allowed([
  'blob'
  'file'
])
param groupId string

@description('Subnet resource ID for the private endpoint NIC.')
param subnetId string

@description('Client VNet resource ID to link to the private DNS zone.')
param vnetId string

var zoneName = 'privatelink.${groupId}.${environment().suffixes.storage}'

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  location: 'global'
  tags: tags
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: 'link-${last(split(vnetId, '/'))}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false // never auto-register VM records in a privatelink zone
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${storageAccountName}-${groupId}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${storageAccountName}-${groupId}'
        properties: {
          privateLinkServiceId: storageAccountId
          groupIds: [
            groupId
          ]
        }
      }
    ]
  }
}

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: replace(zoneName, '.', '-')
        properties: {
          privateDnsZoneId: zone.id
        }
      }
    ]
  }
  dependsOn: [
    link
  ]
}

output privateEndpointId string = pe.id
