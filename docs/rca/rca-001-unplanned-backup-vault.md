# RCA-001: Unplanned Recovery Services vault and delete lock after file share creation

**Milestone:** M3b (Azure Files) | **Date:** 2026-11-03 | **Impact:** lab only, no data loss, about 10 minutes from detection to clean state
**Evidence:** `docs/evidence/m3-02-share.txt`, `docs/evidence/m3-03-unplanned-backup-vault.txt`

## Summary

Creating the file share `labshare` in the portal also created a Recovery Services vault, a backup policy, a protected item for the share, and a `CanNotDelete` lock on the storage account. The share wizard's **Enable backup** option is on by default and was not unchecked. A post-change verification (listing resource types in the resource group) detected it before the first backup ran.

## Symptoms

- `az resource list -g rg-storage-lab` returned `Microsoft.RecoveryServices/vaults` in addition to the storage account; the plan expected the storage account only.

## Investigation (confirmed findings)

| Check | Result |
|---|---|
| Vault | one auto-named vault (`vault-<random>`) |
| Protected item | `labshare`, state `IRPending` (registered, no backup taken yet) |
| Policy | wizard-created `DailyPolicy-<random>` plus vault defaults |
| Lock | `AzureBackupProtectionLock`, `CanNotDelete`, auto-created by Azure Backup |
| Share snapshots | none (first backup had not run) |
| Vault soft delete | `Enabled` |

## Root cause

The portal file share wizard enables Azure Backup by default. The default was accepted, so the portal deployed backup resources that were outside the lab's plan. Contributing factor: the wizard step list did not call out the Backup tab explicitly before creation.

## Why it mattered

- **Cost:** ongoing protected-instance charges plus backup snapshot storage.
- **Teardown blocker:** the `CanNotDelete` lock prevents deleting the storage account or the resource group, and vault soft delete can hold backup data (and the vault) for 14 days, as seen in P5.

## Remediation (in order, with results)

1. Disable vault soft delete: **refused**, `BMSUserErrorDisablingSoftDeleteStateNotAllowed`. It was not needed in the end, because no backup data existed.
2. Stop protection and delete backup data: exit 0.
3. Unregister the storage account from the vault: returned `CloudInternalError` (a transient service error). The lock was nevertheless gone on the next check. Whether the unregister completed server-side despite the error is **not confirmed**; the final state below is.
4. Delete the lock: not needed, because it was already gone.
5. Delete the vault: exit 0.

## Verification

- Resource types in `rg-storage-lab`: `Microsoft.Storage/storageAccounts` only.
- Locks in `rg-storage-lab`: none.
- `labshare` still holds `finance/budget.txt` and `finance/report.txt`: removing backup did not affect the share.

## Prevention

- Wizard checklists now name every tab that can create extra billable resources (Backup on file shares; Defender for Storage on storage accounts).
- Keep the post-change check `az resource list -g <rg> --query "[].type"` after every portal create.
- In M6 the share is defined in Bicep, which deploys only what is declared.

## Interview takeaway

A default checkbox created a vault, a policy and a delete lock. A one-line resource inventory after the change caught it before the first backup ran, which kept the cleanup to minutes instead of a 14-day soft-delete wait. The order matters: stop protection and delete its data, unregister the storage account, release the lock, then delete the vault.
