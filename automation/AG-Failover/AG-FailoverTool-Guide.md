# AG Failover Tool – user guide

The AG Failover Tool moves SQL Server Always On availability groups (AGs) off a VM before maintenance (Windows patching, SQL CU patching, reboots) and puts them back afterwards. It can also patch-reboot a whole cluster one VM at a time, and rebalance AGs to their preferred primaries.

Every change is a **planned, no-data-loss failover**. The tool never forces a failover, and it checks the AG before every step. Each run leaves a detailed log and a plain-English summary you can share with leadership.

---

## 1. Before you start

### What you need

| Item | Detail |
|---|---|
| PowerShell | Windows PowerShell 5.1 or PowerShell 7. No extra modules (SqlServer, dbatools) are needed. |
| Account | The Windows account that holds your SQL permissions. Open PowerShell with **Run as different user** using that account, as you do for SSMS. |
| SQL permissions on every replica | `VIEW SERVER STATE` and `ALTER ANY AVAILABILITY GROUP`, or sysadmin. The tool checks these before it changes anything. |
| Network | The VM you run it from must reach every replica on the SQL port, and reach each AG listener. |
| Rolling reboot only (option 5) | Your account must be **local admin** on the VMs, so it can run `shutdown /m \\VM`. If it isn't, you can enter a Windows admin credential at the start (this needs WinRM enabled on the VMs). |

### Files

