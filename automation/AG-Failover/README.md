# AG failover tool

A separate, menu-driven tool for moving Always On AGs off a VM before maintenance and back afterwards, rebooting a whole cluster one VM at a time, and rebalancing AGs to their preferred primaries. Every change is a planned, no-data-loss failover with safety checks before and after. **Full instructions: [AG-FailoverTool-Guide.md](AG-FailoverTool-Guide.md).**

More documents in [`docs/`](docs/):

- [Leadership overview](docs/Leadership-Overview.md): what the tool does and why, the safety checks, benefits and the rollout plan.
- [SOP and technical guide](docs/SOP-Technical-Guide.md): the team's standard procedure, KT and how-to, with prompts, troubleshooting and a code map.

| File | Purpose |
|---|---|
| `AG-FailoverTool.ps1` | Launcher. Run this: `powershell.exe -ExecutionPolicy Bypass -File .\AG-FailoverTool.ps1` |
| `AGFailoverTool.psm1` | All the logic. Settings are in `$Config` at the top. |
| `Tests\AGFailoverTool.Tests.ps1` | Pester 5 tests with mocked SQL calls (`Invoke-Pester .\Tests`). |
| `VMs.txt`, `PreferredPrimaries.txt` | Optional inputs for option 5 (reboot order) and option 6 (preferred primaries). |

| Option | What it does |
|---|---|
| 1 | Drain a VM: record the primaries and fail its AGs over to the best synchronous secondary on another VM. |
| 2 | Fail the AGs from an option 1 run back to their original primaries. |
| 3 | Read-only AG health check. |
| 4 | Dry run on/off. |
| 5 | Rolling reboot of every VM in the cluster, with skip, resume and a final rebalance. |
| 6 | Rebalance AGs to `PreferredPrimaries.txt`. No state file needed. |
