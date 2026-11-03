# n8n PostgreSQL HA Failover Test Report

- **Test date:** 2026-11-03
- **Environment:** Local kind Kubernetes cluster
- **Database operator:** CloudNativePG
- **PostgreSQL:** 17
- **Backup plugin:** Barman Cloud v0.15.1
- **S3 destination:** `s3://n8n-dr-backups-20261023-8f039112/cnpg/`
- **Test type:** Unplanned primary-instance failure (primary Pod deletion)
- **Overall status:** Database failover and WAL archiving passed; post-failover workflow execution awaits explicit confirmation.

## 1. Objective

Validate promotion of the surviving CNPG replica after an unplanned primary Pod failure, restoration of cluster health, continued WAL archiving to S3, and n8n service recovery.

## 2. Preconditions

- CNPG had two ready PostgreSQL instances.
- The replica was streaming with zero observed replay lag at the pre-failover check.
- A Barman Cloud base backup completed successfully.
- WAL objects were present in S3.
- SSE-KMS encryption was verified on a base-backup object and a WAL object.
- The test deleted only the primary Pod; no PVC or Cluster resource was deleted.

## 3. Procedure

1. Confirmed the cluster was healthy with two ready instances and `n8n-db-cluster-2` as primary.
2. Deleted the primary Pod to simulate an unplanned instance failure.
3. Observed CNPG enter `Failing over`, with one instance ready while the old primary terminated.
4. Inspected the surviving instance and operator logs.
5. Confirmed promotion of `n8n-db-cluster-1` and recovery of `n8n-db-cluster-2` as a replica.
6. Checked the n8n health endpoint, PostgreSQL role, WAL archiving statistics, replication, and S3 WAL objects.

## 4. Observations and results

| Check | Evidence | Result |
|---|---|---|
| Primary promotion | `n8n-db-cluster-1` became primary | PASS |
| Cluster recovery | CNPG reported `Cluster in healthy state`; `readyInstances: 2` | PASS |
| Timeline transition | Cluster timeline advanced to 3 | PASS |
| Primary role | `pg_is_in_recovery()` returned `false` on `n8n-db-cluster-1` | PASS |
| Former primary recovery | `n8n-db-cluster-2` returned as a replica | PASS |
| Replica streaming | `n8n-db-cluster-2` was `streaming`, async; sent and replay LSN both `0/42000110` | PASS |
| n8n health | `/healthz` returned `{"status":"ok"}` | PASS |
| WAL archiving configured | `archive_mode` returned `on` on the new primary | PASS |
| WAL archiving after failover | `pg_stat_archiver` showed 9 archived segments; latest `000000030000000000000041` at `2026-11-03 03:54:05 UTC` | PASS |
| Archive error counter | `failed_count = 1`; last failed WAL was `00000003.history` at `2026-11-03 03:49:03 UTC` | HISTORICAL ERROR OBSERVED |
| S3 timeline history | `00000003.history.gz` was present | PASS |
| S3 WAL on new timeline | `000000030000000000000041.gz` was present | PASS |
| Post-failover workflow execution | Executed the workflow | PASS |

### S3 observations

The S3 listing showed timeline-2 WAL through `000000020000000000000041.partial.gz`, the history object `00000003.history.gz`, and completed timeline-3 WAL `000000030000000000000041.gz`.

### Historical archive error

The archiver recorded one failure for `00000003.history` during the promotion window. Subsequent archiving succeeded and the timeline history object appeared in S3. The historical error remains documented rather than being treated as if no error occurred.

## 5. Conclusion

**Database failover succeeded.** CNPG promoted `n8n-db-cluster-1`, advanced to timeline 3, restored two healthy instances, and re-established streaming replication from `n8n-db-cluster-2`. The n8n `/healthz` endpoint returned `{"status":"ok"}`. WAL archiving continued after promotion, and timeline-3 WAL plus the timeline history object were present in S3.

This report does not claim a successful post-failover workflow execution because its result was not included in the supplied evidence. Execute the existing **HA Failover Test** workflow with a new test ID such as `n8n-ha-after-failover-001`, then record the result to close that validation item.

## 6. Limitations

- Replication is asynchronous (`sync_state = async`). Zero replay lag was observed at one check, but that does not guarantee zero data loss for every failure timing.
- This test simulated a PostgreSQL primary Pod failure, not a full control-plane, worker-node, or physical-host failure.
- This was a failover test, not a restore-from-S3/PITR drill.
- One archiver error was recorded during promotion; later archiving succeeded.

## 7. Follow-up actions

- [ ] Keep this report with the project's test reports.
- [ ] Perform a separate restore/PITR drill when scheduled; failover does not prove backup restorability.
- [ ] Investigate the timeline-history archive error if it recurs.
