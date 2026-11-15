# One-click PRE / POST change check and HEALTH check with performance window (v2)

> **v2** of [`../pre-post-check`](../pre-post-check/README.md) (which stays the stable version). New in v2: the **HEALTH** check is followed by a **performance window** sampled every N seconds, it can be **scheduled** with Windows Task Scheduler (option 5), and **Agent jobs, logins and server role members are no longer collected or compared**. Failed Agent job steps in the last 24 hours are still reported as problems.

> **Just 3 files:** `Run-PrePostCheck.bat` (double-click), `Invoke-PrePostCheck.ps1` and `HC_Snapshot.sql`. Copy them together to a folder on the VM, for example `C:\DBA\PrePostCheck`. The older `automation/health-check` folder (script 44) isn't needed.

Double-click `Run-PrePostCheck.bat` and choose:

| # | Choice | What it does |
|---|---|---|
| 1 | **PRE** | Snapshot before a change, stored on the VM and emailed |
| 2 | **POST** | Snapshot after the change, compared with PRE, emailed as SUCCESS or DIFFERENCES |
| 3 | **HEALTH** | Health check, then a **performance window** (default: a sample every 60 s for 30 min) on every instance. One combined report with a `[CRITICAL]`, `[WARNING]` or `[OK]` subject. Nothing is stored for comparison |
| 4 | **CLEANUP** | Delete old snapshots, reports and logs (this also runs automatically at the start of every check) |
| 5 | **SCHEDULE** | Create (or delete) a Windows scheduled task that runs HEALTH unattended - daily, weekly or once |

Before a change (patching, CU, in-place upgrade, failover test, config change), run it with **PRE**. After the change, run it with **POST**. It checks **every SQL instance on the VM**:

- **PRE** collects a full health-check snapshot, **stores it on the VM** as JSON, and emails a *PRE captured* report, which gives the team a baseline.
- **POST** collects the same snapshot, **compares it with the stored PRE**, and emails one of:
  - 🟢 **`[POST SUCCESS]`**: no unexpected differences and no new problems. Expected changes such as the new build/CU are listed for the record.
  - 🔴 **`[POST DIFFERENCES]`**: a *before → after* table of every unexpected difference, plus any problems that are new since PRE. Sent with high importance.
  - 🟡 **`[POST NO BASELINE]`**: no PRE snapshot was found, so it sends the POST report only.

**One report and one email per VM.** All instances on the VM go into a single HTML file, `Reports\<VM>_<PRE|POST>_<ticket>_<time>.html`. It opens with a summary table (one row per instance), followed by each instance's section. A single email is sent through the first instance that has working Database Mail, local instances first:
- The **email body** has the summary plus each instance's differences / new problems.
- The **full combined report is attached**. If it can't be attached, because it's bigger than Database Mail's `MaxFileSize` or the SQL Server service account can't read the `Reports` folder, the whole report goes in the email body instead.
- If no instance has Database Mail, no email is sent and the combined report opens in your browser.

Snapshots (JSON) and reports stay on the VM as evidence. Set `PerInstanceReports = $true` in `$Config` if you also want one HTML file per instance, or `AttachReport = $false` to always put the report in the body.

## Files

| File | Purpose |
|---|---|
| `Run-PrePostCheck.bat` | Double-click this. Starts the Secondary Logon service if needed, then runs the PowerShell script. |
| `Invoke-PrePostCheck.ps1` | Menu, credentials, run-as with fail-safe, snapshots, PRE/POST comparison, combined report, Database Mail and cleanup. All settings are in `$Config` at the top. |
| `HC_Snapshot.sql` | All the checks, run on every instance. |

