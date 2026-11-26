# Changelog: perf-check-reports (collector)

Versions follow `MAJOR.MINOR.PATCH`. The version is `$ToolVersion` in `Collect-PerfCheckReports.ps1`.

## 1.1.0 - 2026-11-26

- **Settings file:** optional `settings.psd1` next to the script overrides the values in the script's `$Config` block and isn't in the repo, so copying a newer script keeps it (`settings.example.psd1` lists them). Without it, the script behaves exactly as before.
- **Version** shown in the log and in the email.
- **Shared core:** HTML style, Database Mail sending and other helpers come from `automation/common/DbaCommon.ps1`, the same code the pre-post check uses. Sending still checks `sp_send_dbmail`'s return code and still falls back to SMTP.

## 1.0.0

First version: reads the latest run of every instance from `DBAdmin.dbo.DBA_PerfCheck_Report`, one HTML file per VM, one email.
