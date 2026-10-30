# One-click PRE / POST change check

Before a change (patching, CU, in-place upgrade, failover test, config change), run it with **PRE**. After the change, run it with **POST**. It checks **every SQL instance on the VM**:

- **PRE** collects a full health-check snapshot, **stores it on the VM** as JSON, and emails a *PRE captured* report, which gives the team a baseline.
- **POST** collects the same snapshot, **compares it with the stored PRE**, and emails one of:
  - 🟢 **`[POST SUCCESS]`**: no unexpected differences and no new problems. Expected changes such as the new build/CU are listed for the record.
  - 🔴 **`[POST DIFFERENCES]`**: a *before → after* table of every unexpected difference, plus any problems that are new since PRE. Sent with high importance.
  - 🟡 **`[POST NO BASELINE]`**: no PRE snapshot was found, so it sends the POST report only.

Every email also includes the full POST health report. Copies of the snapshots and HTML reports stay on the VM as evidence.

## Files

| File | Purpose |
|---|---|
| `Run-PrePostCheck.bat` | Double-click this. |
| `Invoke-PrePostCheck.ps1` | Handles the prompts and relaunches as your account. Then it runs the instances, stores the snapshots, compares PRE and POST, and emails the result through Database Mail. |
| `HC_Snapshot.sql` | A data-only version of `scripts/44`. It contains the same checks plus config, trace flags, all jobs, logins, server roles, linked servers, endpoints, certificates and XE sessions. |
| `servers.txt.example` | Optional. Rename it to `servers.txt` to add instances on other VMs. |

Folders that are created automatically: `Snapshots\<ticket>\` (JSON), `Reports\` (HTML) and `Logs\`.

## Set up once per VM

1. Copy the folder to a place **your own account can read and write**, for example `C:\DBA\PrePostCheck`. Snapshots must be writable there.
2. In `Invoke-PrePostCheck.ps1` → `$Config`, set `Recipients` and your usual `MailProfile`. Optionally adjust the tolerances (below).

## Run it

1. RDP in with the generic admin account and double-click `Run-PrePostCheck.bat`.
2. Enter `PRE` or `POST` and the **change ticket**. The ticket is how PRE and POST get paired, so use the same one for both runs.
3. Enter **your** Windows account at the credential prompt, the same one you use for SSMS "Run as different user". Cancel runs it as the current account.
4. Read the summary in the window and check your mailbox.

**When to run POST:** after services are up and the **AG databases are SYNCHRONIZED** again. If they're still catching up, the check will rightly report it as a difference. Also resume any jobs you paused, otherwise jobs left disabled will show up as differences.

If POST finds no PRE for that ticket, it offers the **latest PRE for that instance** and shows its ticket, time and user, then asks you to confirm. If you decline or none exists, it sends the POST report as *NO BASELINE*.

## What is compared

| Area | Compared | Treated as expected (listed, not a failure) |
|---|---|---|
| Instance | edition, collation, FCI/HADR, active node, CPUs, memory, memory model | build, CU, KB, product level, SQL start time |
| Services | status, startup type, service account, IFI | last start time |
| sp_configure / trace flags | every value, global flags added or removed | |
| Databases | state, user access, recovery model, compat level, owner, read-only, page verify, RCSI, snapshot isolation, TDE, broker, trustworthy, Query Store, AG name/role/sync state, full and log backup **folders** | size changes within tolerance |
| Always On | each replica's role, **primary replica**, commit/failover mode, connected, health, readable, endpoint, backup priority, listeners; each DB's role, sync state, health and suspended flag on every replica | |
| Cluster | quorum type/state, member type/state, votes | |
| Disks / files | disk size, file paths, type, state, growth, max size | free space and size changes within tolerance |
| Jobs / security / objects | job enabled/owner/category; logins (type, disabled, default DB); server role members; linked servers; endpoints; certificates; XE sessions | |
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

Your account needs `VIEW SERVER STATE`, read access to `msdb`, and `DatabaseMailUserRole` (or sysadmin) on every instance. It also needs write access to the folder.
For other problems (credentials, folder access, `Login failed`, mail stuck as `unsent`/`failed`, execution policy), see the troubleshooting table in [`../health-check/README.md`](../health-check/README.md); the same fixes apply.

## Cleanup

Double-click `Cleanup-OldFiles.bat` to delete files older than **48 hours** from `Reports\` and `Logs\` and `Snapshots\`. A ticket's snapshots are deleted only once it has a **POST**; a PRE still waiting for its POST is kept for 7 days (`-KeepPreWithoutPostDays`), so a change done later can still be compared. Use `Cleanup-OldFiles.bat -Hours 72` for a different age, or `-WhatIf` to preview without deleting. To run it automatically, schedule it daily in Task Scheduler (action: the `.bat`, "Start in": this folder).
