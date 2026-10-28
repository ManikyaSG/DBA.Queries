# SQL Server DBA Toolkit

Ready-to-run DMV queries for day-to-day DBA work and incident troubleshooting, organised by topic.

**Covers:** SQL Server 2016 · 2017 · 2019 · 2022 · 2025 (on-prem and Azure VM, incl. Always On AGs) · Azure SQL Managed Instance · Azure SQL Database

## How to use

1. Open the file for the area you are investigating in SSMS / Azure Data Studio / VS Code (mssql).
2. Every file is split into numbered sections (`5.3`, `11.4` …). **Highlight one section and execute it** — sections are independent.
3. Values you need to change are marked `-- <== change`.
4. Statements that change things (KILL, failover, ALTER, DROP) are **commented out** or only *generated* as text. Review before running.

### Compatibility tags

Every section header carries tags showing where it runs:

| Tag | Meaning |
|---|---|
| `[BOX]` | SQL Server 2016–2025 on-prem or SQL Server on Azure VM |
| `[MI]` | Azure SQL Managed Instance |
| `[SQLDB]` | Azure SQL Database (single DB / elastic pool) |

Version minimums (e.g. *2016 SP2+*, *2019+*) are noted in the section header where they apply. The baseline assumes 2016 **SP2** or later.

## Files

