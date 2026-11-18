# Health & performance check as a SQL Agent job (no PowerShell)

The same check as [`automation/perf-check`](../perf-check/README.md), written entirely in **T-SQL**, for servers where PowerShell can't be used. One file, [`HealthPerfCheck_AgentJob.sql`](HealthPerfCheck_AgentJob.sql), installs a stored procedure and creates a **SQL Agent job** that runs it and emails the report through **Database Mail**.

## What it does (per instance)

1. **Health check:** instance and build, SQL Server and Windows uptime, services, vitals, databases (state, recovery, backups, CHECKDB, log use, AG role), Always On replicas / listeners (IP, static / DHCP) / databases, cluster and quorum, disks, failed job steps (24 h), severe error log entries, key `sp_configure` values, trace flags, linked servers, endpoints, certificates, XE sessions, SSIS catalog / projects / environments / failures, SSRS content and subscriptions, and the state of the **SSIS / SSRS / SSAS services** on the server.
   *Not included:* the data / log file list, the Agent job list, logins, server role members, and SSAS databases (those need PowerShell / the MSOLAP provider).
2. **Performance window:** a sample every `@SampleSec` seconds for `@DurationMin` minutes (default 60 s for 30 min), with the same metrics as the PowerShell version: throughput, compilations, connections and connection pool usage, locking / blocking / deadlocks, memory, wait stats per interval, file latency, log flush, tempdb, Always On queues / transaction delay / listener connections.
   **Root cause with SPID and statement:** head blockers (including idle sessions holding an open transaction), problem sessions (blocked, I/O / log / memory / tempdb waits, long running), memory grants, tempdb users, every deadlock process plus the deadlock graph XML, every query over 5 s (Extended Events), and the top 20 queries of the window by duration / CPU / reads from the plan cache (no Query Store needed).
3. **One email:** the body has the summary, both *needs attention* tables, head blockers, the top 10 problem sessions and the metric summary; the **full report is attached** as an `.html` file.

## Install

1. **Database Mail** must work on the instance. [`scripts/45_database_mail_setup.sql`](../../scripts/45_database_mail_setup.sql) sets it up, makes the profile the default and raises the attachment limit to 10 MB (the report is usually 0.3–3 MB).
2. Open `HealthPerfCheck_AgentJob.sql` in SSMS as **sysadmin**.
3. **PART 1** (top of the file): leave `USE [master];` or change it to your DBA database, then run PART 1. It creates `dbo.DBA_PerfCheck_State`, `dbo.fn_DBA_Html`, `dbo.usp_DBA_HtmlTable` and `dbo.usp_DBA_HealthPerfCheck`. Safe to re-run to upgrade.
4. **Test by hand** with a short window; the report comes back as a clickable XML cell instead of an email:
   ```sql
   EXEC dbo.usp_DBA_HealthPerfCheck @SampleSec = 10, @DurationMin = 1, @SendEmail = 0;
   ```
   or send it:
   ```sql
   EXEC dbo.usp_DBA_HealthPerfCheck @Recipients = N'dba-team@yourcompany.com', @SampleSec = 10, @DurationMin = 2;
   ```
5. **PART 2** (bottom of the file): set the parameters at its top and run it. It creates (or replaces) the job **DBA - Health & Performance Check** with one T-SQL step and a schedule:

| Parameter | Meaning |
|---|---|
| `@ProcDatabase` | database used on the `USE` line of PART 1 |
| `@Recipients`, `@CopyRecipients`, `@MailProfile`, `@FromAddress` | email settings (`@MailProfile` NULL = default profile) |
| `@SampleSec`, `@DurationMin` | performance window; the job runs about `@DurationMin` + 1 minutes |
| `@PerfDatabases` | e.g. `N'MARS,CLR'` for Transactions/sec; NULL = all databases |
| `@NoPerf` | 1 = health check only |
| `@Schedule` | `DAILY`, `WEEKLY` (with `@WeekDays = 'Mon,Wed,Fri'`), `ONCE` (with `@OnceDate`) or `NONE` (run on demand) |
| `@StartTime` | `HH:mm`, server time |
| `@JobOwner` | NULL = `sa` (found by SID, works when `sa` is renamed or disabled) |
| `@NotifyOperator` | optional Agent operator emailed if the job itself fails |

Run the job now: `EXEC msdb.dbo.sp_start_job @job_name = N'DBA - Health & Performance Check';`

On an **Always On** VM, install and create the job on **every replica**. The job only reports the instance it runs on, so there's one email per instance (the PowerShell version combines all instances on a VM into one email). Send/redo queues of every replica are only visible on the primary.

## What it changes on the server - and puts back

During the window: `blocked process threshold (s)` is set to `@BlockedThresholdSec` (5) and the XE session `DBA_PerfCheckJob` is created. At the end, and also when the procedure fails, the session is dropped and the threshold restored. If the job is **stopped** half-way, the original value stays in `dbo.DBA_PerfCheck_State` and is restored at the start of the next run (or run the job again). Check:

```sql
SELECT value_in_use FROM sys.configurations WHERE name = 'blocked process threshold (s)';
SELECT name FROM sys.dm_xe_sessions WHERE name = 'DBA_PerfCheckJob';
SELECT * FROM dbo.DBA_PerfCheck_State;   -- empty = nothing to restore
```

## Email

- The full report is attached as a **query result** (Database Mail's `@query` attachment), so no file is written to disk and it works for any login.
- If the report is bigger than Database Mail's `MaxFileSize`, or the attachment fails, the email still goes out with the summary and a note.
- If the check itself fails, a `[FAILED]` email with the error is sent and the job step fails, so the job history and `@NotifyOperator` show it.
- The step's output in the job history shows the `mailitem_id`; check delivery with `SELECT sent_status FROM msdb.dbo.sysmail_allitems WHERE mailitem_id = <id>;`.

## Differences from the PowerShell version

| | PowerShell (`perf-check`) | Agent job (this folder) |
|---|---|---|
| Instances | every instance on the VM, one combined email | the instance it runs on |
| SSAS | services + SSAS databases | service state only |
| Deadlock graphs | saved as `.xdl` files and attached | XML shown in the attached report (copy into a `.xdl` file to see the diagram) |
| SMTP fallback | yes | no (Database Mail only) |
| Login | SQL login with Windows fallback | the job owner (`sa`) |
