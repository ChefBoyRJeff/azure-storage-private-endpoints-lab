# RCA-002: Private endpoint healthy, but clients resolve the public IP and time out (planned failure)

**Milestone:** M4e | **Date:** 2026-11-03 | **Type:** planned failure (deliberately induced), diagnosed and fixed
**Evidence:** `docs/evidence/m4-03-baseline.txt`, `m4-04-blob-private-endpoint.txt`, `m4-05-dns-link-failure.txt`

## Environment

- Client: `vm-pe-test` (Windows Server 2022, no public IP) in P1's `vnet-spoke1/snet-workload` (10.1.1.0/25).
- P1 route table on that subnet: `0.0.0.0/0 -> VirtualAppliance 10.0.1.4`, with no appliance behind it. The VM's effective route shows next hop `None` (drop). So any traffic to a public IP is dropped.
- Storage account `stpelabjj1103`: blob private endpoint `pe-stpelab-blob` at 10.1.1.5; private DNS zone `privatelink.blob.core.windows.net` in `rg-storage-lab`.

## Symptoms (after the zone's VNet link was deleted)

| Probe from the VM | Result |
|---|---|
| DNS `stpelabjj1103.blob.core.windows.net` | public IP; CNAME chain `stpelabjj1103.privatelink.blob.core.windows.net -> blob.<cluster>.store.core.windows.net` |
| TCP 443 | False |
| Managed-identity blob read | no response (timed out) |

With a healthy private path, the same probe returned A=10.1.1.5, TCP True, HTTP 200.

## Initial hypotheses

1. The private endpoint is broken or not approved.
2. The A record is missing from the private zone.
3. The private zone is not visible to the client's VNet (no virtual network link).

## Diagnosis (in order, with confirmed results)

1. Private endpoint connection state: **Approved**. Rules out hypothesis 1.
2. Zone A record: `stpelabjj1103 -> 10.1.1.5` **present**. Rules out hypothesis 2.
3. Zone virtual network links: **none**. Confirms hypothesis 3.

The key clue was in the DNS answer itself. The public CNAME to `privatelink.blob.core.windows.net` is handed to every client, but only a VNet linked to the private zone gets the private A record. Here the chain continued to the public storage cluster.

## Root cause

The private DNS zone had no virtual network link to `vnet-spoke1`. Azure DNS (168.63.129.16) therefore answered from public DNS. The client connected to the public IP, and P1's default route dropped the traffic.

## Remediation

Re-created the link in the portal: `link-vnet-spoke1` -> `vnet-spoke1`, auto-registration **off**.

## Verification

- Link state `Completed`.
- The probe right after (+3 s): A=10.1.1.5, TCP 443 True, HTTP 200 with the blob content.

## Prevention

- Define the zone and its VNet links in Bicep with the private endpoint (M6), so a link can't be dropped silently.
- In hub-and-spoke designs, keep `privatelink.*` zones central and link every spoke that has clients, or use Azure DNS Private Resolver with conditional forwarding for on-premises clients.
- Monitoring idea: an alert or Azure Policy that flags a private DNS zone with fewer links than expected.

## Interview takeaway

"The endpoint was healthy and the record existed, but the client got the public IP. The CNAME showed privatelink, but the A record was public. That pattern means the private zone isn't linked to the client's VNet. I proved it by checking the endpoint state, then the record, then the links, and fixed it by re-creating the link."
