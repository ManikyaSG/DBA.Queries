# DBAdmin HC_ objects

The toolkit's diagnostic sections, installed as objects in the `DBAdmin` database so nobody has to open a script file:

```sql
SELECT * FROM DBAdmin.dbo.HC_catalog;                         -- everything installed here + how to call it
SELECT * FROM DBAdmin.dbo.HC_active_sessions ORDER BY elapsed_s DESC;
EXEC DBAdmin.dbo.HC_blocking_tree;
EXEC DBAdmin.dbo.HC_index_usage @database_name = N'Sales';
```

Full list: [HC_OBJECTS.md](HC_OBJECTS.md).

## Install

Run `DBAdmin_HC_Deploy.sql` in SSMS on each instance (or push it everywhere with dbatools):

```powershell
Get-Content .\servers.txt | ForEach-Object {
    Invoke-DbaQuery -SqlInstance $_ -File .\dba-database\DBAdmin_HC_Deploy.sql -MessagesToOutput
}
```

- **Box / Azure VM / Managed Instance:** creates `DBAdmin` if it is missing. Install on **every AG replica**; keep `DBAdmin` out of the AG, because DMVs are per instance.
- **Azure SQL Database:** connect to the user database and run it there. The `USE DBAdmin` line errors, and that is expected.
- **Re-runnable:** each object is `CREATE OR ALTER` inside TRY/CATCH, so one failure never stops the rest. The summary at the end, and `HC_catalog.status`, show `OK`, `OK (as procedure)`, `NOT APPLICABLE` (wrong platform), `NOT ON THIS VERSION` or `FAILED` with the error.

## Which object type you get

| Toolkit section looks like | Becomes | Call it with |
|---|---|---|
| One SELECT, server-wide, nothing to change | view | `SELECT * FROM dbo.HC_x` |
| One SELECT with a `-- <== change` value | inline function | `SELECT * FROM dbo.HC_x(DEFAULT)` or pass a value |
| Several steps, temp tables, `WAITFOR`, `xp_readerrorlog` | procedure | `EXEC dbo.HC_x` (inputs become parameters) |
| Reads one database's catalog ("CURRENT DB", Query Store, indexes, users) | procedure | `EXEC dbo.HC_x @database_name = N'YourDB'` |

Views can't keep `ORDER BY`, so the suggested sort is in `HC_catalog.how_to_run`. Views that keep `TOP (n)` still return the right rows, but in no guaranteed order. If SQL Server refuses a view (for example because of duplicate column names), the deploy creates a procedure with the same name instead.

Templates and anything that changes the server (KILL, ALTER, cache clears, enable/disable) are **not** converted. They stay in the scripts, where you review them before running.

## Permissions

The objects run with the caller's permissions:

- `VIEW SERVER STATE` (on 2022+: `VIEW SERVER PERFORMANCE STATE` and `VIEW SERVER SECURITY STATE`)
- read access to `msdb` and to the databases being checked
- `SELECT` / `EXECUTE` on DBAdmin (there is a grant example at the bottom of the deploy script)

## Changing a query

Edit the section in `scripts/NN_*.sql`, then rebuild and check:

```bash
python3 dba-database/build_hc_deploy.py scripts dba-database/DBAdmin_HC_Deploy.sql
python3 dba-database/check_deploy.py dba-database/DBAdmin_HC_Deploy.sql
```

- **Object names:** set in the `NAMES` map in `build_hc_deploy.py`.
- **Parameters:** any `DECLARE @x type = literal;` in a section becomes a parameter.
- **Header and footer:** the registry, deploy helper and `HC_catalog` live in `deploy_header.sql` and `deploy_footer.sql`.
