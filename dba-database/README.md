# DBAdmin HC_ objects

The toolkit's diagnostic sections, installed as objects in the `DBAdmin` database so nobody has to open a script file:

```sql
EXEC DBAdmin.dbo.HC_help N'block';                              -- find a check by keyword
SELECT * FROM DBAdmin.dbo.HC_active_sessions ORDER BY elapsed_s DESC;
EXEC DBAdmin.dbo.HC_blocking_tree;
EXEC DBAdmin.dbo.HC_index_usage @database_name = N'Sales';      -- one database
EXEC DBAdmin.dbo.HC_index_usage @database_name = N'*';          -- every online user database
```

Full list: [HC_OBJECTS.md](HC_OBJECTS.md). `EXEC DBAdmin.dbo.HC_help;` with no keyword lists the main commands.

## Install

**One instance:** run `DBAdmin_HC_Deploy.sql` in SSMS.

**Many instances:** use `Deploy-HCObjects.ps1` (needs dbatools). It deploys to every instance and prints one line per instance with the build, OK / failed counts and, with `-SelfTest`, the self-test result:

```powershell
.\dba-database\Deploy-HCObjects.ps1 -ServerListFile .\servers.txt -SelfTest -OutCsv .\hc_deploy.csv
.\dba-database\Deploy-HCObjects.ps1 -SqlInstance SQLVM01, SQLVM02\INST2 -TrustServerCertificate
```

- **Box / Azure VM / Managed Instance:** creates `DBAdmin` if it is missing. Install on **every AG replica**; keep `DBAdmin` out of the AG, because DMVs are per instance.
- **Azure SQL Database:** connect to the user database and run it there (the `USE DBAdmin` line errors, and that is expected), or pass `-Database` to the PowerShell script.
- **Re-runnable any number of times:** nothing is created blindly. Every table, column, helper and `HC_` object is checked with `IF EXISTS` / `IF NOT EXISTS` first: a missing object gets an empty placeholder, which is then `ALTER`ed into the real one. That also works on 2016 builds before SP1, where `CREATE OR ALTER` doesn't exist. Each object deploys inside TRY/CATCH, so one failure never stops the rest, and a failed object doesn't leave a placeholder behind.
- **Cleans up after itself:** an object an earlier run installed but this build no longer contains is dropped at the end of the run, but only after a complete run, and only names recorded in `dbo.HC_objects`. The summary at the end, and `HC_catalog.status`, show `OK`, `OK (as procedure)`, `NOT APPLICABLE` (wrong platform), `NOT ON THIS VERSION` or `FAILED` with the error.
- **Which build is installed:** `SELECT * FROM DBAdmin.dbo.HC_version;` shows the build id, when and by whom it was deployed, the object counts and the last self-test. The build id is in the header of `DBAdmin_HC_Deploy.sql` and in `HC_OBJECTS.md`, so you can see which servers are behind. `dbo.HC_deploy_history` keeps the last 50 deploys.

## Which object type you get

| Toolkit section looks like | Becomes | Call it with |
|---|---|---|
| One SELECT, server-wide, nothing to change | view | `SELECT * FROM dbo.HC_x` |
| One SELECT with a `-- <== change` value | inline function | `SELECT * FROM dbo.HC_x(DEFAULT)` or pass a value |
| Several steps, temp tables, `WAITFOR`, `xp_readerrorlog` | procedure | `EXEC dbo.HC_x` (inputs become parameters) |
| Reads one database's catalog ("CURRENT DB", Query Store, indexes, users) | procedure | `EXEC dbo.HC_x @database_name = N'YourDB'` or `N'*'` |

Views can't keep `ORDER BY`, so the suggested sort is in `HC_catalog.how_to_run`. Views that keep `TOP (n)` still return the right rows, but in no guaranteed order. If SQL Server refuses a view (for example because of duplicate column names), the deploy creates a procedure with the same name instead.

Templates and anything that changes the server (KILL, ALTER, cache clears, enable/disable) are **not** converted. They stay in the scripts, where you review them before running. `HC_help` still finds them and says which script and section to open.

## Every database at once

Per-database checks accept `@database_name = N'*'`: every online user database this login can open (database snapshots and non-readable AG secondaries are skipped; on Azure SQL Database only the current one).

- When the check is a single query (68 of the 92), you get **one result set** with a `database_name` column first.
- Otherwise you get one result set per database, with `--- DatabaseName` printed on the Messages tab before each.
- An error in one database (offline mid-run, Query Store off, no permission) is printed and the check carries on with the next one.

`HC_catalog.all_databases_mode` shows which checks take `@database_name`.

## Safe on busy servers

