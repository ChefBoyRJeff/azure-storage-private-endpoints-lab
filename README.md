# Azure Storage + Private Endpoints Lab

Hands-on lab covering what an Azure administrator owns in **Azure Storage**: access tiers, rehydration and lifecycle rules; data protection; SAS vs. RBAC data access; Azure Files; AzCopy and Storage Explorer; and **private endpoints with private DNS** on an existing hub-and-spoke network ([azure-hub-spoke-network](https://github.com/ChefBoyRJeff/azure-hub-spoke-network)). It was built in the portal and CLI first, then codified in Bicep and verified against the live account with what-if. The planned failures are documented from real evidence.

Built as a hands-on project while studying for **AZ-104: Microsoft Azure Administrator**. This is lab work in a personal subscription, not a production environment.

> **Status:** complete (M0-M6). Lab resources torn down; see [Cleanup](#cleanup).

## Business problem

A team keeps files in Azure Storage but hands out account keys, leaves data reachable from the internet, and doesn't know which access tier or retention it needs. This lab builds the storage controls an administrator owns, breaks them on purpose, and records how each failure was diagnosed and fixed.

## Architecture

```mermaid
flowchart LR
    subgraph home["Admin workstation (outside Azure)"]
        cli["az CLI / AzCopy<br/>Storage Explorer"]
    end

    subgraph p1["rg-hubspoke-lab (P1, reused)"]
        subgraph spoke1["vnet-spoke1 10.1.0.0/16"]
            subgraph snet["snet-workload 10.1.1.0/25<br/>UDR 0.0.0.0/0 -> 10.0.1.4 (no NVA: dropped)"]
                vm["vm-pe-test<br/>10.1.1.4, no public IP<br/>managed identity"]
                peb["PE blob<br/>10.1.1.5"]
                pef["PE file<br/>10.1.1.6"]
            end
        end
        hub["vnet-hub 10.0.0.0/16"]
    end

    subgraph rg["rg-storage-lab"]
        sa[("stpelabjj1103<br/>StorageV2, LRS<br/>containers: tiers, lifecycle, scratch, transfer<br/>share: labshare (SMB 3.1.1, encrypted)")]
        zb["privatelink.blob.core.windows.net"]
        zf["privatelink.file.core.windows.net"]
    end

    spoke1 <-->|peering| hub
    vm -->|HTTPS 443| peb
    vm -->|SMB 445| pef
    peb --> sa
    pef --> sa
    zb -.->|VNet link| spoke1
    zf -.->|VNet link| spoke1
    cli -->|public endpoint, Entra or key<br/>denied while public access Disabled| sa
```

The VM, private endpoints and zones existed only during M4; the Bicep template can rebuild the private endpoint part with `deployPrivateEndpoints = true`.

## What was built and what it showed

| Milestone | Built | Key verified result |
|---|---|---|
| M0 | Scaffold, P1 inspection, $5 budget, prices | P1 route `0.0.0.0/0 -> 10.0.1.4` with no appliance; lab estimate under $1 |
| M1 | Blob tiers, rehydration, versioning, soft delete, lifecycle | Archive read -> `BlobArchived` (409); High-priority rehydration **about 44 min**; overwrite and delete recovered by promoting versions; lifecycle moved a blob to Cool **about 16 h** after the rule was applied |
| M2 | Keys, SAS, RBAC data roles, shared key off | Owner denied blob data with Entra (no `dataActions`); container-scoped Reader worked after **about 1.1 min**; user delegation SAS capped by RBAC (403 on write); stored access policy revoked only its own tokens; disabling shared key **suspends** key-signed SAS, rotation **revokes** it (about 15 s) |
| M3 | Azure Files share, snapshot, restore | TCP 445 blocked from home (443 OK) -> mount moved into Azure; **RCA-001** unplanned backup vault and lock; file restore from snapshot via portal and CLI |
| M4 | VM in P1 spoke, blob + file private endpoints, private DNS, public access off | Baseline **timeout** -> after PE **403** -> after VM identity role **200**; **RCA-002** unlinked zone; workstation refused with valid key and RBAC; SMB 3.1.1 encrypted mount over PE |
| M5 | AzCopy + Storage Explorer | AzCopy reused the az login token; Reader upload 403 (job Cancelled); container-scoped Contributor in **0.6 min**; S2S copy; `sync --delete-destination` dry run; **Storage Explorer wrote to a Reader-only container using the account key** |
| M6 | Bicep, what-if, docs, teardown | Template written from the live export; what-if found real drift (share soft delete off), fixed by deploy; final what-if: only documented noise |

## Troubleshooting and root-cause reports

| Report | Symptom | Root cause |
|---|---|---|
| [RCA-001](docs/rca/rca-001-unplanned-backup-vault.md) | Recovery Services vault and `CanNotDelete` lock appeared after creating a file share | The share wizard enables Azure Backup by default |
| [RCA-002](docs/rca/rca-002-private-dns-zone-not-linked.md) | Private endpoint healthy, but the VM resolved the public IP and timed out | Private DNS zone had no VNet link to the client VNet (planned failure) |

Other findings recorded in the evidence:
- The lifecycle rule saved `tierToCold` instead of Cool, and a portal edit didn't persist; it was fixed by applying `infra/lifecycle-policy.json`.
- Re-enabling `publicNetworkAccess` left `networkAcls.defaultAction = Deny`.
- An SMB write failed on a PowerShell 5.1 drive mapped to a UNC path (hypothesis; the script is fixed but not re-tested).
- Share soft delete was found disabled at M6 export (cause unconfirmed: never applied, or changed via the data plane).

## Repository structure

```
infra/
  main.bicep                  storage account, services, containers, share, lifecycle, optional PEs
  main.bicepparam             lab values (no IDs or secrets)
  modules/private-endpoint.bicep   PE + private DNS zone + VNet link + zone group
  lifecycle-policy.json       lifecycle rule (used by the CLI in M1e and loaded by Bicep)
  budget.bicep, budget.example.bicepparam   cost guardrail
scripts/
  m4-probe.ps1                VM-side probe: DNS, TCP, managed-identity blob read (Run Command)
  m4-smb-mount.ps1            VM-side SMB mount test (key passed as a parameter, rotated after)
docs/
  plan.md                     plan, outcomes and deviations
  interview-guide.md          walkthrough, deep dive, Q&A
  evidence/                   sanitized command output for every milestone
  rca/                        root-cause reports
```

## Prerequisites

- An Azure subscription with Owner or Contributor + User Access Administrator on the lab resource group.
- Azure CLI 2.90 with Bicep 0.48 (`az bicep install`), PowerShell 7, AzCopy 10.22 or later, and Storage Explorer (both via winget).
- For private endpoints: the P1 network (`rg-hubspoke-lab`, `vnet-spoke1/snet-workload`, private endpoint network policies Disabled) in the same region.

## Deploy

```powershell
az group create -n rg-storage-lab -l eastus --tags project=azure-storage-private-endpoints-lab
# Optional cost guardrail (copy the example to budget.local.bicepparam and set your email; it is gitignored)
az deployment sub create -l eastus --template-file infra/budget.bicep --parameters infra/budget.local.bicepparam

az deployment group what-if -g rg-storage-lab --template-file infra/main.bicep --parameters infra/main.bicepparam
az deployment group create  -g rg-storage-lab --template-file infra/main.bicep --parameters infra/main.bicepparam

# M4 design (billed hourly): blob + file private endpoints, zones and links
az deployment group what-if -g rg-storage-lab --template-file infra/main.bicep --parameters infra/main.bicepparam --parameters deployPrivateEndpoints=true
```

`storageAccountName` must be globally unique, so change it in `main.bicepparam`. Data roles are not in the template. Grant them at the narrowest scope, for example Storage Blob Data Reader on one container.

## Verification

- `az deployment group what-if` after deployment shows only the known `staticWebsite` noise (see `docs/evidence/m6-01-bicep-whatif.txt`).
- `scripts/m4-probe.ps1` via `az vm run-command invoke` checks DNS (private IP and privatelink CNAME), TCP 443/445, and a managed-identity blob read.

## Security notes

- Anonymous blob access is off, TLS 1.2 is the minimum, HTTPS only, copy scope is the same tenant, and cross-tenant replication is off.
- Data access uses Entra RBAC at container scope. Shared key stayed enabled only because M3 used key-based SMB; **M5 showed why that matters**: an Owner can fetch keys, and any key-capable tool bypasses RBAC. Production setting: `allowSharedKeyAccess = false`, with identity-based SMB auth.
- No keys or SAS values are in the repo. Keys used during tests were rotated, and the evidence was scanned for key-like strings.

## Cost

Estimate under $1 (`docs/plan.md`): storage pennies; M4 VM about 45 min at $0.0496/h; 2 private endpoints at $0.01/h; 2 private DNS zones at up to $0.50 each (proration not confirmed). Actual charges are checked against the budget after billing posts.

## Cleanup

Done at the end of M6 (`docs/evidence/m6-02-teardown.txt`): remove the data role assignments, delete the storage account and `rg-storage-lab`, and confirm no lab resources remain. The budget is deleted later, after the last charges post. P1's network was left unchanged throughout.

## Limitations and possible improvements

- The SMB **write** over the private endpoint was not verified (read, list and snapshot read were).
- Role assignments and data were created by hand, not in code.
- Shared key stayed enabled for the lab; production would disable it and use Entra Kerberos for Azure Files.
- Centralized private DNS (zones linked to hub and every spoke) and Azure DNS Private Resolver for on-premises clients were described, not built.
- Service endpoints were covered conceptually; adding one would have required changing P1's Bicep.

## Skills demonstrated (AZ-104)

Configure storage accounts, redundancy and access tiers; lifecycle management; blob versioning and soft delete; SAS, stored access policies and access keys; RBAC data roles and least privilege; storage firewall and private endpoints; private DNS; Azure Files and snapshots; AzCopy and Storage Explorer; Bicep and what-if.