Keep these together in one folder, for example `D:\DBA\AGFailoverTool\`:

| File | Purpose |
|---|---|
| `AG-FailoverTool.ps1` | The launcher. **This is what you run.** |
| `AGFailoverTool.psm1` | All the logic. The settings are in `$Config` at the top of this file. |
| `Tests\AGFailoverTool.Tests.ps1` | Automated tests (optional, see section 10). |
| `VMs.txt` | *Optional.* The VM list and order for the rolling reboot. |
| `PreferredPrimaries.txt` | *Optional.* The preferred primary for each AG, used by option 6. |

The tool creates `Logs\`, `State\` and `Summary\` in the same folder the first time it runs.

If you copied the files from a download or an email attachment, unblock them once:

```powershell
Get-ChildItem D:\DBA\AGFailoverTool -Recurse | Unblock-File
```

### Start the tool

1. RDP to one of the cluster VMs.
2. Open PowerShell with **Run as different user**, using your SQL account.
3. Run:

```powershell
cd D:\DBA\AGFailoverTool
powershell.exe -ExecutionPolicy Bypass -File .\AG-FailoverTool.ps1
```

> **First time in an environment?** Choose **4** (dry run) first. Everything is checked and every command is printed, but nothing is changed.

---

## 2. The menu

| Option | Use it for |
|---|---|
| **1** Before activity | Drain one VM: record where every AG is, then move its AGs to other VMs. |
| **2** After activity | Put the AGs from an option 1 run back where they were. |
| **3** AG health check | Read-only report. Use it at any time, and always when something looks wrong. |
| **4** Dry run | Toggle on or off. While it's on, nothing is changed. The menu header shows **DRY RUN MODE**. |
| **5** Rolling reboot | Drain, reboot and return **every** VM in the cluster, one at a time. |
| **6** Rebalance | Move AGs to the primaries listed in `PreferredPrimaries.txt`. No state file is needed. |
| **0** Exit | |

---

## 3. Common scenarios

### A. Patch or reboot one VM

1. Run the tool and choose **1**.
2. Enter the VM name, for example `SQLVM01`. If the VM only has named instances, enter one of them, for example `SQLVM01\INST1`; the tool finds the others itself.
3. Read the **plan**: every AG, its current primary, the planned target, and anything skipped with the reason.
4. The **pre-flight** checks run. Fix anything listed, or choose *Override* only if you understand the risk.
5. Type `YES` (capitals) to start.
6. Check the result table. **Do not reboot** if any AG shows `FAILED`, `SKIPPED` or `UNKNOWN`, because it is still on the VM or in an unknown state.
7. Do your patching or reboot.
8. Run the tool again and choose **2**. Pick the activity from the list and type `YES`. The AGs go back, and automatic failover is switched back on.
9. Share the summary file from `Summary\` (section 7).

### B. Patch the whole cluster (rolling reboot)

1. Let Tanium (or your process) install the patches first. This option only does the **reboots**.
2. Run the tool **on one of the cluster VMs** and choose **5**.
3. The tool finds the cluster nodes (or reads `VMs.txt`), finds the SQL instances on them, and takes a **pre-snapshot** of every AG primary. It shows the reboot order. The VM you're on is always **last**.
4. The pre-flight checks run (section 5).
5. Enter the **maintenance window end time** (`HH:mm`, 24-hour), or leave it blank for no limit.
6. Type `YES`, then choose the reboot account: **U** for your account, or **C** to enter a Windows admin credential.
7. Before each VM you're asked:

   | Key | Meaning |
   |---|---|
   | C | Continue with this VM. |
   | S | Skip this VM; it isn't rebooted. |
   | R | Run this and all remaining VMs without asking. It stops asking automatically once the maintenance window has ended. |
   | A | Skip all remaining VMs and go straight to the final rebalance. |
   | Q | Quit now. Run option 5 later to resume. |

8. For each VM the tool:
   - checks the cluster
   - moves its AGs off
   - sets its replicas to MANUAL failover
   - runs `shutdown /r /t 0`
   - waits for SQL to restart and the replicas to re-sync
   - moves its AGs back and switches AUTOMATIC failover back on
9. When it reaches **your VM**, it drains it and stops with instructions. Reboot that VM yourself (`shutdown /r /t 0`), log back in, run the tool, choose **5**, then **R** (*Resume*).
10. The tool returns your VM's AGs, then rebalances **every** AG to the pre-snapshot layout and writes the final summary.

A run that stops for any reason (you quit, an error, a closed window, the VM you're on was rebooted) **resumes from where it stopped** with option 5. Progress is saved after every step.

### C. Put AGs back where they belong (no state file)

Use this after a manual failover, an unplanned failover, or when the state file is lost.

1. Choose **6**. The first time, `PreferredPrimaries.txt` doesn't exist: choose **G** and enter any instance in the cluster. The tool writes the file from the **current** layout.
2. Open the file and correct any lines, so each AG names the instance it should run on.
3. Choose **6** again. Check the plan, then type `YES`. AGs already on their preferred primary are left alone.

### D. Check the AGs

Choose **3** and enter any instance in the cluster. For each AG you get:
- replicas, roles, modes and connection state
- per-database sync state, suspension, queues and joined status
- the SQL build of each replica
- a **HEALTHY** or **ATTENTION** verdict, with the reasons

The report is saved in `Summary\`.

---

## 4. What the tool checks before each failover

A replica is used as the target only if **all** of these are true:

- It is a **synchronous-commit** secondary, **connected** and **healthy**.
- Every AG database on it is **joined**, **SYNCHRONIZED**, **not suspended** and **failover-ready**.
- Its SQL build is the **same or higher** than the current primary's. The tool never moves a primary to an older build.
- It is **not on the VM being drained**, which also rules out other instances on that VM.

If more than one replica qualifies, it prefers the automatic-failover partner, then the one with the smallest send and redo queue. If the only problem is that a replica is still catching up, it waits up to 3 minutes.

Then, for the chosen target:

- **Commit requirement.** If `REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT` needs more synchronous secondaries than will be left while the VM is down, the new primary would **stop accepting writes**. You're asked whether to continue or skip that AG.
- **Long transactions.** Transactions open longer than 5 minutes are listed with session, login, host and log size. A failover rolls them back, and the databases only come online on the new primary after the rollback. You can continue, re-check (for example after a job finishes), or skip the AG.
- **The failover.** It runs `ALTER AVAILABILITY GROUP … FAILOVER` on the target. If the command errors or times out, the tool **checks the replicas** to see what actually happened:
  - **COMPLETED:** the target is primary despite the error. Treated as success.
  - **NOT STARTED:** the old primary is confirmed still primary. The SQL error is reported.
  - **OUTCOME UNKNOWN:** the tool can't tell. **Stop.** Run option 3 or check Failover Cluster Manager until exactly one replica shows PRIMARY.
- **After the failover.** It waits for the synchronous secondaries to re-sync, then **connects through every AG listener** to confirm it reaches the new primary. It waits up to 90 seconds for DNS, the Azure load balancer probe or the DNN to catch up.

---

## 5. Pre-flight checks (before anything is changed)

| Check | Why |
|---|---|
| Every replica is reachable, and your account has `VIEW SERVER STATE` and `ALTER ANY AVAILABILITY GROUP` | So a permission or firewall problem doesn't show up halfway through, after some AGs have already moved. |
| No **other** AGFailoverTool session has been active on those replicas in the last 15 minutes | So two people don't fail over the same AGs at once. The message shows who it is (login, machine, process). |
| Every **other** cluster node and the quorum witness are UP, and quorum survives losing this VM (options 1 and 5) | So a reboot can't take the cluster down. |

All problems are listed together. **Cancel** leaves everything unchanged. **Override** continues anyway and is recorded in the log.

---

## 6. Prompts you may see

| Prompt | What to answer |
|---|---|
| `Type YES to continue` | `YES` in capitals to go ahead. Anything else cancels with no changes. |
| `[O]verride … / [C]ancel` (pre-flight) | Normally **C**. Fix the listed problem and run again. |
| `[C]ontinue with this failover anyway / [S]kip this AG` (write risk) | **S**, unless you've temporarily set `REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0`, or you accept writes stopping. |
| `[C]ontinue / [R]e-check / [S]kip` (long transactions) | **R** after the job finishes. **C** if the rollback time is acceptable. |
| `Resume data movement …? (Y/N)` | **Y** if you know why it was suspended and it's fixed. Otherwise **N**, and check option 3 first. |
| `[B]ring the moved AGs back and skip … / [Q]uit` (option 5, drain incomplete) | **B** to leave the VM unpatched but healthy. **Q** to stop and look. |
| `[R]esend / [W]ait longer / [B]ring back and skip / [Q]uit` (VM didn't go down) | **R** once. If it still doesn't go down, check the reboot permissions (section 9). |
| `[W]ait / [C]ontinue anyway / [Q]uit` (VM or re-sync slow) | **W** while Windows updates are still applying (check the Azure serial console or boot diagnostics). |
| `Unfinished rolling reboot found: [R]esume / [N]ew run / [C]ancel` | **R** to carry on. **N** abandons the old run. |

---

## 7. Output files

| Folder | File | Contents |
|---|---|---|
| `Summary\` | `AG_Failover_Summary_<VM>_<time>.txt` | **Leadership summary** for options 1 and 2. It shows the VM and instances, overall result, and each AG's original primary, new primary, result, time, listener check and whether automatic failover was available during the activity. The failback section is appended by option 2. |
| `Summary\` | `Rolling_Reboot_Summary_<cluster>_<time>.txt` | Option 5. It has: the layout before; progress per VM (drained, back online, minutes down); every move and return; the layout after (BALANCED or NOT_BALANCED); SQL builds before and after; issues. It's rewritten after every step, so it's always current. |
| `Summary\` | `AG_Rebalance_<time>.txt` | Option 6. |
| `Summary\` | `AG_HealthCheck_<instance>_<time>.txt` | Option 3. |
| `Logs\` | `AGFailoverTool_<time>.txt` | Every step and every T-SQL run. Errors are written with the details in section 9. |
| `State\` | `AGState_<VM>_<time>.json`, `Rolling_<cluster>_<time>.json` | What options 2 and 5 resume from. **Don't delete these while an activity is open.** A `.bak` copy is kept and used automatically if the main file is damaged. |

Files from a dry run end in `_DRYRUN`.

### Result codes

| Code | Meaning |
|---|---|
| `FAILED_OVER` / `FAILED_BACK` / `MOVED` / `RETURNED` | Done and verified. |
| `ALREADY_PRIMARY` | The AG was already where it should be. |
| `NOT_PRIMARY_HERE` | The VM is only a secondary for this AG, so no failover was needed. |
| `SKIPPED` | Not moved, for a stated reason: no eligible target, or you chose skip. |
| `BLOCKED` | Not moved because a check failed, for example a version mismatch or a replica not ready. |
| `FAILED` | The failover didn't happen. The log has the SQL error and the likely cause. |
| `UNKNOWN` | The tool couldn't confirm which replica is primary. **Check before doing anything else.** |
| `DRYRUN` | Dry run: what *would* have happened. |
| `NOT_SYNCED` | Option 5: the replica wasn't synchronized after the reboot. The final rebalance retries it. |
| `BALANCED` / `NOT_BALANCED` | Option 5 final layout compared with the pre-snapshot. |

---

## 8. Input files

**`VMs.txt`** (option 5, optional). One VM per line, in reboot order. Lines starting with `#` are ignored. Without this file, every node of the cluster is rebooted.

