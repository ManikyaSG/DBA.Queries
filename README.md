# SQL Server DBA Toolkit

Ready-to-run DMV queries for day-to-day DBA work and incident troubleshooting, organised by topic.

**Covers:** SQL Server 2016 · 2017 · 2019 · 2022 · 2025 (on-prem and Azure VM, incl. Always On AGs) · Azure SQL Managed Instance · Azure SQL Database

## How to use

1. Open the file for the area you are investigating in SSMS / Azure Data Studio / VS Code (mssql).
2. Every file is split into numbered sections (`5.3`, `11.4` …). **Highlight one section and execute it.** Sections are independent unless the header says "highlight together with …".
3. Values you need to change are marked `-- <== change`.
4. Statements that change things (KILL, failover, ALTER, DROP) are **commented out** or only *generated* as text. Review before running.

## On-call quick card

**Paged for a P1:**
1. `42` 42.1: first 60 seconds (vitals, waits now, head blockers, top requests, red flags, error log).
2. `42` 42.2: capture evidence **before** any restart, failover or KILL.
3. Fix it with the specific script (blocking `02`, CPU `07`/`03`, I/O `08`, memory `06`, log full `08` 8.7, AG `25`, recovery `34`/`35`).
4. `42` 42.4: safety check before KILL / restart / failover / cache clears.
5. Post status updates every 15–30 min (`42` 42.5). Afterwards: timeline `42` 42.3, then RCA.

**Daily / shift handover:** `41` 41.1 (0 rows = healthy) and `40` 40.1 (RPO/RTO vs SLA).

**Before / after any change (patch, upgrade, failover test):** `43` 43.3 PRE → change → 43.3 POST → 43.4 diff → 43.5 go/no-go.

**Weekly:** `40` 40.3/40.4 (backup chain), `40` 40.6 (backup files exist), `40` 40.9 (restore tests), `41` 41.2 (disk forecast).

**Set up once:** Agent alerts `41` 41.4, health-check email job `41` 41.8, evidence capture proc `42` 42.2, baseline collector `38` 38.2, SLA table `40` 40.12, change snapshot proc `43` 43.2, remote DAC `35` 35.10.

