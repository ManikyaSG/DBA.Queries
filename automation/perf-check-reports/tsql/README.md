# Health & performance check as a SQL Agent job (no PowerShell)

The same check as [PowerShell version](../powershell/README.md), written entirely in **T-SQL**, for servers where PowerShell can't be used. One file, [`HealthPerfCheck_AgentJob.sql`](HealthPerfCheck_AgentJob.sql), installs a stored procedure and creates a **SQL Agent job** that runs it and emails the report through **Database Mail**.

> **Several VMs, primary instances only, one email with one file per VM:** use the PowerShell version run by a SQL Agent job instead: see the [PowerShell version](../powershell/README.md#several-vms-primary-only-one-email-sql-agent-job) (`-PrimaryOnly`, `Run-PerfCheck-Agent.bat`, `CreateAgentJob_PerfCheck.sql`).

## What it does (per instance)

1. **Health check:** instance and build, SQL Server and Windows uptime, services, vitals, databases (state, recovery, backups, log use, AG role), Always On replicas / listeners (IP, static / DHCP) / databases, cluster and quorum, disks, failed job steps (24 h), severe error log entries, key `sp_configure` values, linked servers, endpoints, certificates, XE sessions, and the state of the **SSIS / SSRS / SSAS services** on the server.
   *Not included:* the data / log file list, the Agent job list, logins, server role members, and SSAS databases (those need PowerShell / the MSOLAP provider).
2. **Performance window:** a sample every `@SampleSec` seconds for `@DurationMin` minutes (default 60 s for 30 min), with the same metrics as the PowerShell version: throughput, compilations, connections and connection pool usage, locking / blocking / deadlocks, memory, wait stats per interval, file latency, log flush, tempdb, Always On queues / transaction delay / listener connections.
   **Root cause with SPID and statement:** head blockers (including idle sessions holding an open transaction), problem sessions (blocked, I/O / log / memory / tempdb waits, long running), memory grants, tempdb users, every deadlock process, and the top 20 queries of the window by duration / CPU / reads from the plan cache (no Query Store needed).
3. **One email with the full report in the body** (no attachment). If Database Mail rejects it, a compact report (without the per-interval tables and deadlock XML) is sent instead, then the short summary, so an email always goes out.

## Install

1. **Database Mail** must work on the instance. [`database_mail_setup.sql`](../database_mail_setup.sql) sets it up and makes the profile the default.
2. Open `HealthPerfCheck_AgentJob.sql` in SSMS as **sysadmin**.
3. **PART 1** (top of the file): leave `USE [master];` or change it to your DBA database, then run PART 1. It creates `dbo.DBA_PerfCheck_State`, `dbo.fn_DBA_Html`, `dbo.usp_DBA_HtmlTable` and `dbo.usp_DBA_HealthPerfCheck`. Re-run it to upgrade: each object is created only if it's missing and then `ALTER`ed, so nothing is dropped and granted permissions stay. It ends with *PART 1 done* or, if the procedure didn't compile, an error.
4. **Test by hand** with a short window; the report comes back as a clickable XML cell instead of an email:
   ```sql
   EXEC dbo.usp_DBA_HealthPerfCheck @SampleSec = 10, @DurationMin = 1, @SendEmail = 0;
   ```
   or send it:
   ```sql
   EXEC dbo.usp_DBA_HealthPerfCheck @Recipients = N'dba-team@yourcompany.com', @SampleSec = 10, @DurationMin = 2;
   ```
5. **PART 2** (bottom of the file): set the parameters at its top and run it. It creates the job **DBA - Health & Performance Check** with its steps and schedule, or, if the job already exists, **updates it in place** (`@UpdateExisting = 1`): the job and its history stay, the steps and schedule are rebuilt from the parameters.

| Parameter | Meaning |
|---|---|
| `@ProcDatabase` | database used on the `USE` line of PART 1 |
| `@Recipients`, `@CopyRecipients`, `@MailProfile`, `@FromAddress` | email settings (`@MailProfile` NULL = default profile) |
| `@SampleSec`, `@DurationMin` | performance window; the job runs about `@DurationMin` + 1 minutes |
| `@PerfDatabases` | e.g. `N'MARS,CLR'` for Transactions/sec; NULL = all databases |
| `@NoPerf` | 1 = health check only |
| `@PrimaryOnly` | 1 = add step 1, the AG role check (run only on the primary); 0 = every replica runs the check |
| `@Schedule` | `DAILY`, `WEEKLY` (with `@WeekDays = 'Mon,Wed,Fri'`), `ONCE` (with `@OnceDate`) or `NONE` (run on demand) |
| `@StartTime` | `HH:mm`, server time |
| `@JobOwner` | NULL = `sa` (found by SID, works when `sa` is renamed or disabled) |
| `@NotifyOperator` | optional Agent operator emailed if the job itself fails |

Run the job now: `EXEC msdb.dbo.sp_start_job @job_name = N'DBA - Health & Performance Check';`

**Always On:** install PART 1 and create the job on **every replica**. With `@PrimaryOnly = 1` (default) the job has two steps:

1. **AG role check:** carries on if the instance has no availability group, is **primary** for at least one, or an AG is **resolving** (no primary, so an outage is never silent). If it is **secondary for every AG**, the step stops the job on purpose: the job ends as **succeeded**, no email, and the step history says *Skipped: … is a SECONDARY replica …*.
2. **The check** (`dbo.usp_DBA_HealthPerfCheck`).

After a failover the new primary starts reporting on its own; nothing to change. The primary's report shows every replica's sync state, send and redo queues. Instance-level health of the secondaries (their disks, services, error log, blocking) is **not** checked in this mode; set `@PrimaryOnly = 0` to create the job without step 1, and every replica then reports itself. The job reports only the instance it runs on (the PowerShell version combines all instances on a VM into one email).

## What it changes on the server - and puts back

During the window: `blocked process threshold (s)` is set to `@BlockedThresholdSec` (5) and the XE session `DBA_PerfCheckJob` is created. At the end, and also when the procedure fails, the session is dropped and the threshold restored. If the job is **stopped** half-way, the original value stays in `dbo.DBA_PerfCheck_State` and is restored at the start of the next run (or run the job again). Check:

```sql
SELECT value_in_use FROM sys.configurations WHERE name = 'blocked process threshold (s)';
SELECT name FROM sys.dm_xe_sessions WHERE name = 'DBA_PerfCheckJob';
SELECT * FROM dbo.DBA_PerfCheck_State;   -- empty = nothing to restore
```

## Email

- The **full report is the email body**: no attachment, so Database Mail's attachment limit (`MaxFileSize`) doesn't matter.
- If Database Mail rejects the full body, the **compact report** is sent (everything except the per-interval tables and the deadlock XML), and if that is rejected too, the **short summary** with the reason. The return code of `sp_send_dbmail` is checked, so a silent rejection is caught too.
- If no email at all can be sent, or the check itself fails, the job step fails (after trying to send a `[FAILED]` email), so the job history and `@NotifyOperator` show it.
- The step's output in the job history shows the `mailitem_id`; check delivery with `SELECT sent_status FROM msdb.dbo.sysmail_allitems WHERE mailitem_id = <id>;`.
- Very large bodies (several MB, e.g. a long window with many problem sessions) can be clipped by some mail clients; shorten `@DurationMin` or raise `@SampleSec` if that happens.

## Differences from the PowerShell version

| | PowerShell (`powershell/`) | Agent job (`tsql/`, this folder) |
|---|---|---|
| Instances | every instance on the VM, one combined email | the instance it runs on |
| SSAS | services + SSAS databases | service state only |
| Report | attached `.html` file + summary in the body | full report in the email body |
| SMTP fallback | yes | no (Database Mail only) |
| Login | SQL login with Windows fallback | the job owner (`sa`) |