Every procedure starts with:

```sql
SET LOCK_TIMEOUT 5000;                            -- give up after 5 s instead of queueing behind production
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;  -- no shared locks
SET DEADLOCK_PRIORITY LOW;                         -- if anything deadlocks, it is the check
```

These settings end with the procedure, so they don't leak into your session. Views and functions can't set them; run `SET LOCK_TIMEOUT 5000;` in your window first if you query them on a busy server.

## Self-test

```sql
EXEC DBAdmin.dbo.HC_selftest;                                         -- per-database checks run in DBAdmin
EXEC DBAdmin.dbo.HC_selftest @test_database = N'Sales', @include_heavy = 1;
SELECT * FROM DBAdmin.dbo.HC_selftest_last WHERE result <> 'PASS';
```

Runs every installed check once and logs `PASS` / `FAIL` (with the error) / `SKIPPED` and the duration. This catches what the deploy can't: SQL inside the per-database checks is only compiled when it runs.

- **Skipped by default:** checks that wait on purpose (the 30 s / 1 min sampling windows). Checks that read index pages are skipped unless you pass `@include_heavy = 1`. CDC checks are skipped unless CDC is enabled in the test database.
- **Viewing the output:** the checks return their normal result sets. In SSMS, tick *Query > Query Options > Results > Grid > Discard results after execution* first; progress and failures still appear on the Messages tab. `Deploy-HCObjects.ps1 -SelfTest` discards them for you.
- **History:** the last 10 runs are kept in `dbo.HC_selftest_results`.

## Snapshots (before / after a change)

```sql
EXEC DBAdmin.dbo.HC_snapshot N'change', @label = N'pre-patch-2026-11';      -- before patching
-- ... patch / change ...
EXEC DBAdmin.dbo.HC_snapshot N'change', @label = N'post-patch-2026-11';
EXEC DBAdmin.dbo.HC_snapshot_diff @before_label = N'pre-patch-2026-11', @after_label = N'post-patch-2026-11';
```

- **Taking a snapshot:** `HC_snapshot` saves a check's output as JSON in `dbo.HC_snapshots` under a label. Pass a set name (`N'change'` = version, settings, services, database options, logins, server roles, jobs, linked servers, AG layout, TDE, audit and more), one check, or a comma list (`N'HC_logins, HC_job_inventory'`). Per-database checks are saved for `@database_name` (default `N'*'`).
- **Comparing:** `HC_snapshot_diff` first lists every check as `same` / `changed` / `only in before` / `only in after`. Then, for each changed check, it shows the rows that differ (`before` row and `after` row next to each other). Compare two specific snapshots with `@before_id` / `@after_id`.
- **Browsing:** `SELECT * FROM dbo.HC_snapshot_list;`, and `EXEC dbo.HC_snapshot_show @snapshot_id = 12;` shows one snapshot as a table.
- **What can be saved:** checks built from plain queries (views, functions with their default inputs, most procedures, each result set separately). Checks that use variables, temp tables or DBCC can't (`HC_catalog.can_snapshot`).
- **Retention:** snapshots older than 90 days are removed (`@keep_days`).
- **Volatile columns:** columns like uptime or sizes always differ, so expect them in the diff.
- **Compatibility level:** showing and diffing snapshots needs DBAdmin at compatibility level 130 or higher (the deploy warns if it isn't).

## Permissions

The objects run with the caller's permissions:

- `VIEW SERVER STATE` (on 2022+: `VIEW SERVER PERFORMANCE STATE` and `VIEW SERVER SECURITY STATE`)
- read access to `msdb` and to the databases being checked
- `SELECT` / `EXECUTE` on DBAdmin. That's enough for the snapshot and self-test procedures too, because they write to their tables through ownership chaining. There is a grant example at the bottom of the deploy script.

## Changing a query

Edit the section in `scripts/NN_*.sql`, then rebuild and check:

```bash
python3 dba-database/build_hc_deploy.py scripts dba-database/DBAdmin_HC_Deploy.sql
python3 dba-database/check_deploy.py dba-database/DBAdmin_HC_Deploy.sql
```

- **Object names:** set in the `NAMES` map in `build_hc_deploy.py`.
- **Parameters:** any `DECLARE @x type = literal;` in a section becomes a parameter.
- **Snapshot sets:** set in `SNAPSHOT_SETS`.
- **Build checks:** the build stops if a section uses a variable or temp table it doesn't declare (sections written to run straight after an earlier one get their setup in `SETUP`).
- **Header and footer:** the registry, helpers, catalog, help, self-test and snapshot procedures live in `deploy_header.sql` and `deploy_footer.sql`.
