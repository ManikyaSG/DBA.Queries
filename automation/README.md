# Automation tools

| Folder | Tool | Version |
|---|---|---|
| [`pre-post-check`](pre-post-check/README.md) | One-click PRE / POST change check and HEALTH report for every instance on a VM (`Run-PrePostCheck.bat`). Also the AG failover / rolling reboot tool. | see [CHANGELOG](pre-post-check/CHANGELOG.md) |
| [`perf-check-reports`](perf-check-reports/README.md) | Daily health & performance check: a SQL Agent job on every instance, and one collector that emails one report per VM. | see [CHANGELOG](perf-check-reports/CHANGELOG.md) |
| [`health-check`](health-check/README.md) | Superseded by `pre-post-check` (HEALTH). Kept for reference. | - |
| [`common`](common) | Code shared by the tools, and the script that copies it into them. | - |
| [`tests`](tests) | Pester tests, run by hand (nothing runs automatically). | - |

## How the code is organised

**One shared core, single-file tools.** Helpers used by more than one tool live in [`common/DbaCommon.ps1`](common/DbaCommon.ps1):
- HTML style and tables
- `settings.psd1` loading
- sending through Database Mail with the return code checked
- reading the mail status
- splitting scripts on `GO`

Each tool still deploys as one `.ps1`, so the shared code is **copied** into each tool script between `#region DbaCommon` and `#endregion DbaCommon`. Change a shared helper in `DbaCommon.ps1`, never in a tool's copy, then run:

```powershell
.\automation\common\Sync-DbaCommon.ps1          # updates every tool's copy
.\automation\common\Sync-DbaCommon.ps1 -Check   # only reports: fails if a copy is out of date
```

**Settings outside the scripts.** Each tool has built-in defaults in its `$Config` block and reads an optional `settings.psd1` next to it (`settings.example.psd1` lists everything). The settings file is never in the repo, so copying a newer version of a script never overwrites a VM's recipients or thresholds. Don't change `$Config` in a copy on a VM.

**Checks as data (pre-post-check).** What is compared and how each section is shown is defined by `--@check` lines next to each query in `HC_Snapshot.sql`. See [Adding or changing a check](pre-post-check/README.md#adding-or-changing-a-check).

## Tests (run by hand)

There is no automatic testing or publishing: nothing runs on GitHub, and nothing is pushed to the VMs. Before pushing a change to `automation/`, run the tests on your own machine (Pester 5: `Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck`):

```powershell
Invoke-Pester .\automation\tests\Unit.Tests.ps1 -Output Detailed
```

[`tests/Unit.Tests.ps1`](tests/Unit.Tests.ps1) needs no SQL Server and changes nothing. It checks that:
- every script parses
- files are plain ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)
- the shared core is in sync in every tool
- every check definition matches its `SELECT`
- the PRE / POST comparison finds changed settings, new and missing rows, size drift, expected build changes and new problems
- the report sections and the settings files are right
- the version numbers match their CHANGELOG

[`tests/Integration.Tests.ps1`](tests/Integration.Tests.ps1) is optional and only for a **test instance** (never production). It runs `HC_Snapshot.sql` and checks a PRE / POST comparison catches a new database, a changed setting and a new login (all created and removed by the test). It also runs `database_mail_setup.sql` and queues a test mail through the shared Database Mail code. It doesn't touch `usp_DBA_HealthPerfCheck` and creates no Agent jobs.

```powershell
$env:SQLCI_SERVER = 'TESTVM\INST01'; $env:SQLCI_PASSWORD = '<sa password of the test instance>'
Invoke-Pester .\automation\tests\Integration.Tests.ps1 -Output Detailed
```

## Versions

Each tool has a version number:
- **pre-post-check:** `$ToolVersion` in `Invoke-PrePostCheck.ps1` **and** `--@version` in `HC_Snapshot.sql` (the two must match)
- **perf-check-reports:** `$ToolVersion` in `Collect-PerfCheckReports.ps1`

When you change a tool, raise its version and add a section at the top of its `CHANGELOG.md`:
- **patch** for fixes
- **minor** for new checks or options
- **major** when a VM has to do something when it gets the new version (for example 3.0.0 moved settings to `settings.psd1`)

The version is shown in every run's window, log, report and email footer, so you can see which VMs have an older copy. Copy new versions to the VMs the way you do today; `settings.psd1` stays as it is.
