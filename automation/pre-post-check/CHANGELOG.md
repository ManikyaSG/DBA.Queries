# Changelog: pre-post-check

Versions follow `MAJOR.MINOR.PATCH`. The version is in `Invoke-PrePostCheck.ps1` (`$ToolVersion`) and in `HC_Snapshot.sql` (`--@version`); the two must match, and CI checks that they do. Releases are tagged `pre-post-check/vX.Y.Z` on GitHub and contain a zip of this folder plus `Update-Tool.ps1`.

## 3.0.0 - 2026-11-26

**Upgrade note:** your settings now go in `settings.psd1` next to the script instead of the `$Config` block. Updating with `Update-Tool.ps1` writes it for you from the old script. If you copy the files by hand, copy `settings.example.psd1` to `settings.psd1` and put your values (recipients, extra instances, ...) in it.

- **Settings file:** optional `settings.psd1` overrides the built-in defaults and is never overwritten by an update. Unknown setting names are reported. `settings.example.psd1` lists every setting with its default. The window shows which settings file was used, and warns while `Recipients` is still the example address.
- **Checks defined as data:** each section's comparison rules and report title are `--@check` lines directly above its SELECT in `HC_Snapshot.sql` (they replace `$Spec` / `$ReportSections` in the script). Adding a check is now one SELECT plus its `--@check` lines. The run warns when a definition names a column the SELECT doesn't return, or when the SQL returns a section with no definition (it's then still shown at the end of the report).
- **Versions everywhere:** the window, log, report footer and email footer show the script version, the `HC_Snapshot.sql` version and the settings file. A mismatch between the script and the SQL file is reported. Snapshots record the version that took them, and the POST report shows the PRE and POST versions.
- **CLEANUP option removed:** every PRE / POST / HEALTH run already removes old files (`CleanupHours`). `-Phase CLEANUP` now stops with a message.
- **Shared core:** HTML, settings, Database Mail and batch-splitting helpers come from `automation/common/DbaCommon.ps1` (the same code as the perf check collector). `sp_send_dbmail`'s return code is now checked.
- The "Needs attention" table is no longer repeated in the PRE / HEALTH / NO BASELINE report file.

## 2.x - before 2026-11-26

Unversioned. Run-as window with RDP fail-safe, Database Mail auto-setup (`db_mail_setup.sql`), duplicate-email guard, attachment with body fallback.
