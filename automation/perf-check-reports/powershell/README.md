# SQL Server health & performance check (one click)

For **every SQL Server instance on the VM**: a **health check** (including SSIS / SSRS / SSAS), then a **performance window** sampled every **60 s for 30 min** (configurable), then **one combined report** emailed through Database Mail and saved in `Reports\`. No menu: it does one thing. `-NoPerf` = health check only, `-NoHealth` = performance window only.

**3 files**, kept together in a folder such as `C:\DBA\PerfCheck`:

| File | Purpose |
|---|---|
| `Run-PerfCheck.bat` | Double-click this (or schedule it). |
| `Invoke-PerfCheck.ps1` | Connects, runs the health check, samples, builds the report, sends the email. All settings are in `$Config` at the top. |
| `PerfCheck.sql` | The T-SQL it runs, plus the **one-time SETUP** block for the SQL login at the top. |

## Health check (once, at the start)

Instance and build, SQL Server and Windows uptime, services, vitals, databases (state, recovery model, compat, owner, size, log use, last full / diff / log backup, AG role), Always On replicas, listeners (IP, static / DHCP) and databases per replica, cluster and quorum, disk space, failed job steps (24 h), severe error log entries (24 h), sp_configure, trace flags, linked servers, endpoints, certificates, XE sessions, **SSIS** (catalog settings, projects, environments, failed executions 24 h), **SSRS** (content and subscriptions of the report server databases on the instance), and once for the VM the **SSIS / SSRS / SSAS services** and **SSAS databases**. Problems go into a *Needs attention* table per instance.

**Not included:** the data / log file list, the Agent job list, logins and server role members.

SSIS needs read access to `SSISDB`, SSRS to the `ReportServer` database, SSAS to SSAS administrator rights and the MSOLAP provider on the VM; without them that part is skipped with a warning. The SSAS check runs as the Windows account running the script (SSAS doesn't use SQL logins).

## Performance window: what it captures

| Area | Metrics |
|---|---|
| Throughput | Batch Requests/sec; Transactions/sec for `PerfDatabases` (e.g. `@('MARS','CLR')`; empty = all), plus a per-database table |
| Compilation | SQL Compilations/sec, SQL Re-Compilations/sec |
| Connections | User Connections; connection pool usage = sessions per application / host / login (peak, average, peak active) |
| Locking | Lock Waits/sec, Lock Wait Time, Lock Timeouts/sec, Deadlocks/sec, sessions blocked over 5 s; **blocked process reports** (threshold 5 s) and **deadlocks** from a temporary Extended Events session |
| Memory | Page Life Expectancy, Buffer cache hit ratio, Memory Grants Pending, Target vs Total Server Memory |
| Wait stats | ms waited **per interval**: LCK_M_\*, PAGEIOLATCH_\*, PAGELATCH_\*, WRITELOG, CXPACKET, CXCONSUMER, SOS_SCHEDULER_YIELD, HADR_SYNC_COMMIT, RESOURCE_SEMAPHORE |
| Queries | **top 20 by duration, CPU and logical reads** in the window, from the plan cache (`sys.dm_exec_query_stats` at the start vs the end; **no Query Store needed**), and **every query over 5 s** (Extended Events) |
| I/O | data / log file read and write latency per interval and per database, Log Flush Wait Time, Log Bytes Flushed/sec |
| TempDB | space used (user, internal, version store), version store size, allocation contention |
| Always On | synchronization state, log send queue, redo queue, transaction delay per database / replica; connections per listener IP |

**Root cause - SPID and statement** (collected at each sample, only for sessions with a problem, merged across samples with first / last seen and peak values):

| Table | What's in it |
|---|---|
| Head blockers | the session at the top of each blocking chain: SPID, login, host, program, database, status, open transactions, sessions blocked, longest block, statement. **Idle sessions holding an open transaction** are included with the last statement they ran (flagged in *needs attention*) |
| Problem sessions | every request that is blocked over 5 s, waiting on I/O (PAGEIOLATCH), the log (WRITELOG), memory (RESOURCE_SEMAPHORE) or tempdb pages, or running longer than 5 s: reason, SPID, login, host, program, database, wait type / time / resource, blocked by, elapsed, CPU, reads, writes, memory granted, tempdb used, open transactions, statement, object |
| Memory grants | queries waiting for memory, and grants of 1 GB or more (`BigGrantMB`): SPID, requested / granted / used MB, wait, DOP, statement |
| TempDB users | sessions using 500 MB or more of tempdb (`TempdbSessionMB`): SPID, login, host, program, user / internal objects MB, statement |
| Deadlocks | every process of every deadlock (victim, SPID, login, host, app, database, isolation level, lock mode, wait resource, statement), and each **deadlock graph saved as a `.xdl` file** in `Reports\` - double-click to see the diagram in SSMS. Up to 5 are attached to the email |
| Queries over 5 s | from Extended Events, now with the SPID |


**Email:** per instance the health *needs attention*, the performance *needs attention*, head blockers, the top 10 problem sessions and average / min / max of every metric. **Attachment:** the full report with the per-interval tables and query lists. If the report can't be attached (Database Mail `MaxFileSize`, or the SQL Server service account can't read `Reports\`), the email keeps the short version and gives the report's path on the VM. The subject is `[CRITICAL]`, `[WARNING]` or `[OK]`.

**Flagged:** PLE under 300 s, data read latency over 20 ms, log write latency over 10 ms, AG send queue over 100 MB (`PerfThresholds`); any deadlock, blocking over 5 s, lock timeout, memory grant pending, RESOURCE_SEMAPHORE wait, tempdb allocation wait or query over 5 s. An AG database that stops synchronizing is CRITICAL.

## Email - how it makes sure the report goes out

1. **The report is attached.** Database Mail doesn't allow file attachments for SQL logins (like `dba_perfcheck`), so the script attaches the report as a query result instead (same `.html` file name); with Windows authentication it attaches the file itself (and up to 5 deadlock graphs). The report must fit in Database Mail's `MaxFileSize` (about 1 MB by default): [`database_mail_setup.sql`](../database_mail_setup.sql) raises it to 10 MB (`@MaxFileSizeMB`). If it is still too big, or attaching fails, the email is sent with the summary and the report's path on the VM.
2. **Database Mail on every instance, one after the other** (local instances first). Only profiles this login can really use are picked: Database Mail XPs on, the profile has an SMTP account, and it is public, granted to the login, or the login is sysadmin (`MailProfile` is preferred). After queueing, the script waits until Database Mail has handed it to the SMTP server; if an instance can't queue it or Database Mail reports **failed**, the next instance is tried.
3. **SMTP straight from the VM** (fallback) when no instance could send it with the report attached: set `SmtpServer` (and `SmtpPort`, `SmtpUseSsl`, `SmtpFrom` if needed) in `$Config`. It uses .NET mail from the VM with the same subject, body and attachments, anonymous relay or `SmtpUseDefaultCredentials = $true` (the Windows account running the script). Only after that is a **summary-only** email sent through Database Mail, with the report's path on the VM.
4. **If the check itself fails** (script error), a short `[FAILED]` email with the error is sent the same way.
5. **If nothing worked**, the window shows `EMAIL NOT SENT` in red with every reason, the report opens in the browser (interactive runs), and the exit code is **4**, which Task Scheduler shows as *Last Run Result*.

To set up or repair Database Mail on an instance, use [`database_mail_setup.sql`](../database_mail_setup.sql) (it makes the profile public and default, which this check needs when it runs as the SQL login).

## One-time setup

1. **SQL login** - on **every instance** (every AG replica too), run the SETUP block at the top of `PerfCheck.sql` in SSMS as sysadmin, with your own password. It creates `dba_perfcheck` with only what the check needs: `VIEW SERVER STATE`, `VIEW ANY DEFINITION`, `ALTER SETTINGS`, `ALTER ANY EVENT SESSION`, read access to msdb (backup / job history) plus `DatabaseMailUserRole`, and EXECUTE on `xp_readerrorlog`. Optional lines in the block add read access to `SSISDB` and `ReportServer`. Missing access only skips that part, with a warning in the report. On AG replicas, create it with the **same SID** (shown in the block) so it keeps working after a failover. The instance must allow SQL authentication (mixed mode).
2. **Config** - in `Invoke-PerfCheck.ps1` set `Recipients`, `MailProfile`, `PerfDatabases`, and if needed `SampleSec` / `DurationMin`.
3. **First run** - double-click `Run-PerfCheck.bat` **as the Windows account that will run it later** (the scheduled task's or Agent proxy's account). It asks once for the `dba_perfcheck` password and offers to **save it for that account**. After that, its runs (and the job) don't ask anything.

**How the password is stored:** encrypted with Windows DPAPI, never in plain text. When the script runs, it's decrypted straight into a `SecureString` / `SqlCredential`, and never written to a connection string, the log or job history.
- `CredentialScope = 'CurrentUser'` (default): file `PerfCheck.<account>.cred`. **Only the Windows account that saved it can decrypt it, and only on this VM**; a copy of the file is useless to anyone else. The NTFS permissions are limited to Administrators, SYSTEM and that account.
- `CredentialScope = 'LocalMachine'`: file `PerfCheck.cred`. Any account on this VM that can read the file can decrypt it, so the NTFS permissions (Administrators, SYSTEM, the saver, `CredentialReaders`) are the only guard. Use this if the account running the job can't decrypt a CurrentUser file (DPAPI needs the account's user profile loaded).
- What no stored-password method can prevent: an administrator on the VM, or anything that runs as that account, can recover the password. That's why the login has only the permissions above.
- `Run-PerfCheck.bat -ResetCredential` to change it.

**Fail-safe:** if the SQL login can't connect to an instance (mixed mode off, login missing, wrong password, or no `VIEW SERVER STATE`), that instance is checked with **Windows authentication** as the account running the script. The **ConnectedAs** column shows which one was used. `-WindowsAuth` skips the SQL login completely. **`SqlAuthOnly = $true`** turns the fail-safe off: the instances are reached only with the SQL login, and an instance where it fails is reported as FAILED.

**Everything else runs as the Windows account running the script:** writing the reports and logs, reading SSIS / SSRS / SSAS services on other VMs, SMTP, and (with `MailWindowsAuth = $true`, the default) Database Mail on an instance on **this** machine. That's the one Windows connection to SQL Server, and it's what allows the report files to be attached; if it fails, the email goes out through the SQL login instead (summary, or one report as a query result).

## Run it

- **Double-click** `Run-PerfCheck.bat`: no questions after the first run; the window shows progress. Press **Q** to stop early (it takes one last sample and reports).
- **Other length / label:** `Run-PerfCheck.bat -SampleSec 30 -DurationMin 15 -Label LOADTEST1`
- **Only some instances:** `Run-PerfCheck.bat -Instances SQLVM1,SQLVM1\INST2`

Start it when the load test starts; with the defaults the email arrives about 31 minutes later.

## Test it in SSMS

`PerfCheck.sql` also runs as-is in SSMS (as a login with the permissions above):
- **F5 on the whole file** = a quick end-to-end test: the HEALTH check, then START (threshold + XE session + plan cache baseline), **one** sample, END (blocked process reports, deadlocks, long queries and top queries since START) and TEARDOWN (threshold restored, XE session dropped). The result grids are the same sections the script reads.
- **Block by block** (select the text between two `GO` lines and press F5), all in the **same query window** so the temp tables carry over: START, then SAMPLE a few times while you generate load, then END, then TEARDOWN. Always finish with TEARDOWN.
- Each block starts with its `DECLARE @p_...` parameters (threshold, long-query limit, top queries on/off); change them there for a manual test. The script sets them from `$Config`.

## Schedule it (Windows Task Scheduler)

1. Save the SQL login once **as the account the task runs as** (first run above, e.g. from `runas /user:<account> cmd`). With `CredentialScope = 'LocalMachine'` instead, add the task's account to `CredentialReaders` and save it again with `Run-PerfCheck.bat -ResetCredential`.
2. Task Scheduler > **Create Task**:
   - **General:** run as the account the task should use, *Run whether user is logged on or not*.
   - **Triggers:** when you want it (daily, weekly, once at the test start time).
   - **Actions:** Program `C:\DBA\PerfCheck\Run-PerfCheck.bat`, Arguments `-Unattended -Label SCHEDULED` (add `-SampleSec 60 -DurationMin 30` to override `$Config`), **Start in** `C:\DBA\PerfCheck`.
   - **Settings:** *Stop the task if it runs longer than* at least the window length + 30 min; *If the task is already running: Do not start a new instance*.
3. Right-click > **Run** to test it; the report is emailed and saved in `Reports\`, the log in `Logs\`.

`-Unattended` never prompts or pauses. Exit codes: 0 OK, 1 warnings, 2 critical or a failed instance, 3 script error, 4 email not sent (visible as *Last Run Result* in Task Scheduler). The account needs **Log on as a batch job** on the VM.

## What it changes on the server - and puts back

At the start, on each instance: `blocked process threshold (s)` is set to 5 and the XE session `DBA_PerfWindow` is created. At the end, even if the run fails or you press Ctrl+C, the session is dropped and the threshold restored. If a run is killed outright, the next run on that VM restores the recorded value first. Check after a test run:

```sql
SELECT value_in_use FROM sys.configurations WHERE name = 'blocked process threshold (s)';
SELECT name FROM sys.dm_xe_sessions WHERE name = 'DBA_PerfWindow';
```

## Overhead on a busy server

- **Sampling:** in-memory DMVs once per interval - negligible. Keep the interval at 60 s or more on heavy servers.
- **XE session:** blocked process reports and deadlocks only fire when they happen; the "over 5 s" filter on completed queries is a cheap check (up to ~1-2 % CPU on extremely high-throughput OLTP). Ring buffer capped at 8 MB / 2,000 events.
- **Top queries:** the plan cache is read once at the start and once at the end (a few seconds on a very large cache). `TopQueries = $false` skips it.

**Limits of the top 20:** plans evicted or recompiled during the window and `OPTION (RECOMPILE)` statements aren't counted (anything over 5 s is still in the Extended Events list). **Always On:** run it on the VM hosting the primary to see the queues of every replica.

## Several VMs, primary only, one email (SQL Agent job)

For example 3 VMs with 3 instances each, in Always On AGs: **one run** checks every instance, writes **one report file per VM** and sends **one email with all the files attached**.

**What gets checked (`-PrimaryOnly`):**
- An instance is checked if it is **PRIMARY for at least one AG**, or has **no AG** (standalone). An AG with no primary (RESOLVING) also counts, so an outage is never silent.
- An instance that is **SECONDARY for every AG** is listed in the summary as *skipped* and not checked.
- For the instances checked, the full instance health check is kept (services, disks, error log, jobs, blocking, waits, ...). The **AG, database and listener tables keep only the AGs the instance is primary for**: AGs where it is secondary, and their databases, are left out (per-database I/O latency and Transactions/sec too). Databases that are in no AG stay.
- The VM is the instance's physical host (`SERVERPROPERTY('ComputerNamePhysicalNetBIOS')`). Roles are read at the start; if an AG fails over during the window, the instance gets a warning in the report.
- A VM with no primary or standalone instance still gets a (short) file, so the email always has one file per VM.

**Setup on the server that runs it (the coordinator):**
1. Copy `Run-PerfCheck-Agent.bat`, `Invoke-PerfCheck.ps1`, `PerfCheck.sql` to e.g. `C:\DBA\PerfCheck`.
2. Copy `servers.example.txt` to `servers.txt` and list **every instance on every VM** (instance names, not listeners).
3. In `$Config`: `IncludeLocalInstances = $false`, `Recipients`, and optionally `PrimaryOnly = $true` (or pass `-PrimaryOnly`).
4. Run `CreateAgentJob_PerfCheck.sql` on that instance (set `@ScriptFolder`, `@Arguments`, `@ProxyName`, schedule). It creates a job with one **CmdExec** step: `cmd.exe /c ""C:\DBA\PerfCheck\Run-PerfCheck-Agent.bat" -PrimaryOnly -Label SCHEDULED"`.

**Accounts:** the step runs as an **Agent proxy** (a Windows / domain account, e.g. `EMEA\Admin.partner.db`). Recommended split:
- **SQL login `dba_perfcheck`** (`SqlAuthOnly = $true`) for every connection to the instances that collects data. Created with the SETUP block of `PerfCheck.sql` on every instance; its password is saved once **as the proxy's account** (`CredentialScope = 'CurrentUser'`), so only that account can decrypt it.
- **The proxy's Windows account** for everything else: files, reading the other VMs' services, and sending the email.
- **Several files in one email through Database Mail** need a **Windows login** and an instance with Database Mail on the **same server as the script** (`MailWindowsAuth = $true`, `MailInstance`): Database Mail reads the files from its own server's disk, and doesn't allow file attachments for SQL logins. Give the proxy's account a Windows login on that one instance with `DatabaseMailUserRole` in msdb. Each file must fit in `MaxFileSize`.
- Otherwise set **`SmtpServer`**: the email is sent straight from the server with every file attached. This is also the way when the script runs on a jump host without SQL Server.
- The order is: attached through Database Mail, then SMTP with the files, then a summary-only email through Database Mail (the reports stay in `Reports\`).

**Job result:** `Run-PerfCheck-Agent.bat` maps the exit code for Agent: 0 OK, 1 warnings and 2 critical findings become **success** (the email went out); 3 script error and 4 email not sent **fail** the step. Set `SUCCESS_MAX=1` in the .bat to make critical findings fail the job too. Full log in `Logs\`, last step output in `AgentJobStep_output.txt`.

**SSIS / SSRS / SSAS services** of the other VMs are read over CIM / WinRM (`RemoteBiServices`); if WinRM isn't open, the report shows a warning for that VM. Set `RemoteBiServices = $false` to skip them.

## Housekeeping

Reports and logs older than **7 days** are deleted at the start of each run (`CleanupHours`, `0` = keep).
