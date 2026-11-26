# One-click PRE / POST change check

> **Files on the VM:** `Run-PrePostCheck.bat` (double-click), `Invoke-PrePostCheck.ps1` and `HC_Snapshot.sql`, plus your `settings.psd1` and, optionally, `db_mail_setup.sql`. Keep them together in one folder, for example `C:\DBA\PrePostCheck` (see [Install and update](#install-and-update)). The older `automation/health-check` folder (script 44) isn't needed.
>
> **Version 3.0.0** ([CHANGELOG](CHANGELOG.md)): settings moved to `settings.psd1`, checks are defined in `HC_Snapshot.sql`, and the CLEANUP option is gone (every run cleans up).

Double-click `Run-PrePostCheck.bat` and choose:

| # | Choice | What it does |
|---|---|---|
| 1 | **PRE** | Snapshot before a change, stored on the VM and emailed |
| 2 | **POST** | Snapshot after the change, compared with PRE, emailed as SUCCESS or DIFFERENCES |
| 3 | **HEALTH** | Health check only: one combined report with a `[CRITICAL]`, `[WARNING]` or `[OK]` subject. Nothing is stored for comparison |

Every run also deletes old snapshots, reports and logs (see [Cleanup](#cleanup)).

Before a change (patching, CU, in-place upgrade, failover test, config change), run it with **PRE**. After the change, run it with **POST**. It checks **every SQL instance on the VM**:

- **PRE** collects a full health-check snapshot, **stores it on the VM** as JSON, and emails a *PRE captured* report, which gives the team a baseline.
- **POST** collects the same snapshot, **compares it with the stored PRE**, and emails one of:
  - 🟢 **`[POST SUCCESS]`**: no unexpected differences and no new problems. Expected changes such as the new build/CU are listed for the record.
  - 🔴 **`[POST DIFFERENCES]`**: a *before → after* table of every unexpected difference, plus any problems that are new since PRE. Sent with high importance.
  - 🟡 **`[POST NO BASELINE]`**: no PRE snapshot was found, so it sends the POST report only.

**One report and one email per VM.** All instances on the VM go into a single HTML file, `Reports\<VM>_<PRE|POST>_<ticket>_<time>.html`. It opens with a summary table (one row per instance), followed by each instance's section. A single email is sent through the first instance that has working Database Mail, local instances first:
- The **email body** has the summary plus each instance's differences / new problems.
- The **full combined report is attached**. If it can't be attached, because it's bigger than Database Mail's `MaxFileSize` or the SQL Server service account can't read the `Reports` folder, the report goes in the email body instead, **without the data / log file list**, which stays in the report file on the VM (its path is given in the email).
- If Database Mail isn't usable on an instance, the script fixes it there and checks again:
  1. **Database Mail XPs off** → it runs `sp_configure 'Database Mail XPs', 1` + `RECONFIGURE`. `show advanced options` is turned on only for this step and put back afterwards if it was off.
  2. **No mail profile with an SMTP account** (none at all, or a profile with no account / no SMTP server) → it runs **`db_mail_setup.sql`** (your setup script, kept next to the `.ps1`). Its batches are split on `GO` and its `PRINT` messages go to the console and log. SQLCMD-mode lines (`:setvar`, `:r`, `:connect`) aren't supported.

  Both steps need sysadmin. If either one fails, the run carries on and the reason is shown on the `Email :` line of the summary. Turn this off with `AutoSetupDbMail = $false` in `settings.psd1`.
- If no instance has Database Mail, no email is sent and the combined report opens in your browser.

Snapshots (JSON) and reports stay on the VM as evidence. The report and email don't list **Agent jobs, logins or server role members**, to keep them short. These are still **compared**, so a job left disabled or a login change still shows up under *Unexpected differences*. Set `PerInstanceReports = $true` in `settings.psd1` if you also want one HTML file per instance, or `AttachReport = $false` to always put the report in the body.

The report and email footer show the script version, the `HC_Snapshot.sql` version and the settings file used, so you can tell which VMs still run an older version.

## Files

| File | Purpose |
|---|---|
| `Run-PrePostCheck.bat` | Double-click this. Starts the Secondary Logon service if needed, then runs the PowerShell script. |
| `Invoke-PrePostCheck.ps1` | Menu, credentials, run-as with fail-safe, snapshots, PRE/POST comparison, combined report, Database Mail and cleanup. Holds the default settings. |
| `HC_Snapshot.sql` | All the checks, run on every instance, and their `--@check` definitions (what is compared and how each section is shown). Must be the same version as the script. |
| `settings.psd1` | *Your settings* (recipients, mail profile, extra instances, tolerances). Not in the repo, so copying a newer version of the scripts never overwrites it. Start from `settings.example.psd1`. |
| `settings.example.psd1` | Every setting with its default and a short explanation. |
| `db_mail_setup.sql` | *Optional, your own file.* Run automatically on an instance where Database Mail is disabled or not configured. |
| `CHANGELOG.md` | What changed in each version. |

Folders that are created automatically: `Snapshots\<ticket>\` (JSON), `Reports\` (HTML) and `Logs\`.

## Install and update

**First install on a VM**
1. Copy `Run-PrePostCheck.bat`, `Invoke-PrePostCheck.ps1`, `HC_Snapshot.sql` and `settings.example.psd1` to a folder **your own account can read and write**, for example `C:\DBA\PrePostCheck`. Snapshots must be writable there.
2. Copy `settings.example.psd1` to `settings.psd1` and set at least `Recipients` and your usual `MailProfile`. Optionally adjust the tolerances (below), and list instances on other VMs (for example AG replicas) in `ExtraInstances = @('SQLVM2', 'SQLVM3\INST2')`. You only need to keep the lines you change.

**Update a VM:** copy the new `Invoke-PrePostCheck.ps1` **and** `HC_Snapshot.sql` over the old ones (always both: they carry the same version, and the run warns if they differ). Leave `settings.psd1`, `db_mail_setup.sql` and the `Snapshots` / `Reports` / `Logs` folders as they are.

**Coming from a version before 3.0.0** (settings in the script's `$Config` block): before you replace the script, note the values you changed in its `$Config` block (`Recipients`, `MailProfile`, `ExtraInstances`, ...) and put them in `settings.psd1`. The new script's `$Config` has the defaults only.

> Don't edit `Invoke-PrePostCheck.ps1` on a VM. A change made there is lost at the next update and makes that VM differ from the others. Put settings in `settings.psd1`, and change checks in the repo (see [Adding or changing a check](#adding-or-changing-a-check)).

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

**When to run POST:** after services are up and the **AG databases are SYNCHRONIZED** again. If they're still catching up, the check will rightly report it as a difference. Also resume any jobs you paused, otherwise jobs left disabled will show up as differences.

If POST finds no PRE for that ticket, it offers the **latest PRE for that instance** and shows its ticket, time and user, then asks you to confirm. If you decline or none exists, it sends the POST report as *NO BASELINE*.

## What is compared

| Area | Compared | Treated as expected (listed, not a failure) |
|---|---|---|
| Instance | edition, collation, FCI/HADR, active node, CPUs, memory, memory model. **SQL Server uptime and Windows uptime** are shown side by side (not compared) | build, CU, KB, product level, SQL start time, Windows boot time |
| Services | status, startup type, service account, IFI | last start time |
| sp_configure / trace flags | every value, global flags added or removed | |
| Databases | state, user access, recovery model, compat level, owner, read-only, page verify, RCSI, snapshot isolation, TDE, broker, trustworthy, Query Store, AG name/role/sync state | size changes within tolerance |
| Always On | each replica's role, **primary replica**, commit/failover mode, connected, health, readable, endpoint, backup priority, listeners; **listener IPs**: static or **DHCP**, subnet mask, network subnet, IP state, port (DNN listeners don't appear here); each DB's role, sync state, health and suspended flag on every replica | |
| Cluster | quorum type/state, member type/state, votes | |
| Disks / files | disk size, file paths, type, state, growth, max size | free space and size changes within tolerance |
| Jobs / security / objects | job enabled/owner/category; logins (type, disabled, default DB); server role members; linked servers; endpoints; certificates; XE sessions | |
| SSIS | SSIS service state; SSISDB catalog settings; projects (package count, version, deployed by); environments (variable count). Failed package executions in the last 24 h are reported as problems | catalog `SCHEMA_BUILD` / `SCHEMA_VERSION` |
| SSRS | Reporting Services / Power BI Report Server service; for each report server database on the instance: counts of folders, reports, data sources, datasets and schedules; each subscription (report, owner, enabled, failing). Failing subscriptions and failed report executions (24 h) are reported as problems | |
| SSAS | Analysis Services service; whether the instance can be queried; each database (compatibility level, type) | SSAS version, database `date_modified` |
| Problems | issues that exist **after but not before** = new problems | issues already present at PRE are listed separately |

**Tolerances**, set in `settings.psd1`:
- File/DB size changes are flagged only above **10 % and 512 MB** (`FileSizeDriftPct`, `FileSizeDriftMinMB`).
- Disk free-space changes are flagged only above **5 % of the disk** (`DiskFreeDriftPct`).

Last-backup *times*, log usage %, queue sizes and CPU are not compared, because they always move. A change of AG primary is **flagged on purpose**, so you'll notice if a failback was missed.

## Command line (optional)

```bat
Run-PrePostCheck.bat -Phase HEALTH
```

```powershell
.\Invoke-PrePostCheck.ps1 -Phase PRE  -Ticket CHG0012345
.\Invoke-PrePostCheck.ps1 -Phase POST -Ticket CHG0012345 -UseCurrentUser
.\Invoke-PrePostCheck.ps1 -Phase POST -Ticket CHG0012345 -Instances 'SQLVM1','SQLVM1\INST2'
.\Invoke-PrePostCheck.ps1 -Phase HEALTH -SettingsFile .\settings.test.psd1
```

## Adding or changing a check

Everything about a section lives in `HC_Snapshot.sql`, next to its query. Each output `SELECT` starts with `N'<section>' AS _section` and has `--@check` lines directly above it:

```sql
--@check databases: Databases & backups
--@   key: name
--@   compare: state, user_access, recovery_model, compat_level, owner_name, ...
--@   drift: size_mb=pct
SELECT N'databases' AS _section, d.name, d.state_desc AS state, ...
```

| Line | Meaning |
|---|---|
| `--@check <section>: <title>` | Starts a definition. The title is used in the report and in the *Section* column of differences. |
| `key: col, col` | Identifies a row. Rows only in PRE are *MISSING*, rows only in POST are *NEW*. No `key` = shown in the report, not compared. |
| `compare: col, col` | Must be equal in PRE and POST. |
| `expected: col, col` | May change; listed under *Expected changes*. |
| `expected_keys` / `ignore_keys` | Rows whose values may change (for example `build`), or that are never compared (for example uptime). |
| `drift: col=pct` / `col=disk` | Numeric tolerance: `pct` uses `FileSizeDriftPct` + `FileSizeDriftMinMB`, `disk` uses `DiskFreeDriftPct`. |
| `report: no` / `email: no` | Compared but not shown in the report / in the report file but not in the email body. |
| `source: powershell` | The section is collected by the script on the VM (SSIS / SSRS / SSAS services), not by a `SELECT`. |

Sections appear in the report in the order of the file. To add a check:
1. Add the `SELECT` (every value cast to text) and its `--@check` lines.
2. Raise the version in both `HC_Snapshot.sql` (`--@version`) and `Invoke-PrePostCheck.ps1` (`$ToolVersion`), and add a line to `CHANGELOG.md`.
3. Run the unit tests (see [automation/README.md](../README.md#tests-run-by-hand)). They check that every `SELECT` has a definition and that every column a definition names is in its `SELECT`. Then try it on a non-production VM before copying it to the others.

At run time the script also warns if a definition names a column the `SELECT` didn't return, or if the SQL returns a section without a definition (that section is still shown, at the end of the report).

## Permissions and troubleshooting

Your account needs `VIEW SERVER STATE`, read access to `msdb`, and `DatabaseMailUserRole` (or sysadmin) on every instance. Both your account and the RDP account need write access to the folder (snapshots, reports and logs are written by whichever account checks the instance). The script grants both accounts Modify on the folder at the start of each run (`icacls`, inherited by all subfolders). If that isn't allowed, a snapshot it can't save goes to that account's `%TEMP%\DBA_PrePostCheck\Snapshots\<ticket>` and the report says so; copy it into `Snapshots\<ticket>` before the POST run.
For the SSIS / SSRS / SSAS sections it also needs:
- **SSIS:** read access to `SSISDB` (sysadmin, or `ssis_admin`). Otherwise the section is skipped and a warning is added.
- **SSRS:** read access to the report server database (for example `ReportServer`). It must be on the same instance; a remote report server catalog isn't seen.
- **SSAS:** SSAS server administrator rights, and the **MSOLAP OLE DB provider** on the VM (installed with SSAS / SSMS). If either is missing, the SSAS service state is still captured and a warning explains why the databases couldn't be read.
- SSIS/SSRS/SSAS **services** are read from the VM itself, so they're only captured for instances discovered on this VM, not for `ExtraInstances` entries.
For other problems (credentials, folder access, `Login failed`, mail stuck as `unsent`/`failed`, execution policy), see the troubleshooting table in [`../health-check/README.md`](../health-check/README.md); the same fixes apply.

## Cleanup

Every PRE, POST and HEALTH run first deletes files older than **48 hours** from `Reports\` and `Logs\`, and from `Snapshots\` once a ticket has its **POST**. A PRE still waiting for its POST is kept for **7 days**, so a change done later can still be compared. Change this with `CleanupHours` (`0` turns it off) and `KeepPreWithoutPostDays` in `settings.psd1`.

There is no separate CLEANUP option any more (removed in 3.0.0). A Task Scheduler job that ran `Run-PrePostCheck.bat -Phase CLEANUP` now stops with a message, so remove it.

## AG failover tool (`AG-FailoverTool.ps1`)

A separate, menu-driven tool for Always On AGs during maintenance. Start PowerShell with "Run as different user" (your SQL account) and run `powershell.exe -ExecutionPolicy Bypass -File .\AG-FailoverTool.ps1`.

| Option | What it does |
|---|---|
| 1 | Records the primaries on one node and fails its AGs over to the best synchronous secondary. |
| 2 | Returns the AGs from an option 1 run to their original primaries. |
| 3 | Read-only AG health check. |
| 4 | Dry run on/off (prints the T-SQL and reboot commands without running them). |
| 5 | Rolling reboot of every VM in the cluster (below). |

**Rolling reboot (option 5).** Run it on one of the cluster VMs. The tool:
1. Finds the cluster nodes, or uses `VMs.txt` if it exists. Then it finds the SQL instances on them and takes a pre-snapshot of every AG primary.
2. Works through one VM at a time. Before each VM you choose to continue, skip it (for example when the maintenance window is over), run the rest without asking, skip all remaining VMs, or quit.
3. For each VM:
   - checks that the other nodes and the quorum witness are up and quorum survives losing this VM
   - fails over every AG primary on it
   - runs `shutdown /r /t 0`
   - waits for SQL to restart and the replicas to re-sync
   - returns that VM's AGs
4. Drains the VM it runs on last and stops for you to reboot that VM manually. After the reboot, run option 5 again and choose *Resume*. The tool returns that VM's AGs and rebalances every AG to the pre-snapshot layout.

`VMs.txt` (optional, next to the script) lists one VM per line in reboot order. Lines starting with `#` are ignored, and `VMNAME\INSTANCE` adds a named instance on that VM. The reboot runs `shutdown /r /t 0 /m \\VM` as your account, which must be local admin on the VMs. If it isn't, enter a Windows admin credential at the start and the reboot runs through WinRM. Progress is saved after every step, so a run that stops for any reason resumes with option 5. Output goes to `Logs\` (detailed errors with likely cause), `State\` (snapshots) and `Summary\` (leadership summary).
