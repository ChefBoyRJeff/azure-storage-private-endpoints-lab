# Interview Guide: Azure Storage + Private Endpoints Lab

This is a hands-on lab in my own subscription while studying for AZ-104, not production experience. Every number below comes from the evidence files in `docs/evidence/`.

## 3-5 minute walkthrough

1. **Problem.** A team uses Azure Storage with shared keys, public endpoints, and no plan for tiers or retention. I built the controls an administrator owns, broke each one on purpose, and documented the diagnosis.
2. **Data lifecycle.** I used four access tiers. Reading an Archive blob failed with BlobArchived, and High-priority rehydration took about 44 minutes. Versioning and soft delete recovered an overwrite, a delete and a deleted container. A lifecycle rule moved a blob to Cool about 16 hours after I applied it, so lifecycle runs daily, not in real time.
3. **Access.** As subscription Owner I couldn't read blobs with Entra, because Owner has no data actions. A container-scoped Storage Blob Data Reader fixed it in about a minute. I compared service SAS and user delegation SAS, revoked tokens with a stored access policy, and showed that disabling shared key only suspends key-signed SAS, while rotating the key revokes it.
4. **Network.** I reused my hub-and-spoke network. A VM in a spoke timed out reaching storage, because the spoke's default route pointed at a firewall that doesn't exist. A private endpoint changed the timeout into a 403, and giving the VM's managed identity a scoped role made it a 200. Then I deliberately removed the private DNS zone's VNet link, diagnosed it, and fixed it. With public access disabled, even a valid key from my workstation was refused.
5. **Code.** I exported the live account, wrote Bicep from the export, and used what-if until it showed only documented noise. What-if also caught real drift: share soft delete was off.

## 10-minute deep dive (pick by interviewer interest)

- **Timeout vs 403:** a timeout means the request never arrived, so check DNS, routes and firewalls. A 403 means the service answered and refused you, so check identity and RBAC. The M4 baseline, private endpoint and role steps show all three states with the same probe script.
- **Effective routes:** P1's route is configured `VirtualAppliance 10.0.1.4`, but the VM NIC showed next hop `None`. The user route overrides the default internet route, so public-bound packets are dropped.
- **Private DNS mechanics:** public DNS returns a CNAME to `<account>.privatelink.blob.core.windows.net` to everyone. Only VNets linked to the private zone get the private A record. Diagnosis order: endpoint state, then record, then VNet links.
- **Control plane vs data plane:** Owner can `listKeys` (control plane), and the key reads data. Any key-capable tool, such as Storage Explorer, then bypasses RBAC. Fix: `allowSharedKeyAccess=false`.
- **What-if triage:** I sorted each line into real drift (fix) or noise (document or declare). Declaring the container encryption-scope defaults removed four noise lines.

## Most difficult problem

Getting reliable evidence on Windows. Several "results" were artifacts of my own scripts: `@($null).Count` returning 1, pipes inside JMESPath breaking under `az.cmd`, `Select-Object -First` hiding exit codes, and template lines pasted as real observations. I learned to treat a blank or surprising result as a question, re-check with raw output, and append corrections instead of rewriting evidence.

## Real troubleshooting examples (with evidence)

| Case | Evidence | One-line answer |
|---|---|---|
| Unlinked private DNS zone (RCA-002) | `m4-05` | CNAME showed privatelink but the A record was public, so the zone wasn't linked to that VNet |
| Unplanned backup vault + delete lock (RCA-001) | `m3-03` | Wizard default; caught by a resource inventory before the first backup, removed in the right order |
| Data plane still blocked after re-enabling public access | `m4-08` | `defaultAction` stayed Deny; both settings must be restored together |
| Storage Explorer bypassing RBAC | `m5-04` | The tool used account keys fetched via Owner |
| SMB blocked from home | `m3-01` | DNS OK, 443 OK, 445 failed, so an outbound 445 block, not Azure |

## Security and cost

- Least privilege: data roles at **container** scope for both my user and the VM's managed identity; no anonymous access; same-tenant copy scope; keys rotated after every test that used them; evidence scanned for key-like strings.
- Cost: estimate under $1. The VM, private endpoints and DNS zones were created and deleted the same day, there was a $5 budget alert, and the template keeps private endpoints off by default.

## What I would change for production

- `allowSharedKeyAccess=false`, identity-based SMB (Entra Kerberos), and Azure Policy to enforce both.
- Central `privatelink.*` zones linked to every spoke (or DNS Private Resolver for on-premises), all in IaC.
- ZRS or GZRS instead of LRS, depending on recovery objectives; diagnostic settings to Log Analytics for denied-request alerts.
- Role assignments and the budget in code, deployed by a pipeline (P3 pattern).

## Likely questions and answers from this lab

**Q: An app in a spoke can't reach a storage account that has a private endpoint. Where do you start?**
A: Resolve the name from the client. If it returns the public IP with a privatelink CNAME, the private zone isn't linked to that VNet. If it returns the private IP, test TCP 443, then look at authorization. In my lab the unlinked zone gave a timeout, and the fix took effect about 3 seconds after re-linking.

