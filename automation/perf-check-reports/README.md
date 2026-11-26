# Perf check reports

Daily health & performance check of every SQL Server instance, **one email** with **one HTML report per VM**. Everything for it lives in this folder.

| File | What it is |
|---|---|
| [`HealthPerfCheck_AgentJob.sql`](HealthPerfCheck_AgentJob.sql) | Everything on the SQL Server side. **PART 1** (every instance): the procedure `usp_DBA_HealthPerfCheck` and the results table `DBA_PerfCheck_Report` in **DBAdmin**. **PART 2** (every instance): the check job. **PART 3** (one instance): the collector job. |
| [`Create_PerfCheck_Logins.sql`](Create_PerfCheck_Logins.sql) | The logins: **section A** (every instance) the read-only SQL login `dba_perfcheck` for the collector (`SELECT` on the results table only); **section B** (coordinator) Database Mail access for the Agent service account; **section C** password change / clean-up reference. |
| [`Collect-PerfCheckReports.ps1`](Collect-PerfCheckReports.ps1) | The collector: reads the latest result of every instance, writes one HTML file per VM, sends one email with all files attached. |
| [`database_mail_setup.sql`](database_mail_setup.sql) | Database Mail setup / repair (only needed on the instance that sends the email). |
| [`SETUP.txt`](SETUP.txt) | Step-by-step setup. |
| `settings.psd1` | *Your settings* for the collector (instances, recipients, mail instance, subject). Start from [`settings.example.psd1`](settings.example.psd1); kept when the script is updated. Without it, the defaults in the script's `$Config` block are used. |
| [`CHANGELOG.md`](CHANGELOG.md) | Versions of the collector. |

## How it works

```
06:00  every instance   SQL Agent job "DBA - Health & Performance Check"
                        health check + performance window (every 30 s for 5 min)
                        -> one row in DBAdmin.dbo.DBA_PerfCheck_Report (finished HTML + status)
06:10  one instance     SQL Agent job "DBA - Perf Check Reports (collector)"
                        Collect-PerfCheckReports.ps1: reads the 9 rows, one HTML file per VM,
                        one email with all files attached
```

- **Primary only:** an instance that is SECONDARY for every availability group saves a *SKIPPED* row and does no work. The others report the full instance health check, but the AG, database and listener tables show **only the AGs the instance is primary for**. Instances without an AG are always reported.
- **Nothing missed silently:** the collector waits (up to 15 min) for runs still going. An instance with no result, a failed run or no connection is shown in red in the email.
- **History:** every run stays in `DBA_PerfCheck_Report` for 30 days (`@KeepDays`). `DBAdmin` must not be in an availability group (secondaries can't write to it).
- **Top lists:** top 5 queries of the window by duration, CPU and logical reads (plan cache, no Query Store), top 5 databases by transactions/s.
- **Not included:** global trace flags, SSIS catalog / SSRS content tables, deadlock graphs, long-query capture, failed Agent job steps / job history, data / log file list, Agent job list, logins.
- **DBAdmin** (where the check runs) is shown in the database list only: no warnings for it, and it is left out of file latency, transactions/s, problem sessions, head blockers, memory grants and the top queries (so the check doesn't report itself).

## Accounts

| Who | Used for | Rights |
|---|---|---|
| Job owner (`sa`) | the check on each instance (runs locally) | sysadmin (the job owner) |
| SQL login `dba_perfcheck` | the collector reading the results | `SELECT` on `DBAdmin.dbo.DBA_PerfCheck_Report` only |
| SQL Agent service account of the coordinator | running the collector, writing files, sending the email | Modify on the script folder; its normal Database Mail access on that instance |
| Your admin account (secondary logon) | one-time setup | - |

No Windows password is needed anywhere. The `dba_perfcheck` password is handed to the Agent service account once (`-SaveCredentialFor`) and stored with Windows DPAPI so that only that account, on that machine, can decrypt it.

## Collector exit codes

`0` email sent (findings are in the email), `3` script error, `4` no email sent - the Agent job fails only on 3 and 4. Log per run in `Logs\`, reports in `Reports\` (both next to the script, kept 30 days), last job output in `CollectorJob_output.txt`.