| # | File | What's in it |
|---|---|---|
| 00 | `00_instance_overview.sql` | Version/CU, uptime, hardware, sp_configure, trace flags, services/IFI, DB properties & sizes |
| 01 | `01_wait_stats.sql` | Top waits (filtered), live delta snapshot, waiting tasks, per-session waits, signal %, latches |
| 02 | `02_sessions_blocking.sql` | Active requests, live plans, **blocking tree**, open transactions, sleeping sessions with open trans, connections, KILL helpers |
| 03 | `03_query_performance_plan_cache.sql` | Top queries by CPU/reads/duration/grants/spills, top procs, query_hash rollup, parameter sniffing suspects, plan warnings, cache bloat |
| 04 | `04_query_store.sql` | QS status, top queries over N hours, **regressed queries**, multi-plan queries, forced plans, wait categories, QS hints |
| 05 | `05_indexes_statistics.sql` | Missing (with CREATE), unused (with DROP), duplicate/overlapping, fragmentation, heaps, stats health, lock/latch hotspots, columnstore, resumable ops |
| 06 | `06_memory.sql` | OS/process memory, PLE per NUMA, buffer pool by DB/object, memory clerks, memory grants, low-memory ring buffer, OOM events |
| 07 | `07_cpu.sql` | CPU % history (ring buffer), scheduler/runnable queue, worker threads, top CPU now, CPU by DB, NUMA/MAXDOP |
| 08 | `08_storage_io_files.sql` | File latency (cumulative + live delta), pending IO, volume free space, file free space (all DBs), log reuse wait, log stats, **VLF counts**, autogrowth settings & events, largest tables |
| 09 | `09_tempdb.sql` | File layout check, space by category, usage per session, version store, snapshot transactions, allocation contention |
| 10 | `10_backup_restore.sql` | Last backup + RPO flags, history (size/speed/path), backup/restore/DBCC progress, restore history, **restore-chain script generator** |
| 11 | `11_alwayson_ag.sql` | AG dashboard, replica states, **DB sync/lag/RPO/RTO**, data-loss window, failover readiness, listeners, routing, endpoints, seeding, WSFC, AG waits, failover history (XE), action templates |
| 12 | `12_locking_deadlocks.sql` | Locks by session, waiting locks with object names, escalation, **deadlocks from system_health** (graph + shredded), Azure DB deadlocks |
| 13 | `13_security.sql` | sysadmins/role members, logins & policy, weak passwords, risky permissions, orphaned users, DB roles/permissions, guest, TRUSTWORTHY, TDE & cert expiry, encryption, failed logins, audit, linked servers |
| 14 | `14_agent_jobs_dbmail.sql` | Failed jobs, running jobs, job inventory & next run, long-running vs average, steps, non-sa owners, alerts/operators, Database Mail |
| 15 | `15_database_health_errorlog.sql` | DB state, last good CHECKDB, suspect pages, AG auto page repair, config anti-patterns, error log searches, system_health errors |
| 16 | `16_azure_sql_database.sql` | Tier/limits, resource stats (1h / 14d), elastic pool, waits, space, geo-replication, operations, automatic tuning, PVS |
| 17 | `17_azure_managed_instance.sql` | Instance resource history, governance limits, storage vs reserved, GP file-size/IO, log rate governor, replica state, MI differences |
| 18 | `18_extended_events.sql` | List sessions; ready-made XE for blocked process report, long queries, errors/timeouts; Azure DB-scoped session |
| 19 | `19_maintenance_helpers.sql` | Index & stats maintenance generators, safe log shrink, find object/column/code, row counts, recent changes, DB owner fix, migrate logins |
| 20 | `20_version_specific_features.sql` | 2017+ / 2019+ (ADR, page decode, last actual plan, missing-index→query) / 2022+ (contained AG, PSP, ledger) / 2025 (optimized locking), version decoder |
| 21 | `21_cdc_change_tracking.sql` | CDC: enabled DBs/tables, capture instances, captured vs missing columns, **capture latency & errors**, jobs & retention, log held by CDC, change table sizes, read-changes / enable / tune templates, CDC + AG notes; Change Tracking versions & side-table sizes |
| 22 | `22_tde_encryption.sql` | TDE status & scan progress, unencrypted DBs, **cert expiry & private-key backup**, DMK/SMK, encrypted backups, **AG cert consistency**, EKM/Key Vault, Always Encrypted inventory, enable / restore-elsewhere / rotate / disable templates |
| 23 | `23_data_masking_rls_classification.sql` | Masked columns, **who can UNMASK**, test-as-user, unmasked sensitive-column finder, mask/unmask templates (incl. 2022 granular UNMASK), Row-Level Security, sensitivity classification, per-table protection summary |
| 24 | `24_index_tuning.sql` | Missing indexes consolidated per table, **key lookups & scans in plans**, **unindexed foreign keys**, clustered key review (wide/GUID/non-unique), over-indexed tables, page splits, fill factor, compression candidates, partition map, disabled/hypothetical indexes, before/after test |
| 25 | `25_alwayson_advanced.sql` | **One-shot AG alert query**, "not synchronizing" checklist, **redo blocked on readable secondary**, version store impact, commit latency, distributed & contained AGs, login/job drift, primary-only job guard, backup preference, build/add/remove templates, Azure VM notes |
| 26 | `26_filestream_filetable.sql` | FILESTREAM level (configured vs effective), containers & filegroups, FILESTREAM columns, FileTables + UNC paths, open handles, garbage collection, waits, setup templates, AG/backup notes |
| 27 | `27_inplace_upgrade.sql` | Source version/OS, **deprecated features in use**, compat levels, blockers (CLR strict security, startup procs, server triggers, SSIS/SSRS/replication/mirroring, text/ntext), pre-upgrade backups & config snapshot, post-upgrade validation, **Query-Store-guided compat level raise**, AG rolling upgrade order |
| 28 | `28_version_control_schema_changes.sql` | Recent changes across all DBs, **who changed what (default trace)**, DDL audit table + trigger, SchemaVersion table, **object hash baseline for drift**, dump module definitions for git, SSDT/sqlpackage/Flyway/DbUp cheat sheet |
| 29 | `29_migration.sql` | DB & **instance-level inventory** (logins, jobs, linked servers, credentials, certs…), cross-DB/server dependencies, risky code (xp_cmdshell, OPENROWSET, hard-coded server), **Azure SQL DB / MI blocker check**, cutover backup/restore generator, log shipping status, post-migration validation, cutover checklist |
| 30 | `30_patching.sql` | Build/CU/**last patched date**, **pre-patch health check (one result set)**, system DB backup generator, pause/resume jobs, **AG rolling patch** checks & order, FCI notes, post-patch validation, Azure VM / MI / SQL DB patching notes |
| 31 | `31_schema_validation.sql` | **Schema & index fingerprints** for env-to-env compare, **two-DB object & column diff**, broken references / modules that fail to refresh, untrusted/disabled constraints, row-count diff, collation mismatches, inconsistent data types, identity exhaustion, object counts |
| 32 | `32_database_refresh.sql` | PROD → DEV/UAT refresh: target snapshot, **capture users/roles/permissions/settings as a re-apply script**, locate backup, **RESTORE WITH MOVE generator**, AG handling, drop PROD users / fix orphans / NEW_BROKER / remove CDC & replication, **static data sanitization**, log shrink, validation |

## Symptom → where to look

| Symptom | Start here |
|---|---|
| "Everything is slow" | `01` 1.2 (live waits) → `02` 2.1 → `07` 7.1 |
| Users blocked / timeouts | `02` 2.3 blocking tree → 2.5 open transactions → `18` 18.2 blocked process report |
| High CPU | `07` 7.1, 7.4 → `03` 3.1 with `@SortBy='CPU'` → `04` 4.3 |
| Query got slower since yesterday | `04` 4.4 regressed → 4.5 multiple plans → force plan 4.6 |
| Disk / IO latency | `08` 8.2 live latency → `01` (PAGEIOLATCH/WRITELOG) → `06` 6.3 PLE |
| Log file full / growing | `08` 8.7 log_reuse_wait → `02` 2.5 open trans → `11` 11.3 (AG) → `10` 10.1 |
| tempdb full | `09` 9.2 → 9.3 per session → 9.4/9.5 version store |
| RESOURCE_SEMAPHORE / memory | `06` 6.7 memory grants → 6.2 counters → `03` 3.1 `@SortBy='GRANT'` |
| AG secondary behind / not synchronizing | `11` 11.3 → 11.2 (connected_state, errors) → 11.13 waits → 11.14 history |
| AG failover happened — why? | `11` 11.14 → `15` 15.6 error log → `11` 11.12 cluster |
| Deadlocks | `12` 12.5 / 12.6 |
| Backup missing / RPO audit | `10` 10.1 (check all AG replicas) |
| Job failed overnight | `14` 14.1 |
| Corruption suspected | `15` 15.3, 15.2 → `15` 15.10 CHECKDB |
| Security audit | `13` top to bottom |
| Azure SQL DB "hitting limits" | `16` 16.2 → 16.5 (LOG_RATE_GOVERNOR etc.) |
| Log full with `log_reuse_wait = REPLICATION` | `21` 21.8 → 21.6 CDC errors → 21.7 capture job |
| CDC consumers getting stale data | `21` 21.5 latency → 21.2 max LSN time |
| TDE audit / cert about to expire | `22` 22.1 → 22.3 |
| TDE DB won't come online on AG secondary | `22` 22.7 → 22.11 |
| "Who can see unmasked data?" | `23` 23.2 → 23.8 |
| Which index should I add? | `03`/`04` find query → `24` 24.3/24.4 → 24.1 → `05` 5.7 |
| Deletes on parent table slow / blocking | `24` 24.5 unindexed FKs |
| AG monitoring job | `25` 25.1 (0 rows = healthy) |
| Redo queue growing on readable secondary | `25` 25.3 → 25.4 |
| FILESTREAM disk not freed after deletes | `26` 26.7 |
| Can't alter FileTable DB (open handles) | `26` 26.6 |
| MI storage / IO | `17` 17.4, 17.5, 17.6 |
| Planning a version upgrade | `27` 27.1 → 27.2 → 27.4 → 27.5 → (upgrade) → 27.6 → 27.7 |
| "Who changed this proc / dropped this table?" | `28` 28.2 → 28.1 → 28.3 (set up for next time) |
| PROD differs from what's in git | `28` 28.5 baseline → `31` 31.1 |
| Migrating to a new server / Azure | `29` 29.1 → 29.2 → 29.3/29.4 → 29.5 → 29.7 |
| Monthly CU patching | `30` 30.1 → 30.2 → 30.3/30.4 → 30.5 (AG) → 30.7 |
| UAT doesn't match PROD / post-deploy check | `31` 31.2 → 31.3 → 31.4 → 31.5 |
| Refresh UAT from PROD | `32` 32.1 → **32.2 save output** → 32.4 → 32.5 → 32.6 → 32.7 → 32.9 |

## Get / update the kit

```bash
git clone https://github.com/ManikyaSG/DBA.Queries.git    # first time
git pull                                                  # later, to get new scripts
```

**Tip:** In SSMS, add the `scripts` folder via *File → Open → Folder* (SSMS 21+) or keep the repo in your Templates/Snippets path; in Azure Data Studio / VS Code, open the repo folder for instant search across all scripts (`Ctrl+Shift+F` → search "VLF", "deadlock", …).

## Recommended community tools (complement this kit)

- **sp_WhoIsActive** (Adam Machanic) — live activity
- **First Responder Kit** (Brent Ozar: sp_Blitz, sp_BlitzFirst, sp_BlitzCache, sp_BlitzIndex)
- **Ola Hallengren Maintenance Solution** — backups, CHECKDB, index/stats maintenance
- **dbatools** (PowerShell) — migrations, login/job sync across AG replicas, mass checks
- **Glenn Berry's Diagnostic Information Queries** — version-specific deep health checks

## Disclaimer

Read-only queries are safe to run, but some (buffer descriptors, physical stats `SAMPLED`, plan XML shredding) can be heavy on very large or busy systems — run them off-peak. Test anything that changes state in non-production first.