**Q: Why can't a subscription Owner read blobs in the portal with Entra auth?**
A: Owner has `actions: *` but no `dataActions`. Data access needs a Storage Blob Data role. Owner can still list keys, which is why key-based access worked for me, and why shared key should be disabled.

**Q: How do you revoke a leaked SAS?**
A: A service SAS bound to a stored access policy: delete the policy (only those tokens die). An unbound service SAS: rotate the signing key; in my test it stopped working within about 15 seconds. A user delegation SAS: revoke user delegation keys or remove the role. Disabling shared key alone only suspends: my old SAS worked again after re-enabling.

**Q: Archive vs Cold?**
A: Archive is offline: properties are readable but content isn't, and rehydration took about 44 minutes at High priority (Standard can take up to 15 hours). Cold is online with cheaper storage than Cool and a 90-day minimum.

**Q: What does what-if not tell you?**
A: It can show noise (properties the API returns but you didn't set), and it doesn't see data-plane changes. My share soft delete drift had no matching control-plane event in the activity log.

## Follow-up questions to practice

- Why did the CLI need `--auth-mode login` vs `key`, and which one does AzCopy use?
- What would change if the spoke had a real NVA at 10.0.1.4?
- How would you give on-premises users access to the private endpoint?
- Why is `registrationEnabled` false on a privatelink zone link?
- What's the cost difference between a service endpoint and a private endpoint, and why choose the more expensive one?

## Lab 7: storage extras

### 2-minute walkthrough

I added the storage topics the first lab skipped: redundancy, object replication, encryption scopes, a customer-managed key, and Azure File Sync.
- **Redundancy:** I switched an account from LRS to RA-GRS and back. The secondary endpoint didn't exist for about 29 minutes. Once it did, it served matching content and refused writes with 403.
- **Object replication:** I replicated only `inv-` blobs to West US. I predicted a delete would not be copied, and that was wrong: deletes replicate. So I recovered from a previous version on the source.
- **Encryption:** an encryption scope took about 12 minutes to block reads after I disabled it, with a 409 rather than the 403 the docs state. Disabling the customer-managed key blocked data in about 3 minutes, and recovery took about 9.5 minutes.
- **File Sync:** I installed the agent and registered the server with the VM's managed identity, with no RDP. I showed that a change made directly in the share doesn't reach the server until change detection runs.
- **Code:** I codified all of it in Bicep and used what-if to find real drift. I documented two incidents: the backup default catching me a second time, and a server endpoint delete that aborted because the VM was off.

### Deep-dive points

- **lastSyncTime:** writes before it are guaranteed on the secondary; later writes may or may not be there. My new blob was readable on the secondary 17 s after upload, while lastSyncTime still showed a time 30 minutes earlier. It's the data-loss bound for a failover, not a freshness indicator.
- **Object replication isn't backup:** overwrites and deletes both replicate. Protection against deletes comes from versioning and soft delete on the source.
- **Why CMK needs two deployments from scratch:** the account's system-assigned identity exists only after the account is created, and it must hold Key Vault Crypto Service Encryption User before encryption can point at the key. Pass 1 creates the account and the role; pass 2 switches to CMK. A user-assigned identity, created first, avoids the second pass.
- **The control plane doesn't show data-plane outages:** with the key disabled, every read failed with 403 while the account still showed `provisioningState Succeeded`. You'd alert on failed requests (storage logs or metrics), not on resource health.
- **What-if and service-owned state:** File Sync wrote metadata and a `GhostedRecall` stored access policy onto the share. Redeploying the share from my template would have removed them, so the template has `deployShare = false` once File Sync owns it.

### Likely questions

**Q: You disabled a customer-managed key. What happens, and how fast?**
A: In my lab, reads and writes on data under that key failed with 403 `KeyVaultEncryptionKeyNotFound` after about 3 minutes. The account still showed Succeeded. Data in an encryption scope with its own Microsoft-managed key stayed readable. After re-enabling the key, access came back after about 9.5 minutes, so revoking a key is fast and undoing it is slow.

**Q: A user says a file they uploaded to the Azure file share hasn't appeared on the on-premises server.**
A: That's expected. Servers learn about changes made directly in the share only through the cloud change detection job, which can take up to 24 hours. In my lab the file was still missing after 10 minutes and arrived 92 seconds after I triggered change detection. Write through the server endpoint, or run `Invoke-AzStorageSyncChangeDetection` after direct changes.

**Q: You deleted a File Sync server endpoint and it never went away. Why?**
A: The delete runs a step on the server. My VM was deallocated, and the workflow aborted at `deleteServerEndpointOnServer`. For a server that's gone or off, unregister it in the portal, which removes its endpoints. Better: delete endpoints while the server is still running, and stop compute last.

**Q: Why did the backup vault appear twice?**
A: The portal file share wizard turns on Azure Backup by default. After the first time I added a reminder, and it didn't work. What caught it both times was a scripted inventory after the change. The real fix is creating shares from code, or adding an Azure Policy audit.

### Follow-ups to practice

- How do you convert an RA-GRS account to ZRS or GZRS, and why didn't the portal offer it?
- What does object replication need on the source vs the destination (versioning, change feed)?
- How would you rotate the CMK, and what does an empty `keyVersion` mean?
- How would cloud tiering change the File Sync teardown risk (tiered files and orphaned files)?
