# Third-party SQL Server toolkits

These are copies of the community toolkits, kept in this repo so they're available offline on servers that can't reach GitHub. The files are **unmodified** and each folder keeps its author's **license file**. To pull the latest versions, run `Update-ThirdParty.ps1`.

| Folder | Author | What it is | License | Source | Version in repo |
|---|---|---|---|---|---|
| `brent-ozar-first-responder-kit` | Brent Ozar Unlimited | `sp_Blitz`, `sp_BlitzFirst`, `sp_BlitzCache`, `sp_BlitzIndex`, `sp_BlitzLock`, `sp_BlitzWho`, `sp_BlitzBackups`, `sp_BlitzAnalysis`, `sp_DatabaseRestore`, `sp_ineachdb`, `sp_kill` + documentation | MIT | [GitHub](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit) | `b32a4e7` (2026-10-30) |
| `adam-machanic-sp_whoisactive` | Adam Machanic | `sp_WhoIsActive`: live activity monitor | **GPL-3.0** | [GitHub](https://github.com/amachanic/sp_whoisactive) | `40ac17b` (2026-04-09) |
| `vlad-drumea-psblitz` | Vlad Drumea | **PSBlitz**: PowerShell tool that runs the First Responder Kit plus its own checks and exports the results to **Excel / HTML** reports (screenshots folder omitted) | MIT | [GitHub](https://github.com/VladDBA/PSBlitz) | `6b98f90` (2026-10-08) |
| `vlad-drumea-sql-server-scripts` | Vlad Drumea | DBA scripts: table sizes, stats info, object dependencies, move DB files, test write speeds, kill SPIDs, quick password audit, and more, plus PowerShell (static port, SQL install, SSMS connections import) | MIT | [GitHub](https://github.com/VladDBA/SQL-Server-Scripts) | `da8088d` (2026-04-15) |
| `ola-hallengren-maintenance-solution` | Ola Hallengren | **Maintenance Solution**: `DatabaseBackup`, `DatabaseIntegrityCheck`, `IndexOptimize`, `CommandExecute`, `CommandLog`, Agent jobs; AG-aware; Azure SQL DB version included + docs | MIT | [GitHub](https://github.com/olahallengren/sql-server-maintenance-solution) · [ola.hallengren.com](https://ola.hallengren.com) | `4161757` (2026-09-12) |

## Install / use

**First Responder Kit + sp_WhoIsActive into a DBA database** (no internet needed):
```sql
USE DBAdmin;   -- or master
-- open and run:  scripts\third-party\brent-ozar-first-responder-kit\Install-All-Scripts.sql
--                (Azure SQL Database: Install-Azure.sql)
-- open and run:  scripts\third-party\adam-machanic-sp_whoisactive\sp_WhoIsActive.sql
```
How to use each one: [`scripts/33_community_tools.sql`](../33_community_tools.sql). The FRK documentation is in `brent-ozar-first-responder-kit/Documentation/`.

**Ola Hallengren Maintenance Solution** (no internet needed):
```sql
-- 1. Open scripts\third-party\ola-hallengren-maintenance-solution\MaintenanceSolution.sql
-- 2. Edit the settings at the top before running:
--      USE [DBAdmin]  (or master)       -> database the procedures and CommandLog table go into
--      @CreateJobs          = 'Y'       -> creates the Agent jobs (no schedules - add your own)
--      @BackupDirectory     = N'\\backupshare\SQL'  (or a URL for backup to Azure blob)
--      @CleanupTime         = 168       -> hours to keep backup files (NULL = never delete)
--      @OutputFileDirectory = NULL      -> job output files (NULL = SQL error log folder)
--      @LogToTable          = 'Y'       -> log every command to dbo.CommandLog
-- 3. Run it. Re-running later upgrades the procedures in place.
-- Azure SQL Database: run MaintenanceSolutionAzureSQLDatabase.sql in the user database (no Agent jobs).
```
Usage examples and CommandLog queries are in [`scripts/33_community_tools.sql`](../33_community_tools.sql) (33.9–33.12). Full parameter reference: the `docs` folder or [ola.hallengren.com](https://ola.hallengren.com).

**PSBlitz** (run from a machine with SSMS or the SqlServer module; produces an Excel or HTML health report per instance):
```powershell
cd scripts\third-party\vlad-drumea-psblitz
.\PSBlitz.ps1 SQLVM1                    # Windows auth; Excel report (needs Excel installed)
.\PSBlitz.ps1 SQLVM1\INST2 -ToHTML      # HTML report, no Excel needed
.\PSBlitz.ps1 SQLVM1 -InDepth -ToHTML   # deeper checks
.\PSBlitz.ps1 -GUI                      # point-and-click
```
Run `Get-Help .\PSBlitz.ps1 -Full` for all options, and see `PERMISSIONS.md` for the rights it needs.

**Vlad's scripts:** open the `.sql` file you need from `vlad-drumea-sql-server-scripts\Scripts\`. Each script documents itself at the top.

## Update to the latest versions

```powershell
.\scripts\third-party\Update-ThirdParty.ps1          # downloads the latest main branch of all five and replaces the folders
```
Commit the result afterwards.

## License notes

- **MIT** (First Responder Kit, Ola Hallengren, PSBlitz, Vlad's scripts): free to use, copy and redistribute, as long as the license file stays with the code.
- **GPL-3.0** (sp_WhoIsActive): free to use and redistribute unmodified with its license, as here. If you **modify** it and give it to others, your changes must also be GPL-3.0. Using it internally on your servers carries no obligations.
- Credit for these tools belongs to their authors. This repo only mirrors them.
