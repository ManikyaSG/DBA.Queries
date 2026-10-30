# One-click health check (all instances on a VM)

Runs [`scripts/44_health_check_report_email.sql`](../../scripts/44_health_check_report_email.sql) against **every SQL Server instance on the VM**. For each instance it emails the full HTML report through that instance's **Database Mail** profile and saves a timestamped copy locally, so you can compare reports from before and after a change.

## Files

| File | Purpose |
|---|---|
| `Run-HealthCheck.bat` | Double-click this. Starts the PowerShell script. |
| `Invoke-HealthCheck.ps1` | Asks for the label and ticket, asks for your Windows account and relaunches as you. Then it discovers the instances, runs script 44, emails the reports, saves copies and checks delivery. |
| `servers.txt.example` | Optional. Rename it to `servers.txt` to add instances on other VMs, such as AG replicas. |
| `44_health_check_report_email.sql` | Copy this here from `scripts/`. Inside the repo it is found automatically. |

## Set up once on each VM

1. Create a folder that **your own account can read and write**, for example `C:\DBA\HealthCheck`. Don't use the generic admin's Desktop or Documents, because the script runs as you.
2. Copy into it: `Run-HealthCheck.bat`, `Invoke-HealthCheck.ps1` and `scripts\44_health_check_report_email.sql`.
3. Edit the `$Config` block at the top of `Invoke-HealthCheck.ps1`:
   - `Recipients`: your DBA mailbox or distribution list, `;`-separated.
   - `MailProfile`: the preferred Database Mail profile name. If an instance doesn't have it, the script uses that instance's default profile, or its only profile.
4. Optional: thresholds such as log backup age and disk percentages are in the config block of the `.sql` file.

## Run it

1. RDP in with the generic admin account and double-click **`Run-HealthCheck.bat`**.
2. Enter a label (`PRE`, `POST` or `DAILY`) and the change ticket, which is optional.
3. At the credential prompt, enter **your** Windows account (`DOMAIN\you`), the same one you use for SSMS "Run as different user". Press **Cancel** to run as the current account instead.
4. A new window opens running as you. It shows progress for each instance, a summary, and whether each email was **sent**.

Each instance's email subject looks like `[WARNING] SQL Server Health Check [PRE CHG0012345] - SQLVM1 - 2026-10-30 01:30`.
The saved copies are named `Reports\SQLVM1_PRE_CHG0012345_20261030_0130.html` (one per instance), and the run log goes to `Logs\`.

**Before and after a change:** run once with `PRE`, make the change, then run again with `POST` and the same ticket. Compare the two emails, or the two HTML files side by side. For an automatic list of every difference, use the snapshot procedure in [script 43](../../scripts/43_pre_post_change_snapshot.sql).

## Command-line use (optional)

```powershell
.\Invoke-HealthCheck.ps1 -Label PRE -Ticket CHG0012345                 # still asks for credentials
.\Invoke-HealthCheck.ps1 -Label POST -Ticket CHG0012345 -UseCurrentUser
.\Invoke-HealthCheck.ps1 -Label DAILY -UseCurrentUser -Instances 'SQLVM1','SQLVM1\INST2'
```

## Permissions your account needs on each instance

- `VIEW SERVER STATE`, plus read access to `msdb` for backup and job history (sysadmin covers all of this).
- Membership of `DatabaseMailUserRole` in `msdb` to send mail (sysadmin covers it too).
- On the VM: permission to log on locally, which you already have if "Run as different user" works for SSMS.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Could not start as DOMAIN\you … directory name is invalid" | Your account can't read the folder. Move the files to `C:\DBA\HealthCheck`. |
| "The user name or password is incorrect" / "logon failure" | Wrong password, a locked account, or the account isn't allowed to log on to the VM. |
| `Login failed for user …` | That account has no SQL login on the instance. Use the account you use for SSMS. |
| "No Database Mail profile exists" | Configure Database Mail on that instance, or set `MailProfile`. |
| MailStatus = `unsent` | Still in the queue. Check later with `SELECT TOP 5 * FROM msdb.dbo.sysmail_allitems ORDER BY mailitem_id DESC`. |
| MailStatus = `failed` | The reason is shown in the summary. The full detail is in `msdb.dbo.sysmail_event_log`, usually an SMTP or relay problem. |
| Execution policy error despite `-ExecutionPolicy Bypass` | Group Policy enforces signing. Sign the script, or ask for an exception for `C:\DBA\HealthCheck`. If the files were downloaded, run `Unblock-File .\*.ps1` once. |
| Window closes immediately | Run `Run-HealthCheck.bat` from a `cmd` window to see the error. The log is in `Logs\`. |

## Cleanup

Double-click `Cleanup-OldFiles.bat` to delete files older than **48 hours** from `Reports\` and `Logs\`. Use `Cleanup-OldFiles.bat -Hours 72` for a different age, or `-WhatIf` to preview without deleting. To run it automatically, schedule it daily in Task Scheduler (action: the `.bat`, "Start in": this folder).
