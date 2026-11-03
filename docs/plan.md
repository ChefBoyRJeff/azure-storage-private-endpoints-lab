# Project 7 Plan: Azure Storage + Private Endpoints Lab

**Status:** Plan approved 2026-11-03. M0 in progress.

## Business Problem

A team keeps files in Azure Storage but hands out account keys, leaves data reachable from the internet, and doesn't know which access tier or retention it needs. This lab builds the storage controls an administrator owns, breaks them on purpose, and records how each failure is diagnosed.

## Reuse

| Asset | Use here |
|---|---|
| **P1 hub-and-spoke network** (`rg-hubspoke-lab`, `azure-hub-spoke-network` repo) | M4: private endpoint in a spoke; private DNS zone linked to hub and spokes (centralized private DNS pattern) |
| **P2 Log Analytics** (`law-monitoring-lab`) | Optional storage resource logs (denied requests, auth type) |
| **P6 conventions** | Budget template, bicepconfig, .gitignore/.gitattributes, evidence style |

## Milestones

| # | Milestone | Acceptance criteria | Planned failure |
|---|---|---|---|
| M0 | Scaffold, P1 network inspection, budget, prices | Budget deployed; P1 state recorded; prices recorded | — |
| M1 | Storage account; blob tiers Hot/Cool/Cold/Archive; rehydration; lifecycle rule; soft delete, versioning | Tier changes and lifecycle rule verified | Read an Archive blob before rehydration |
| M2 | Access: account keys, service SAS, user delegation SAS, stored access policy revocation, RBAC data roles, disable shared key | Each method tested positive and negative | Owner on the account cannot read blobs with Entra auth (control plane vs. data plane) |
| M3 | Azure Files: share, SMB mount from a VM, share snapshot, restore | File restored from snapshot | — |
| M4 | Network security: storage firewall, service endpoint vs. private endpoint, private DNS zone, public access disabled (on P1's spoke) | Private IP resolution and access from the spoke VM; public access denied | Private DNS zone not linked: VM resolves the public IP and is denied |
| M5 | Tools: AzCopy, Storage Explorer | Upload/sync verified | — |
| M6 | Bicep + what-if, teardown, RCAs, interview guide | Nothing billing; docs complete | — |

## Watch-outs (from P1 code inspection, 2026-11-03)

- P1 spoke subnets have a route table sending **0.0.0.0/0 to an NVA at 10.0.1.4 that does not exist**. Internet-bound traffic from a spoke VM is dropped; VNet and peered traffic use more specific system routes and are unaffected. Expected effects: a spoke VM cannot reach the storage **public** endpoint until a service endpoint (which adds a more specific system route) or a private endpoint is used. To be verified with effective routes.
- P1 subnets are declared inline in the VNet resources, so any change made outside P1's Bicep (service endpoint, extra subnet) would be reverted by a P1 redeploy. M4 changes to P1 resources will be made through P1's Bicep.
- P1 spoke NSG: `Deny-VNet-Inbound` (4000) with `Allow-Intra-Subnet` (120); a VM and private endpoint in the same subnet can talk.

## Cost

To be filled in M0 from the Azure Retail Prices API (storage, private endpoint, private DNS zone, B1s VM). Target under $1; budget $5.

## Safety

- Standing approval (as in P6) for lab changes and deletions inside `rg-storage-lab`. Changes to P1's resource group are made through P1's Bicep, reviewed with what-if first.
- No account keys or SAS tokens in chat or Git; evidence masks keys, tokens, account hostnames where needed, subscription IDs, GUIDs and IPs.
- VM deallocated or deleted at the end of each session.