```text
# reboot order (comments go on their own line)
SQLVM02
SQLVM03
# a named instance on SQLVM02 that is in no AG with the others
SQLVM02\INST2
# the VM you run the tool on is always moved to last
SQLVM01
```

**`PreferredPrimaries.txt`** (option 6). One `AGName = Instance` per line. Option 6 can generate it for you.

```text
# Preferred primary for each AG
AG_Sales   = SQLVM01
AG_HR      = SQLVM02
AG_Finance = SQLVM02\INST2
```

---

## 9. Troubleshooting

When something fails, the log has an **ERROR DETAIL** block containing:
- the step, the AG and the server
- the exact T-SQL that ran
- the SQL error number, severity and state
- the full error chain and the script line
- a **Likely root cause / fix** line
- a snapshot of the AG at that moment

Start there.

| Symptom | Likely cause and fix |
|---|---|
| `Login failed (18456)` | PowerShell isn't running as your SQL account. Restart it with *Run as different user*. |
| Network error (53, 10060, 10061, 40) | Name resolution, firewall or NSG on the SQL port, or the SQL service is down. Test with `Test-NetConnection <server> -Port 1433`. |
| Error 41142 | The target isn't synchronized or not failover-ready. Run option 3 and resume or wait for sync. |
| Error 41131 | The cluster couldn't bring the AG online on the target. Usually `NT AUTHORITY\SYSTEM` lacks permissions on the target, or the cluster service is unhealthy. Check `Get-ClusterLog`. |
| Error 35250 | The secondary isn't connected. Check the mirroring endpoint (started, port open, `CONNECT` granted). |
| **OUTCOME UNKNOWN** | Don't retry or reboot. Check Failover Cluster Manager or option 3 until there's exactly one PRIMARY, then read the cluster log and the SQL error log on both servers. |
| `NOT JOINED` on a replica | A database was added on the primary but never joined on that replica. Seed or restore it `WITH NORECOVERY`, then run `ALTER DATABASE … SET HADR AVAILABILITY GROUP = …` on the replica. |
| `lower than the primary's` | The target hasn't been patched yet. Patch it first. |
| `STOP ACCEPTING WRITES` warning | Set `REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0` for the activity and set it back afterwards, or skip the AG. |
| `Listener check FAILED` | Applications using the listener can't reach the new primary. On Azure check the internal load balancer health probe and the cluster IP resource `ProbePort`, or the DNN resource, plus DNS for the listener name. |
| `another AGFailoverTool is active` | Someone else is working on those AGs. Agree with them before continuing. |
| `shutdown … exit code 5` (option 5) | Your account isn't local admin on that VM. Use **C** at the start to enter an admin credential. |
| `shutdown … exit code 53` (option 5) | The VM name didn't resolve, or the firewall blocks remote shutdown. Allow the *Remote Shutdown* / *WMI* rules from the VM you run the tool on. |
| An AG is still `MANUAL` failover after failback | The log shows the exact `ALTER AVAILABILITY GROUP … MODIFY REPLICA … FAILOVER_MODE = AUTOMATIC` to run on the primary. The replica must be synchronous, and at most 3 replicas can be AUTOMATIC. |

