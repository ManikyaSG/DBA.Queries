# Community tools

Free, widely used tools that complement the DMV scripts in `/scripts`. **Their code is not copied into this repo.** They are updated frequently and each has its own licence, so install them from the official source with `Install-CommunityTools.ps1`.

| Tool | Author | What it's for | Official source | Licence |
|---|---|---|---|---|
| **sp_WhoIsActive** | Adam Machanic | Live activity: blocking leaders, plans, waits, deltas, logging to a table | [github.com/amachanic/sp_whoisactive](https://github.com/amachanic/sp_whoisactive) | GPL-3.0 |
| **First Responder Kit** | Brent Ozar Unlimited | `sp_Blitz` (health), `sp_BlitzFirst` (slow right now), `sp_BlitzCache` (worst queries), `sp_BlitzIndex` (index design), `sp_BlitzLock` (deadlocks), `sp_BlitzWho` | [github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit) | MIT |
| **Maintenance Solution** | Ola Hallengren | `DatabaseBackup`, `DatabaseIntegrityCheck`, `IndexOptimize` + `CommandLog`, AG-aware | [ola.hallengren.com](https://ola.hallengren.com) · [GitHub](https://github.com/olahallengren/sql-server-maintenance-solution) | MIT |
| **dbatools** | dbatools community | 700+ PowerShell commands: migrations, AG login/job sync, backups/restores, mass checks, patching | [dbatools.io](https://dbatools.io) · [docs](https://docs.dbatools.io) · [GitHub](https://github.com/dataplat/dbatools) | MIT |
| **Diagnostic Information Queries** | Glenn Berry | Version-specific deep health-check scripts (one per SQL version + Azure SQL DB + MI), refreshed monthly | Glenn Berry's website (resources page); downloaded automatically by dbatools `Save-DbaDiagnosticQueryScript` | Author's terms in script header |

Check each project's page for its current licence before redistributing anything.

## Files here

| File | Purpose |
|---|---|
| `Install-CommunityTools.ps1` | Installs/updates sp_WhoIsActive, First Responder Kit and Ola's solution into a DBA database (default `DBAdmin`) on one or many instances via dbatools, and downloads Glenn Berry's latest scripts to `./GlennBerry` (git-ignored). |
| `dbatools-cheatsheet.ps1` | dbatools commands grouped by the toolkit's scenarios: health, backups, Always On, migration, patching, refresh, security, schema export. |
| `../scripts/33_community_tools.sql` | Ready-to-run T-SQL calls for every proc above, Ola job/CommandLog checks, and how to log sp_WhoIsActive / sp_BlitzFirst to tables. |

## Quick start

```powershell
# One server, everything
.\community-tools\Install-CommunityTools.ps1 -SqlInstance SQLVM1

# All AG replicas, with Ola's Agent jobs and a backup share
.\community-tools\Install-CommunityTools.ps1 -SqlInstance SQLVM1,SQLVM2 -BackupDirectory '\\backup\sql' -CreateOlaJobs

# Only the troubleshooting procs
.\community-tools\Install-CommunityTools.ps1 -SqlInstance SQLVM1 -Tools WhoIsActive,FirstResponderKit
```

Re-run the same command any time to upgrade to the latest versions.

## Where they fit with the DMV scripts

| Situation | Community tool | Raw DMV equivalent in `/scripts` |
|---|---|---|
| What's running / blocking now | `sp_WhoIsActive @find_block_leaders = 1` | `02` 2.1, 2.3 |
| Server is slow right now | `sp_BlitzFirst @Seconds = 30, @ExpertMode = 1` | `01` 1.2, `07` 7.1 |
| Worst queries | `sp_BlitzCache @SortOrder = 'cpu'` | `03` 3.1, `04` 4.3 |
| Index review | `sp_BlitzIndex @DatabaseName = 'X'` | `05`, `24` |
| Deadlocks | `sp_BlitzLock` | `12` 12.5 / 12.6 |
| New server takeover / health | `sp_Blitz`, Glenn Berry queries | `00`, `15` |
| Backups / CHECKDB / index & stats jobs | Ola Hallengren | `10`, `15`, `19` |
| Migration, AG login/job sync, refresh, patching at scale | dbatools | `29`, `25` 25.8/25.9, `32`, `30` |
