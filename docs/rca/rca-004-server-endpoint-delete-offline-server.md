# RCA-004: File Sync server endpoint delete never completed because the server was offline

**Lab:** Lab 7 teardown | **Date:** 2026-11-06 | **Impact:** lab only; teardown paused from 15:11 to 16:43 (the scripted guard stopped it; resumed in the next session); no data at risk (lab data only)
**Evidence:** `docs/evidence/lab7-06-teardown.txt` (sections 1, 1b, 1c)

## Summary

The scripted teardown sent a DELETE for the File Sync server endpoint on `vm-sync01`. Azure accepted it, but the endpoint was still present 10 minutes later, so the block stopped before deleting anything else. The cause: deleting a server endpoint is a job the **File Sync agent on the server** has to carry out, and `vm-sync01` had been deallocated about 16 minutes before the delete was sent. Unregistering the server in the portal, the documented path for a server that is no longer available, removed the endpoint and the registration in under 2 minutes. The rest of the teardown then completed.

## Symptoms

- `DELETE .../serverEndpoints/<id>`: accepted (no error returned).
- The endpoint was still returned by GET for the next 10 minutes (14:59:56 to 15:11:11). The guard logged `STOP: server endpoint still present after 10 min.`

## Hypothesis (recorded before checking)

The delete is a job the agent must run. `vm-sync01` was deallocated at 14:43:48, so the job can't run. Microsoft's troubleshooting docs describe `MgmtServerJobExpired` ("This error occurs if the server is offline or doesn't have network connectivity") and say to unregister the server in the portal when it's no longer available.

## Evidence (confirmed, 16:43:55)

| Check | Result |
|---|---|
| Server endpoint `provisioningState` | `Canceled` |
| Server endpoint `lastOperationName` | `IDeleteServerEndpointWorkflow3` |
| Delete workflow status | `Aborted` |
| Workflow `lastStepName` | `deleteServerEndpointOnServer` |
| Registered server `lastHeartBeat` | 19:40:15 UTC (14:40 ET), just before the deallocation |
| `vm-sync01` power state | `VM deallocated` |

The workflow stopped at the step that runs **on the server**. That confirms the hypothesis.

## Root cause

**Wrong teardown order.** I deallocated `vm-sync01` as soon as the tests finished, to save cost, and only then started the File Sync teardown. Removing a server endpoint needs the agent online, unless the server is unregistered instead.

**Contributing factor:** Azure accepted the DELETE without an error. Only the later state (`Canceled` / `Aborted`) showed the delete hadn't happened.

## Remediation

1. Portal: **Storage Sync Service `sss-lab7` → Sync → Registered servers → `vm-sync01` → Unregister server.** The portal warns that this removes every server endpoint on the server. That was acceptable here, because the data was lab-only and the share held a copy.
2. Within about 2 minutes, the server endpoint and then the registration were gone (16:44:10 → 16:45:37).
3. The scripted teardown continued: cloud endpoint deleted (16:46:48), sync group deleted (16:46:51), then `rg-storage-lab` deleted (16:46:51 → 16:48:55, exit 0).

## Verification

- `rg-storage-lab exists: false`. Subscription-wide: 0 storage sync services, 0 `stl7*` storage accounts, 0 Recovery Services vaults, 0 `vm-sync01` disks.
- `kv-l7-jj1106` is soft-deleted with purge protection, purge scheduled for 2026-11-13. The name stays reserved until then (no charge).

## Prevention

- **Teardown order for File Sync:**
  1. delete server endpoints while the server is **running**
  2. delete the cloud endpoint
  3. delete the sync group
  4. unregister the server
  5. delete the sync service

  If the server is already gone or off, unregister it instead of deleting endpoints one by one.
- **Verify state, not the response code:** the guard that polled for the resource to disappear is what caught this. Keep "poll until gone, with a timeout" for every asynchronous delete.
- Stop compute last when other resources depend on an agent running on it.

## Interview takeaway

An accepted DELETE isn't a finished delete. The server endpoint is a cloud resource, but removing it runs a step on the server. With the VM off, the workflow aborted at `deleteServerEndpointOnServer` and the resource stayed. My teardown script waited for the resource to actually disappear, so it stopped safely instead of deleting the resource group around a half-removed sync topology. The fix was the documented one for an unavailable server: unregister it, which removes its endpoints in one step.