---

## 10. Settings and testing

### Settings

These are in `$Config` at the top of `AGFailoverTool.psm1`:

| Setting | Default | Meaning |
|---|---|---|
| `SyncWaitSec` | 180 | How long to wait for a target to become synchronized before giving up on it. |
| `FailoverTimeoutSec` | 600 | Timeout for the `FAILOVER` command. |
| `RoleVerifyWaitSec` | 60 | How long to wait to confirm the new role, and to work out the outcome after an error. |
| `PostFailoverSyncWaitSec` | 120 | How long to wait for the secondaries to re-sync after a failover. |
| `ListenerWaitSec` | 90 | How long to wait for each listener to reach the new primary. |
| `LongTranWarnMin` | 5 | Transactions open longer than this are listed before failover. |
| `ConcurrencyWindowMin` | 15 | Another operator's session active within this window blocks a run. |
| `SqlRetryCount` / `SqlRetryDelaySec` | 2 / 3 | Retries for brief connection errors on read-only queries. `FAILOVER` and `ALTER` are never retried. |
| `QueueWarnKB` | 102400 | Warn when a target has more than this queued (100 MB). |
| `RebootDownTimeoutSec` | 600 | Option 5: time for a VM to go down after the reboot command. |
| `RebootUpTimeoutSec` | 3600 | Option 5: time for SQL to come back. Patches can be slow. |
| `RebootSyncWaitSec` | 1800 | Option 5: time for the rebooted VM's replicas to re-sync. |
| `PreferredPrimariesFile` | `PreferredPrimaries.txt` | The file option 6 reads. |

### Testing

- **Dry run (option 4).** Runs every check and prints every command without changing anything. Use it on each new environment and after every update of the tool.
- **Automated tests.** These replay failure scenarios with mocked SQL calls, so no SQL Server is needed: a database not joined, an async-only AG, a timed-out failover that actually worked, a lower build, quorum loss, a damaged state file, and more.

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck   # once
cd D:\DBA\AGFailoverTool
Invoke-Pester .\Tests -Output Detailed
```

---

## 11. What the tool does not do

- **Forced (data-loss) failover** for real DR. Use your DR runbook.
- **AGs with only asynchronous secondaries.** These can't take a planned failover and are reported as skipped.
- **AGs with `CLUSTER_TYPE = NONE` or `EXTERNAL`, and distributed AGs.** These are reported and skipped. In option 5 you're warned that they'll be offline during the reboot.
- **Installing patches.** Option 5 only reboots, so the patches must already be installed.
- **Running without prompts** (for example from Tanium). This is planned.
