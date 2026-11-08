# One-click PRE / POST change check

> **One SQL file for everything:** this folder needs only `HC_Snapshot.sql`. It covers the PRE/POST change check **and** the daily health check (`Run-HealthCheck.bat`, or `-Phase HEALTH`). The older `automation/health-check` folder (script 44) isn't needed.

**Health check only:** double-click `Run-HealthCheck.bat` (or `.\Invoke-PrePostCheck.ps1 -Phase HEALTH`). It runs the same snapshot on every instance on the VM and emails **one combined health report** with a `[CRITICAL]`, `[WARNING]` or `[OK]` subject and the full report attached. Nothing is stored for comparison.

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

Snapshots (JSON) and reports stay on the VM as evidence. The report and email don't list **Agent jobs, logins or server role members**, to keep them short. These are still **compared**, so a job left disabled or a login change still shows up under *Unexpected differences*. Set `PerInstanceReports = $true` in `$Config` if you also want one HTML file per instance, or `AttachReport = $false` to always put the report in the body.

## Files

| File | Purpose |
|---|---|
| `Run-PrePostCheck.bat` | Double-click this. |
| `Invoke-PrePostCheck.ps1` | Handles the prompts, starts Secondary Logon and relaunches as your account (RDP account as fail-safe). Then it runs the instances, stores the snapshots, compares PRE and POST, and emails the result through Database Mail. |
| `HC_Snapshot.sql` | A data-only version of `scripts/44`. It contains the same checks plus config, trace flags, all jobs, logins, server roles, linked servers, endpoints, certificates and XE sessions. |
| `servers.txt.example` | Optional. Rename it to `servers.txt` to add instances on other VMs. |

Folders that are created automatically: `Snapshots\<ticket>\` (JSON), `Reports\` (HTML) and `Logs\`.

## Set up once per VM

1. Copy the folder to a place **your own account can read and write**, for example `C:\DBA\PrePostCheck`. Snapshots must be writable there.
2. In `Invoke-PrePostCheck.ps1` → `$Config`, set `Recipients` and your usual `MailProfile`. Optionally adjust the tolerances (below).

## Run it

1. RDP in with the generic admin account and double-click `Run-PrePostCheck.bat`.
2. Enter `PRE` or `POST` and the **change ticket**. The ticket is how PRE and POST get paired, so use the same one for both runs.
3. Enter **your** Windows account at the credential prompt, the same one you use for SSMS "Run as different user". **This is always the first choice.**
   - The `.bat` (and the script) start the **Secondary Logon** service if it's stopped or disabled (UAC prompt if the window isn't elevated). The check then runs **as your account** in a new window.
   - **Fail-safe, per instance:** if your account can't log in to an instance, or has no `VIEW SERVER STATE` there, that instance is handed back to the original window and retried as the **logged-in RDP account**. Everything still ends up in one combined report and one email. If both accounts fail, the instance shows *FAILED* with both errors.
   - **Fail-safe, run-as:** if the new window can't start at all (Secondary Logon won't start, or the logon is refused), the script uses your account from the original window instead, still before the RDP account.
   - The summary, report and email have a **ConnectedAs** column, so you can see which account checked each instance.
   - Cancel at the prompt runs it as the RDP account only.
4. Read the summary in the window and check your mailbox.

**When to run POST:** after services are up and the **AG databases are SYNCHRONIZED** again. If they're still catching up, the check will rightly report it as a difference. Also resume any jobs you paused, otherwise jobs left disabled will show up as differences.

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
| Jobs / security / objects | job enabled/owner/category; logins (type, disabled, default DB); server role members; linked servers; endpoints; certificates; XE sessions | |
| SSIS | SSIS service state; SSISDB catalog settings; projects (package count, version, deployed by); environments (variable count). Failed package executions in the last 24 h are reported as problems | catalog `SCHEMA_BUILD` / `SCHEMA_VERSION` |
| SSRS | Reporting Services / Power BI Report Server service; for each report server database on the instance: counts of folders, reports, data sources, datasets and schedules; each subscription (report, owner, enabled, failing). Failing subscriptions and failed report executions (24 h) are reported as problems | |
| SSAS | Analysis Services service; whether the instance can be queried; each database (compatibility level, type) | SSAS version, database `date_modified` |
| Problems | issues that exist **after but not before** = new problems | issues already present at PRE are listed separately |

**Tolerances**, set in `$Config`:
- File/DB size changes are flagged only above **10 % and 512 MB** (`FileSizeDriftPct`, `FileSizeDriftMinMB`).
- Disk free-space changes are flagged only above **5 % of the disk** (`DiskFreeDriftPct`).

Last-backup *times*, log usage %, queue sizes and CPU are not compared, because they always move. A change of AG primary is **flagged on purpose**, so you'll notice if a failback was missed.

## Command line (optional)

```powershell
.\Invoke-PrePostCheck.ps1 -Phase PRE  -Ticket CHG0012345
.\Invoke-PrePostCheck.ps1 -Phase POST -Ticket CHG0012345 -UseCurrentUser
.\Invoke-PrePostCheck.ps1 -Phase POST -Ticket CHG0012345 -Instances 'SQLVM1','SQLVM1\INST2'
```

## Permissions and troubleshooting

Your account needs `VIEW SERVER STATE`, read access to `msdb`, and `DatabaseMailUserRole` (or sysadmin) on every instance. Both your account and the RDP account need write access to the folder (snapshots, reports and logs are written by whichever account checks the instance).
For the SSIS / SSRS / SSAS sections it also needs:
- **SSIS:** read access to `SSISDB` (sysadmin, or `ssis_admin`). Otherwise the section is skipped and a warning is added.
- **SSRS:** read access to the report server database (for example `ReportServer`). It must be on the same instance; a remote report server catalog isn't seen.
- **SSAS:** SSAS server administrator rights, and the **MSOLAP OLE DB provider** on the VM (installed with SSAS / SSMS). If either is missing, the SSAS service state is still captured and a warning explains why the databases couldn't be read.
- SSIS/SSRS/SSAS **services** are read from the VM itself, so they're only captured for instances discovered on this VM, not for `servers.txt` entries.
For other problems (credentials, folder access, `Login failed`, mail stuck as `unsent`/`failed`, execution policy), see the troubleshooting table in [`../health-check/README.md`](../health-check/README.md); the same fixes apply.

## Cleanup

Double-click `Cleanup-OldFiles.bat` to delete files older than **48 hours** from `Reports\` and `Logs\` and `Snapshots\`. A ticket's snapshots are deleted only once it has a **POST**; a PRE still waiting for its POST is kept for 7 days (`-KeepPreWithoutPostDays`), so a change done later can still be compared. Use `Cleanup-OldFiles.bat -Hours 72` for a different age, or `-WhatIf` to preview without deleting. To run it automatically, schedule it daily in Task Scheduler (action: the `.bat`, "Start in": this folder).
