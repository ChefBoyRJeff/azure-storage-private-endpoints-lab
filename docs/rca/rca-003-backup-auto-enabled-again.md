# RCA-003: Azure Backup auto-enabled again by the file share wizard (recurrence of RCA-001)

**Lab:** Lab 7 M4 (Azure File Sync) | **Date:** 2026-11-06 | **Impact:** lab only, no data lost or billed (no recovery point was taken), about 16 minutes from creation to clean state
**Evidence:** `docs/evidence/lab7-04-file-sync.txt` (sections 2-5, findings B1-B6)

## Summary

Creating the file share `syncshare` in the portal for Azure File Sync also created a Recovery Services vault (`vault-mw5b5na1`, geo-redundant), a daily backup policy, a protected item for the share, and a `CanNotDelete` lock on the storage account. This is the **same failure as RCA-001** three days earlier. The prevention from RCA-001 ("check the Backup tab") depended on a person remembering, and it failed. The post-change inventory check, the other half of the RCA-001 prevention, caught it before the first backup ran.

## Symptoms

- The post-build check counted Recovery Services vaults in `rg-storage-lab`: **1** (expected 0) and locks: **1** (expected 0).
- Activity log: `Microsoft.RecoveryServices/vaults/write Succeeded` at 13:39:42, the minute the share was created.

## Investigation (confirmed findings)

| Check | Result |
|---|---|
| Vault | `vault-mw5b5na1`, storage redundancy `GeoRedundant`, soft delete `Enabled`, 14 days |
| Protected item | `syncshare`, state `IRPending` (registered, no backup taken) |
| Policy | wizard-created `DailyPolicy-<random>` plus the vault defaults |
| Lock | `AzureBackupProtectionLock`, `CanNotDelete`, note "Auto-created by Azure Backup for storage accounts registered with a Recovery Services Vault" |

## Root cause

The portal file share wizard enables Azure Backup by default, and **Enable backup** was left checked (Jeff: "i think i missed the uncheck"). RCA-001 had already identified this default. The fix chosen then was a reminder in the wizard checklist, which is a human control with no enforcement.

**Contributing factor:** this time I was focused on the File Sync steps, so the share felt like a prerequisite rather than a change that needed its own review.

## Remediation (in order, with real results)

1. Turn off vault soft delete: **failed**. I used a CLI option that doesn't exist in this CLI version (`--soft-delete-state`, exit 2), so soft delete stayed `Enabled`.
2. Stop protection and delete backup data: exit 0, but the protected item was still listed right after.
3. Unregister the storage account: `CloudInternalError` (a transient service error), the same as in RCA-001.
4. Delete the lock: nothing to delete. The activity log shows Azure removed `AzureBackupProtectionLock` itself at **13:54:09**, during the stop-protection and unregister operations, before my lock step ran.
5. Delete the vault: exit 0. The activity log shows `vaults/delete Succeeded` at **13:55:32**.

Deleting the vault succeeded even though soft delete was still on. That's consistent with RCA-001: soft delete only holds **backup data**, and none existed (state `IRPending`).

## Verification

- `rg-storage-lab`: 0 Recovery Services vaults and 0 locks. The storage account itself had no locks.
- `syncshare` still existed; removing backup didn't touch the share.
- Subscription-wide: no Recovery Services vaults. The only backup vault is P5's `bv-backup-lab` (`Microsoft.DataProtection/backupVaults`, a different resource type).

## Why this recurred, and the stronger prevention

A recurrence means the first fix was the wrong kind of control. Ranked from weakest to strongest:

| Control | Type | Status |
|---|---|---|
| "Check the Backup tab" in the wizard checklist | human, easily skipped | failed here |
| Post-change inventory (`az resource list` by type, counting vaults and locks) | detective | **worked twice** (RCA-001 and RCA-003) |
| Create file shares with the CLI or Bicep, which deploy only what is declared | preventive | used in `infra/main.bicep` and `infra/lab7/storage-extras.bicep` |
| Azure Policy `audit` (or `deny`) for `Microsoft.RecoveryServices/vaults` in lab resource groups | preventive, enforced | not built; recommended |

Going forward: lab file shares are created from code, and a portal-created share is always followed by the vault and lock count in the same block.

## Interview takeaway

The same checkbox caught me twice. The lesson isn't "be more careful". It's that a reminder isn't a control. What actually caught it, both times, was a scripted check after the change. The fix that removes the problem is creating the resource from code, or adding a policy that makes the unwanted resource visible or impossible.
