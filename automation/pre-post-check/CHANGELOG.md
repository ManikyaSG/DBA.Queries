# Changelog: pre-post-check

Versions follow `MAJOR.MINOR.PATCH`. The version is in `Invoke-PrePostCheck.ps1` (`$ToolVersion`) and in `HC_Snapshot.sql` (`--@version`); the two must match (the run warns, and the unit tests fail, if they don't).

## 3.0.0 - 2026-11-26

**Upgrade note:** your settings now go in `settings.psd1` next to the script instead of the `$Config` block. Before replacing the script, copy `settings.example.psd1` to `settings.psd1` and put the values you changed in the old `$Config` block (recipients, mail profile, extra instances, ...) in it. Copy the new `Invoke-PrePostCheck.ps1` and `HC_Snapshot.sql` together.

- **Settings file:** optional `settings.psd1` overrides the built-in defaults and is not in the repo, so copying a newer version never overwrites it. Unknown setting names are reported. `settings.example.psd1` lists every setting with its default. The window shows which settings file was used, and warns while `Recipients` is still the example address.
- **Checks defined as data:** each section's comparison rules and report title are `--@check` lines directly above its SELECT in `HC_Snapshot.sql` (they replace `$Spec` / `$ReportSections` in the script). Adding a check is now one SELECT plus its `--@check` lines. The run warns when a definition names a column the SELECT doesn't return, or when the SQL returns a section with no definition (it's then still shown at the end of the report).
- **Versions everywhere:** the window, log, report footer and email footer show the script version, the `HC_Snapshot.sql` version and the settings file. A mismatch between the script and the SQL file is reported. Snapshots record the version that took them, and the POST report shows the PRE and POST versions.
- **CLEANUP option removed:** every PRE / POST / HEALTH run already removes old files (`CleanupHours`). `-Phase CLEANUP` now stops with a message.
- **Shared core:** HTML, settings, Database Mail and batch-splitting helpers come from `automation/common/DbaCommon.ps1` (the same code as the perf check collector). `sp_send_dbmail`'s return code is now checked.
- The "Needs attention" table is no longer repeated in the PRE / HEALTH / NO BASELINE report file.

## 2.x - before 2026-11-26

Unversioned. Run-as window with RDP fail-safe, Database Mail auto-setup (`db_mail_setup.sql`), duplicate-email guard, attachment with body fallback.
