# Automation tools

| Folder | Tool | Version |
|---|---|---|
| [`pre-post-check`](pre-post-check/README.md) | One-click PRE / POST change check and HEALTH report for every instance on a VM (`Run-PrePostCheck.bat`). Also the AG failover / rolling reboot tool. | see [CHANGELOG](pre-post-check/CHANGELOG.md) |
| [`perf-check-reports`](perf-check-reports/README.md) | Daily health & performance check: a SQL Agent job on every instance, and one collector that emails one report per VM. | see [CHANGELOG](perf-check-reports/CHANGELOG.md) |
| [`health-check`](health-check/README.md) | Superseded by `pre-post-check` (HEALTH). Kept for reference. | - |
| [`common`](common) | Code shared by the tools, the sync script and the updater. | - |
| [`tests`](tests) | Pester tests, run by CI. | - |

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
.\automation\common\Sync-DbaCommon.ps1 -Check   # what CI runs: fails if a copy is out of date
```

**Settings outside the scripts.** Each tool has built-in defaults in its `$Config` block and reads an optional `settings.psd1` next to it (`settings.example.psd1` lists everything). The settings file is never in the repo or a release zip, so an update never overwrites a VM's recipients or thresholds. Don't change `$Config` in a copy on a VM.

**Checks as data (pre-post-check).** What is compared and how each section is shown is defined by `--@check` lines next to each query in `HC_Snapshot.sql`. See [Adding or changing a check](pre-post-check/README.md#adding-or-changing-a-check).

## Tests and CI

[`.github/workflows/automation-ci.yml`](../.github/workflows/automation-ci.yml) runs on every push and pull request that touches `automation/`:

| Job | What it checks |
|---|---|
| Unit tests, **Windows PowerShell 5.1** and **PowerShell 7** | [`tests/Unit.Tests.ps1`](tests/Unit.Tests.ps1). Every script parses. Files are plain ASCII (5.1 reads BOM-less files as ANSI). The shared core is in sync. Check definitions match their `SELECT`s. The PRE / POST comparison finds changed settings, new and missing rows, size drift, expected build changes and new problems. Report sections, settings files and the 3.0 settings migration are covered. Versions match their CHANGELOG. |
| PSScriptAnalyzer | Errors fail the build; warnings are listed. |
| SQL Server **2017 / 2019 / 2022 / 2025** (Linux containers) | [`tests/Integration.Tests.ps1`](tests/Integration.Tests.ps1): `HC_Snapshot.sql` runs and returns every column its definitions name; two snapshots in a row show no differences; a new database, a changed `sp_configure` value and a new login are found; `database_mail_setup.sql` runs batch by batch; the shared Database Mail helpers send and read back a mail item; `HealthPerfCheck_AgentJob.sql` PART 1 + 2 install, re-install, and the check saves a finished report. |

The containers are Linux, so Windows-only pieces (services, registry, SSIS / SSRS / SSAS, run-as, DPAPI, the email actually reaching a mailbox) are not covered; those still need a test run on a Windows VM before a release.

Run the tests yourself (Pester 5: `Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck`):

```powershell
Invoke-Pester .\automation\tests\Unit.Tests.ps1 -Output Detailed
$env:SQLCI_SERVER = 'localhost,1433'; $env:SQLCI_PASSWORD = '<sa password of a test instance>'
Invoke-Pester .\automation\tests\Integration.Tests.ps1 -Output Detailed     # creates and drops test objects - never on production
```

## Releasing a version

1. Raise the version in the tool:
   - pre-post-check: `$ToolVersion` in `Invoke-PrePostCheck.ps1` **and** `--@version` in `HC_Snapshot.sql`
   - perf-check-reports: `$ToolVersion` in `Collect-PerfCheckReports.ps1`
2. Add a section at the top of the tool's `CHANGELOG.md`.
3. Push to `main` and wait for CI to be green.
4. Tag and push: `git tag pre-post-check/v3.0.1 && git push origin pre-post-check/v3.0.1`.

[`.github/workflows/automation-release.yml`](../.github/workflows/automation-release.yml) then checks that the tag matches the script's version and publishes a GitHub release. The release has a zip of the tool's folder (no `settings.psd1`, no credential files, Windows line endings) plus `Update-Tool.ps1`, and its notes are that version's CHANGELOG section.

On a VM, `.\Update-Tool.ps1` in the tool's folder installs the newest release (or `-Version x.y.z`, or `-ZipFile` for an offline copy). It keeps settings, snapshots, reports, logs and credential files, and backs up the files it replaces to `_previous\`. Because the version is in every report and email footer, you can see which VMs are behind.

Versions: **patch** for fixes, **minor** for new checks or options, **major** when a VM has to do something on update (for example 3.0.0 moved settings to `settings.psd1`).
