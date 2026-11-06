# Project 7 Plan: Azure Storage + Private Endpoints Lab

**Status:** M0-M6 complete (2026-11-03 to 11-04). Lab 7 (storage extras) complete 2026-11-06. Everything torn down.

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

Unit prices from the Azure Retail Prices API on 2026-11-03, pay-as-you-go (raw output in `docs/evidence/m0-03-prices.txt`).

| Item | Unit price | Lab usage | Estimate |
|---|---|---|---|
| Blob, LRS, data stored | Hot $0.0208, Cool $0.0152, Cold $0.0036, Archive $0.00099 per GB/month | well under 1 GB, a few days | < $0.01 |
| Azure Files, LRS | $0.06 per GB/month (transaction optimized); Hot $0.0287, Cool $0.0228 | under 1 GB | < $0.01 |
| Private endpoint | $0.01 per hour (meter listed under region `Global`), plus data processed per GB | about 3 h in M4 | about $0.03 |
| Private DNS zone | $0.50 per zone/month (first 25 zones); queries $0.40 per million | 1 zone | up to $0.50 |
| B1s Linux VM | $0.0104 per hour, plus OS disk | about 3 h in M4 | about $0.03-0.05 |
| **Total** | | | **under $1**, mostly the DNS zone |

Uncertainty: whether a short-lived private DNS zone is prorated or billed as a full month is not confirmed; the estimate assumes the worst case. Transactions, rehydration and data-processed charges are negligible at lab volumes. Budget guardrail: $5/month on `rg-storage-lab` (`budget-storage-pe-lab`).

Price lookup findings (M0): the API response field is `type`, not `priceType` (that is only the filter name), so the first query returned nothing; the standard private endpoint meter is not listed under `eastus` but under `Global`; Hot blob shows three prices because of volume tiers (the lab is in the first tier).

## Safety

- Standing approval (as in P6) for lab changes and deletions inside `rg-storage-lab`. Changes to P1's resource group are made through P1's Bicep, reviewed with what-if first.
- No account keys or SAS tokens in chat or Git; evidence masks keys, tokens, account hostnames where needed, subscription IDs, GUIDs and IPs.
- VM deallocated or deleted at the end of each session.

## Lab 7: storage extras (2026-11-06)

Scope: AZ-104 storage objectives not covered in M0-M6. New resource group `rg-storage-lab` (the M6 one had been deleted), source account in East US, destination in West US (the East US pair).

| # | Milestone | Acceptance criteria | Planned failure / prediction | Outcome |
|---|---|---|---|---|
| M0 | Preflight | Repo clean, no leftovers, providers, names, prices | — | Done. `Microsoft.StorageSync` was NotRegistered (registered in M4, free). No File Sync meter found in the price lookup. |
| M1 | Redundancy | LRS -> RA-GRS -> LRS; secondary read verified | Secondary fails while LRS; secondary write rejected | All 5 predictions held. The secondary appeared about 29 min after the change; `lastSyncTime` is a lower bound; ZRS not offered while RA-GRS (hypothesis only). |
| M2 | Object replication | Prefix-filtered copy; overwrite; destination read-only | Policy rejected without versioning; **delete NOT replicated** | Delete prediction **wrong**: deletes replicate. Recovery from a source previous version. The PS7 `ConvertFrom-Json` date conversion broke the first restore (corrected, re-run). |
| M3a | Encryption scope | Container default with override denied; disable blocks only scope data | Disable gives 403 | Blocked after about 12 min with **409** (not 403); flapped after re-enable. **Cost missed in the plan:** $1/scope/month, 30-day minimum. |
| M3b | Customer-managed key | CMK via the account system identity; revoke and restore | `KeyVaultAuthenticationFailure` before the vault role | Held. Revoke in 171 s (403), restore in 567 s; the control plane showed `Succeeded` throughout. |
| M4 | Azure File Sync | Agent, registration, both sync directions, change detection | Direct share change not on the server within 10 min | Held (612 s absent, 92 s after detection). **RCA-003**: backup auto-enabled again. |
| M5 | Bicep, what-if, teardown, docs | What-if shows only documented noise; nothing left billing | — | Run 1: 3 real issues fixed (`useIdentity`, rotation policy, `deployShare` guard). Run 2: noise only. **RCA-004**: server endpoint delete aborted with the VM off; fixed by unregistering. RG deleted and verified. |

Deviations:
- The VM used the minimal Windows Server 2022 Azure Edition image (supported by File Sync).
- The ZRS conversion wasn't attempted: it can take hours to days, and the portal didn't offer it from RA-GRS.
- Evidence fixes were appended as CORRECTION lines, never rewritten. One exception: a File Sync `SyncSignature` value captured by what-if run 1 was **redacted** in place before publishing.

Cost: the encryption scope (about $1) dominates. The VM ran about 1 h at $0.0496/h. Check actual charges by resource group after billing posts (budget `budget-az104-lab` showed $2.29 of $10 at preflight, mostly earlier labs).