Folders that are created automatically: `Snapshots\<ticket>\` (JSON), `Reports\` (HTML) and `Logs\`.

## Set up once per VM

1. Copy the folder to a place **your own account can read and write**, for example `C:\DBA\PrePostCheck`. Snapshots must be writable there.
2. In `Invoke-PrePostCheck.ps1` → `$Config`, set `Recipients` and your usual `MailProfile`. Optionally adjust the tolerances (below), and list instances on other VMs (for example AG replicas) in `ExtraInstances = @('SQLVM2', 'SQLVM3\INST2')`.

## Run it

1. RDP in with the generic admin account and double-click `Run-PrePostCheck.bat`.
2. Choose `1` PRE, `2` POST or `3` HEALTH, then enter the **change ticket**. The ticket is how PRE and POST get paired, so use the same one for both runs.
3. Enter **your** Windows account at the credential prompt, the same one you use for SSMS "Run as different user". **This is always the first choice.**
   - The `.bat` (and the script) start the **Secondary Logon** service if it's stopped or disabled (UAC prompt if the window isn't elevated). The check then runs **as your account** in a new window.
   - **Fail-safe, per instance:** if your account can't log in to an instance, or has no `VIEW SERVER STATE` there, that instance is handed back to the original window and retried as the **logged-in RDP account**. Everything still ends up in one combined report and one email. If both accounts fail, the instance shows *FAILED* with both errors.
   - **Fail-safe, run-as:** if the new window can't start at all (Secondary Logon won't start, or the logon is refused), the script uses your account from the original window instead, still before the RDP account.
   - The summary, report and email have a **ConnectedAs** column, so you can see which account checked each instance.
   - Cancel at the prompt runs it as the RDP account only.
4. Read the summary in the window and check your mailbox.

**When to run POST:** after services are up and the **AG databases are SYNCHRONIZED** again. If they're still catching up, the check will rightly report it as a difference.

If POST finds no PRE for that ticket, it offers the **latest PRE for that instance** and shows its ticket, time and user, then asks you to confirm. If you decline or none exists, it sends the POST report as *NO BASELINE*.

## What is compared

| Area | Compared | Treated as expected (listed, not a failure) |
|---|---|---|
| Instance | edition, collation, FCI/HADR, active node, CPUs, memory, memory model. **SQL Server uptime and Windows uptime** are shown side by side (not compared) | build, CU, KB, product level, SQL start time, Windows boot time |
| Services | status, startup type, service account, IFI | last start time |
| sp_configure / trace flags | every value, global flags added or removed | |
| Databases | state, user access, recovery model, compat level, owner, read-only, page verify, RCSI, snapshot isolation, TDE, broker, trustworthy, Query Store, AG name/role/sync state, full and log backup **folders** | size changes within tolerance |
| Always On | each replica's role, **primary replica**, commit/failover mode, connected, health, readable, endpoint, backup priority, listeners; **listener IPs**: static or **DHCP**, subnet mask, network subnet, IP state, port (DNN listeners don't appear here); each DB's role, sync state, health and suspended flag on every replica | |
| Cluster | quorum type/state, member type/state, votes | |
| Disks / files | disk size, file paths, type, state, growth, max size | free space and size changes within tolerance |
| Objects | linked servers; endpoints; certificates; XE sessions (Agent jobs, logins and server role members are not collected in v2) | |
| SSIS | SSIS service state; SSISDB catalog settings; projects (package count, version, deployed by); environments (variable count). Failed package executions in the last 24 h are reported as problems | catalog `SCHEMA_BUILD` / `SCHEMA_VERSION` |
| SSRS | Reporting Services / Power BI Report Server service; for each report server database on the instance: counts of folders, reports, data sources, datasets and schedules; each subscription (report, owner, enabled, failing). Failing subscriptions and failed report executions (24 h) are reported as problems | |
| SSAS | Analysis Services service; whether the instance can be queried; each database (compatibility level, type) | SSAS version, database `date_modified` |
| Problems | issues that exist **after but not before** = new problems | issues already present at PRE are listed separately |

**Tolerances**, set in `$Config`:
- File/DB size changes are flagged only above **10 % and 512 MB** (`FileSizeDriftPct`, `FileSizeDriftMinMB`).
- Disk free-space changes are flagged only above **5 % of the disk** (`DiskFreeDriftPct`).

Last-backup *times*, log usage %, queue sizes and CPU are not compared, because they always move. A change of AG primary is **flagged on purpose**, so you'll notice if a failback was missed.

## HEALTH performance window

After the health check, the script samples **every instance at the same time** every `PerfSampleSec` seconds for `PerfDurationMin` minutes. When you run HEALTH by hand it asks: **Enter** = the defaults, **0** = skip, or `seconds/minutes` such as `30/15`. Press **Q** to stop early; it takes one last sample and reports what it has.

| Area | What's reported |
|---|---|
| Throughput | Batch Requests/sec; Transactions/sec for the databases in `PerfDatabases` (for example `@('MARS', 'CLR')`; empty = all), plus a per-database table |
| Compilation | SQL Compilations/sec, SQL Re-Compilations/sec |
| Connections | User Connections; **connection pool usage** = sessions per application / host / login (peak, average, peak active) |
| Locking | Lock Waits/sec, Lock Wait Time, Lock Timeouts/sec, Deadlocks/sec, sessions blocked longer than 5 s; **blocked process reports** and **deadlocks** from a temporary Extended Events session |
| Memory | Page Life Expectancy, Buffer cache hit ratio, Memory Grants Pending, Target vs Total Server Memory |
| Wait stats | ms waited **per interval** for LCK_M_\*, PAGEIOLATCH_\*, PAGELATCH_\*, WRITELOG, CXPACKET, CXCONSUMER, SOS_SCHEDULER_YIELD, HADR_SYNC_COMMIT, RESOURCE_SEMAPHORE |
| Queries | **every query over 5 s** (Extended Events: duration, CPU, reads, database, app, host, login, text) and the **top 20 by duration, CPU and logical reads** from Query Store |
| I/O | data file read and log file write latency per interval and per database, Log Flush Wait Time, Log Bytes Flushed/sec |
| TempDB | space used (user, internal, version store), version store size, allocation contention (tasks waiting on tempdb PAGELATCH) |
| Always On | synchronization state, log send queue, redo queue, transaction delay per database/replica; connections per listener IP |

The email shows a **Performance - needs attention** table and a **summary** (average / min / max of every metric); the attached report also has the per-interval tables and query lists.

**What it changes on the server, and puts back:** at the start it sets `blocked process threshold (s)` to `BlockedProcessThresholdSec` (5) and creates the XE session `DBA_PerfWindow`. At the end, even if the run fails or you press Ctrl+C, it drops the session and restores the original threshold. If a run is killed hard, the next run on that VM restores the value it recorded. That needs `ALTER SETTINGS` and `ALTER ANY EVENT SESSION` (sysadmin has both); without them it carries on read-only (live blocking from DMVs, no blocked process reports / deadlocks / long-query capture) and says so in the report.

**Query Store note:** Query Store groups statistics into intervals (60 min by default), so its top 20 includes the whole intervals that overlap the window. Databases without Query Store are listed in the report; the "queries over 5 s" list comes from Extended Events and is exact to the window.

**Thresholds** (`PerfThresholds` in `$Config`): PLE below 300 s, data read latency over 20 ms, log write latency over 10 ms, AG send queue over 100 MB. Deadlocks, blocking over 5 s, lock timeouts, memory grants pending, RESOURCE_SEMAPHORE waits, tempdb allocation waits and queries over 5 s are flagged whenever they happen. An AG database that stops synchronizing is CRITICAL.

**AG note:** run it on the VM hosting the primary replica to see send/redo queues for every replica; a secondary only sees its own.

## Scheduling (option 5)

Choose **5 = SCHEDULE** (run `Run-PrePostCheck.bat` as administrator). It shows the existing scheduled checks and lets you:
- **A** - add or replace a schedule: label, daily / weekly (chosen days) / once, start time, sample interval and window length, and the **Windows account the task runs as** (it needs SQL access on every instance; Task Scheduler stores its password and runs it whether anyone is logged on or not).
- **D** - delete one.

The task runs `Run-PrePostCheck.bat -Phase HEALTH -Unattended -Ticket <label> -SampleSec N -DurationMin M`. Unattended runs never prompt or pause, don't need Secondary Logon, and email the report as usual; the log is in `Logs\`. Test one straight away with `Start-ScheduledTask -TaskName "DBA SQL Health Check - <label>"`. The account needs the **Log on as a batch job** right on the VM.

## Command line (optional)

```bat
Run-PrePostCheck.bat -Phase HEALTH
Run-PrePostCheck.bat -Phase HEALTH -SampleSec 30 -DurationMin 15
Run-PrePostCheck.bat -Phase HEALTH -NoPerf
Run-PrePostCheck.bat -Phase SCHEDULE
Run-PrePostCheck.bat -Phase CLEANUP
```

```powershell
.\Invoke-PrePostCheck.ps1 -Phase PRE  -Ticket CHG0012345
.\Invoke-PrePostCheck.ps1 -Phase POST -Ticket CHG0012345 -UseCurrentUser
.\Invoke-PrePostCheck.ps1 -Phase POST -Ticket CHG0012345 -Instances 'SQLVM1','SQLVM1\INST2'
```

## Permissions and troubleshooting

Your account needs `VIEW SERVER STATE`, read access to `msdb`, and `DatabaseMailUserRole` (or sysadmin) on every instance. Both your account and the RDP account need write access to the folder (snapshots, reports and logs are written by whichever account checks the instance). The script grants both accounts Modify on the folder at the start of each run (`icacls`, inherited by all subfolders). If that isn't allowed, a snapshot it can't save goes to that account's `%TEMP%\DBA_PrePostCheck\Snapshots\<ticket>` and the report says so; copy it into `Snapshots\<ticket>` before the POST run.
For the SSIS / SSRS / SSAS sections it also needs:
- **SSIS:** read access to `SSISDB` (sysadmin, or `ssis_admin`). Otherwise the section is skipped and a warning is added.
- **SSRS:** read access to the report server database (for example `ReportServer`). It must be on the same instance; a remote report server catalog isn't seen.
- **SSAS:** SSAS server administrator rights, and the **MSOLAP OLE DB provider** on the VM (installed with SSAS / SSMS). If either is missing, the SSAS service state is still captured and a warning explains why the databases couldn't be read.
- SSIS/SSRS/SSAS **services** are read from the VM itself, so they're only captured for instances discovered on this VM, not for `ExtraInstances` entries.
For other problems (credentials, folder access, `Login failed`, mail stuck as `unsent`/`failed`, execution policy), see the troubleshooting table in [`../health-check/README.md`](../health-check/README.md); the same fixes apply.

## Cleanup

Every run first deletes files older than **48 hours** from `Reports\` and `Logs\`, and from `Snapshots\` once a ticket has its **POST**. A PRE still waiting for its POST is kept for **7 days**, so a change done later can still be compared. Change this with `CleanupHours` (`0` turns it off) and `KeepPreWithoutPostDays` in `$Config`.

To clean up without running a check, choose `4` CLEANUP, or schedule `Run-PrePostCheck.bat -Phase CLEANUP` daily in Task Scheduler ("Start in": this folder). Cleanup doesn't ask for credentials or start Secondary Logon.
