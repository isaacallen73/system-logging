# SystemLogging

Small PowerShell tools for catching Windows bloat and memory leaks as they build up.
Windows PowerShell 5.1, no installs needed. Measurements go in `data\<COMPUTERNAME>\`,
which is gitignored, so one clone can serve several machines.

## Baseline: what's on the machine

A point-in-time inventory: hardware and Windows build, idle CPU and memory, processes,
services, scheduled tasks, startup items, installed programs, Store apps, kernel and device
drivers, listening ports, PATH, updates, disk usage and folder sizes on C:.

```powershell
.\baseline\baseline.ps1                    # full run; the folder-size scan is the slow part
.\baseline\baseline.ps1 -SkipFolderSizes   # quick run (about a minute)
.\baseline\compare.ps1                     # first run vs latest run on this machine
.\baseline\compare.ps1 -Old <run> -New <run>
```

Each run writes `data\<COMPUTERNAME>\baseline\<yyyy-MM-dd_HHmm>\*.csv`. The compare lists what
was added, removed or changed, and which folders grew, and saves the report into the newer run.
Run it as admin to also capture optional Windows features, SSD wear/temperature/error counters,
boot durations (read from Windows' own boot log, no reboot needed), and folders a normal user can't read.

**On a new machine:** take a baseline before installing anything, then again after the
manufacturer's setup, then whenever the machine feels heavier. Also save an Autoruns snapshot
(Sysinternals, File > Save) on day one; its File > Compare is the best view of new auto-start entries.

## MemLog: memory over time

Logs a memory sample every 30 minutes and at logon:

```powershell
.\memlog\install-memlog.ps1     # register the scheduled task (current user, hidden)
Unregister-ScheduledTask MemLogger -Confirm:$false   # remove it
```

Output in `data\<COMPUTERNAME>\memlog\`:

| File | What |
|---|---|
| `system.csv` | commit, available RAM, kernel pools, shared commit, unaccounted commit |
| `processes.csv` | top 15 apps by private memory |
| `pooltags.csv` | top kernel pool tags (driver allocations) |
| `jumps.log` | only when shared commit grows 1 GB+ between samples: which processes exited and started |
| `errors.log` | anything that failed |

**Reading it:** commit near the commit limit is what makes Windows complain about low memory.
`UnaccountedGB` = commit - process memory - kernel pools: memory no process owns. If that climbs
while apps stay flat, look at `SharedCommitGB` and `jumps.log`. Shared commit comes from an
undocumented Windows structure; the script checks its offsets against the performance counter
each run and logs to `errors.log` instead of writing wrong numbers.