## Compatibility tags

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
| 33 | `33_community_tools.sql` | Ready-to-run calls for **sp_WhoIsActive**, **sp_Blitz / BlitzFirst / BlitzCache / BlitzIndex / BlitzLock / BlitzWho**, **Ola Hallengren** backups/CHECKDB/IndexOptimize + CommandLog checks, logging WhoIsActive/BlitzFirst to tables, Glenn Berry via dbatools |
| 34 | `34_point_in_time_recovery.sql` | **Accidental DELETE/UPDATE/DROP runbook**: find the bad transaction with `fn_dblog` / `fn_dump_dblog`, hex→decimal LSN, **which backups do I need for time X**, inspect backup files, restore copy with STOPAT / STOPBEFOREMARK, step through with STANDBY, copy rows back, **page restore**, tail-log of damaged DB, **database snapshots** (create/revert), Azure PITR / deleted DB / LTR / geo-restore |
| 35 | `35_corruption_emergency_recovery.sql` | Corruption triage (823/824/825), CHECKDB options, **map bad page → object/index**, fix-by-type decision guide, **SUSPECT / RECOVERY_PENDING / EMERGENCY repair**, lost log file, crash recovery progress, **system DB recovery (master rebuild/restore, msdb, model, tempdb path)**, **locked-out sysadmin**, DAC, moving files, **AG lost quorum / forced failover**, re-seeding a stuck secondary |
| 36 | `36_connectivity_service_troubleshooting.sql` | **Login failed 18456 decoded by state**, connectivity & security ring buffers, **Kerberos vs NTLM + SPN commands**, listener ports/TLS registry, connection storms / pool leaks, linked servers, **orphaned DTC (SPID -2)**, Service Broker health, memory dumps & non-yielding schedulers, Azure SQL DB connectivity checks |
| 37 | `37_replication.sql` | Topology, publications/articles, one-shot subscription health, **agent status & latency**, **undistributed commands**, **errors + the failing command** (`sp_browsereplcmds`), fix options (skip errors / skip transaction / reinitialize), tracer tokens, log reader & publisher log, distribution DB size/retention, AG notes |
| 38 | `38_performance_baseline.sql` | **Live perfmon dashboard with correct per-sec / ratio maths** and hints, **baseline collector** (waits, file I/O, counters → DBAdmin, 15-min job), trend queries, **last hour vs same hour last 7 days** |
| 39 | `39_advanced_tuning.sql` | **Stats histograms**, ascending-key problem, stats past auto-update threshold, **estimated vs actual rows (live)**, parallelism & skew, compile cost & optimizer timeouts, plan guides, **Resource Governor**, **In-Memory OLTP** (memory, hash buckets), spinlocks, query hint quick reference |
| 40 | `40_rpo_rto_compliance.sql` | **RPO/RTO scorecard vs SLA** (data you'd lose now, worst real gap, estimated restore time), gap detail, **broken log chains**, **chain-breaking / rogue backups** (NUL, VSS/VM snapshots, other users, recovery model flips), backup quality, **do the backup files still exist**, restore chain length, crash-recovery RTO, restore-test evidence (dbatools `Test-DbaLastBackup`), **HA/DR coverage per DB**, **AG failover verdict (data loss / readiness)**, SLA table template |
| 41 | `41_proactive_monitoring_alerts.sql` | **Problems-only health check** (backups, CHECKDB, AG, jobs, disk, log, tempdb, blocking, memory, certs, sev 17+ errors, DB Mail), **days-until-disk-full forecast**, files that will fail next autogrowth, **SQL Agent alert generator** (sev 17–25, 823/824/825, AG 1480/35264/41404/41405, 9002…), verify alerts/jobs notify someone, restart & config-change history, scheduled email template |
| 42 | `42_incident_response.sql` | **First-60-seconds triage**, **evidence capture proc before restart/failover**, **incident timeline** (error log, jobs, backups, autogrowth/DDL, AG changes, deadlocks, CPU, memory, new Query Store plans), **safety checks before KILL** (rollback estimate, decodes Agent job name) / restart / failover / cache clears, status-update & RCA templates |
| 43 | `43_pre_post_change_snapshot.sql` | **Pre/post change health-check snapshot**: quick 10-grid report (instance & build, services, DB states, recovery model, last full/diff/log + backup paths, AG roles / replicas / nodes / listeners / DB sync, cluster & quorum, disks, file paths & sizes, jobs, trace flags, endpoints, linked servers), **snapshot procedure storing PRE/POST in DBAdmin**, **automatic PRE vs POST diff (unexpected changes first)**, **go / no-go verdict** |

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
| Second opinion / quick triage | `33` sp_BlitzFirst → sp_WhoIsActive → sp_BlitzCache → sp_Blitz |
| Someone deleted / updated rows by mistake | `34` 34.1 log backup → 34.2 find tran → 34.4 LSN → 34.5 backups → 34.7 restore copy → 34.9 copy back |
| Release / data fix about to run | `34` 34.12 create snapshot first |
| CHECKDB errors / 823 / 824 | `35` 35.1 → 35.2 → 35.3 → 35.4 |
| Database SUSPECT / RECOVERY_PENDING | `35` 35.5 (35.6 if the log is gone) |
| Instance won't start | `35` 35.8 (tempdb path / master) → error log |
| Nobody has sysadmin | `35` 35.9 |
| Server hung, can't connect | `35` 35.10 DAC → `07` 7.3 → `36` 36.9 |
| Primary datacenter down (AG) | `35` 35.12 |
| "Login failed for user" | `36` 36.1 |
| "Cannot connect" / timeouts on connect | `36` 36.2 → 36.4 → 36.5 |
| Double-hop / ANONYMOUS LOGON / linked server auth | `36` 36.3 → 36.6 |
| Blocking by SPID -2 | `36` 36.7 |
| Replication latency / errors | `37` 37.3 → 37.4 → 37.5 → 37.6 → 37.7 |
| "Is this normal for this server?" | `38` 38.1 live → 38.4 vs baseline (set up 38.2 first) |
| Estimates way off / bad plan shape | `39` 39.4 → 39.1/39.2 histogram → 39.3 |
| Paged / P1 just started | `42` 42.1 → 42.2 → (fix) → 42.4 |
| "What changed at 10:05?" | `42` 42.3 timeline |
| Need to KILL a session — safe? | `42` 42.4 (a) |
| Restart or fail over? | `42` 42.4 (b) → `40` 40.11 |
| Auditor / manager asks "are we meeting RPO/RTO?" | `40` 40.1 → 40.2 → 40.9 |
| Restore failed / chain broken | `40` 40.3 → 40.4 → 40.6 |
| Avoid surprises tomorrow | `41` 41.1 → 41.2 → 41.3 |
| Patching / in-place upgrade / failover test | `43` 43.3 PRE → change → 43.3 POST → 43.4 diff → 43.5 go/no-go |
| Refresh UAT from PROD | `32` 32.1 → **32.2 save output** → 32.4 → 32.5 → 32.6 → 32.7 → 32.9 |

## Get / update the kit

```bash
git clone https://github.com/ManikyaSG/DBA.Queries.git    # first time
git pull                                                  # later, to get new scripts
```

**Tip:** In SSMS, add the `scripts` folder via *File → Open → Folder* (SSMS 21+) or keep the repo in your Templates/Snippets path; in Azure Data Studio / VS Code, open the repo folder for instant search across all scripts (`Ctrl+Shift+F` → search "VLF", "deadlock", …).

## Community tools (`/community-tools`)

sp_WhoIsActive, the First Responder Kit, Ola Hallengren's Maintenance Solution, dbatools and Glenn Berry's Diagnostic Information Queries — installed from their official sources (not copied here):

```powershell
.\community-tools\Install-CommunityTools.ps1 -SqlInstance SQLVM1,SQLVM2 -BackupDirectory '\\backup\sql' -CreateOlaJobs
```

See [`community-tools/README.md`](community-tools/README.md) for links, licences and how they map to the DMV scripts, `scripts/33_community_tools.sql` for T-SQL usage and `community-tools/dbatools-cheatsheet.ps1` for dbatools by scenario.

## Disclaimer

Read-only queries are safe to run, but some (buffer descriptors, physical stats `SAMPLED`, plan XML shredding) can be heavy on very large or busy systems — run them off-peak. Test anything that changes state in non-production first.
