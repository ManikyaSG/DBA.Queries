# Perf check reports

Everything for the SQL Server **health & performance check reports** lives in this folder and nowhere else in the repo.

| Folder / file | What it is | Use it when |
|---|---|---|
| [`powershell/`](powershell/README.md) | `Invoke-PerfCheck.ps1` + `PerfCheck.sql`. Health check + performance window for many instances. **One report file per VM, one email**. `-PrimaryOnly` checks only instances that are primary for an AG (or standalone). Run by double-click (`Run-PerfCheck.bat`), Task Scheduler, or a **SQL Agent job** (`Run-PerfCheck-Agent.bat` + `CreateAgentJob_PerfCheck.sql`). | PowerShell is allowed. Several VMs / instances in one email. |
| [`tsql/`](tsql/README.md) | `HealthPerfCheck_AgentJob.sql`. The same check in **pure T-SQL**: a stored procedure plus a SQL Agent job on each instance, report emailed through Database Mail. | PowerShell is not allowed on the server. One report per instance. |
| [`SETUP.txt`](SETUP.txt) | Step-by-step setup for several VMs, primary instances only, one email, one SQL Agent job: SQL login, Agent service account, Database Mail, config, test, password hand-over and job. | Setting it up on a new set of servers. |
| [`database_mail_setup.sql`](database_mail_setup.sql) | Database Mail setup / repair, safe to re-run (account, profile, public/default, `MaxFileSize`, test email). Both versions send their email through Database Mail. | Before the first run, or when the email doesn't go out. |

## Several VMs, primary instances only, one email

Example: 3 VMs with 3 instances each, in Always On AGs.

1. Copy `powershell/` to the server that runs the job, e.g. `C:\DBA\PerfCheck`.
2. `servers.example.txt` → `servers.txt`: list all 9 instances (instance names, not listeners). In `$Config`: `IncludeLocalInstances = $false`, `Recipients`.
3. Run `CreateAgentJob_PerfCheck.sql` on that instance (`@Arguments = N'-PrimaryOnly -Label SCHEDULED'`, no proxy, schedule), after handing the SQL login password to the Agent service account with `Run-PerfCheck.bat -SaveCredentialFor`.
4. Result: one email, with one `.html` report per VM attached; secondary-only instances are listed as skipped.

Details, accounts and how the email is sent: [powershell/README.md](powershell/README.md#several-vms-primary-only-one-email-sql-agent-job).
