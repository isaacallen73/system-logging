# Memory snapshot logger. Appends one sample per run to CSVs in data\<COMPUTERNAME>\memlog\:
#   system.csv     - commit, available RAM, kernel pools, uptime, shared commit, unaccounted commit
#   processes.csv  - top apps (processes grouped by name) by private memory
#   pooltags.csv   - top kernel pool tags (driver allocations) by size
#   jumps.log      - written only when shared commit grows >= 1 GB between samples:
#                    processes that exited/started since the previous sample, plus top handle holders
#   last_procs.csv - full process list from the latest sample (used to diff on a jump)
#   errors.log     - anything that went wrong
# "Unaccounted" = commit - process private - kernel pools. If it grows, the memory is held by
# something no process owns (shared sections, drivers); SharedCommitGB says how much is shared.
param([string]$DataRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data'))
$ErrorActionPreference = 'Stop'
$dir = Join-Path (Join-Path $DataRoot $env:COMPUTERNAME) 'memlog'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$ts  = (Get-Date).ToString('yyyy-MM-dd HH:mm')

try {
    if (-not ('MemLogNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public class MemLogNative {
  [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int c, IntPtr b, int l, out int r);

  // SYSTEM_PERFORMANCE_INFORMATION (class 2), x64. Returns { CommittedPages (offset 48),
  // SharedCommittedPages (offset 336) }, or null if the call fails or the struct is too short.
  public static long[] PerfInfo() {
    int len = 1024, r; IntPtr buf = Marshal.AllocHGlobal(len);
    for (int i = 0; i < len; i++) Marshal.WriteByte(buf, i, 0);
    int st = NtQuerySystemInformation(2, buf, len, out r);
    long[] v = (st == 0 && r >= 344)
      ? new long[] { (uint)Marshal.ReadInt32(buf, 48), Marshal.ReadInt64(buf, 336) } : null;
    Marshal.FreeHGlobal(buf); return v;
  }

  // SYSTEM_POOLTAG_INFORMATION (class 22), x64: { tag, paged bytes, nonpaged bytes } per tag.
  public static List<string[]> PoolTags() {
    int len = 0x100000, r; IntPtr buf = Marshal.AllocHGlobal(len);
    int st = NtQuerySystemInformation(22, buf, len, out r);
    if (st != 0) { Marshal.FreeHGlobal(buf); len = r + 0x10000; buf = Marshal.AllocHGlobal(len); st = NtQuerySystemInformation(22, buf, len, out r); }
    var res = new List<string[]>();
    if (st != 0) { Marshal.FreeHGlobal(buf); return res; }
    int count = Marshal.ReadInt32(buf); IntPtr p = buf + 8;
    for (int i = 0; i < count; i++) {
      byte[] t = new byte[4]; Marshal.Copy(p, t, 0, 4);
      res.Add(new string[] { System.Text.Encoding.ASCII.GetString(t),
        ((long)Marshal.ReadIntPtr(p, 16)).ToString(), ((long)Marshal.ReadIntPtr(p, 32)).ToString() });
      p += 40;
    }
    Marshal.FreeHGlobal(buf); return res;
  }
}
'@
    }
    $os    = Get-CimInstance Win32_OperatingSystem
    $perf  = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $procs = Get-Process

    # Shared commit, with a self-check: the struct's CommittedPages must match the perf counter,
    # otherwise the offsets are wrong on this Windows build and we log nothing rather than garbage.
    $sharedGB = $null
    $pi = [MemLogNative]::PerfInfo()
    if ($pi) {
        $commitFromStruct = $pi[0] * 4KB
        if ([math]::Abs($commitFromStruct - $perf.CommittedBytes) -le 0.05 * $perf.CommittedBytes) {
            $sharedGB = [math]::Round($pi[1] * 4KB / 1GB, 2)
        } else {
            "$ts  SharedCommit skipped: struct commit $([math]::Round($commitFromStruct/1GB,2)) GB != counter $([math]::Round($perf.CommittedBytes/1GB,2)) GB (offsets differ on this build)" |
                Add-Content -Path (Join-Path $dir 'errors.log')
        }
    }
    $procPrivGB = [math]::Round(($procs | Measure-Object PrivateMemorySize64 -Sum).Sum / 1GB, 2)
    $unaccGB = [math]::Round($perf.CommittedBytes / 1GB - $procPrivGB - ($perf.PoolNonpagedBytes + $perf.PoolPagedBytes) / 1GB, 2)

    # Jump detection: compare with the previous sample, and keep a full process list for diffing.
    $sysCsv  = Join-Path $dir 'system.csv'
    $lastCsv = Join-Path $dir 'last_procs.csv'
    $prev = if (Test-Path $sysCsv) { Import-Csv $sysCsv | Select-Object -Last 1 } else { $null }
    $nowProcs = $procs | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.ProcessName
        PrivateMB = [math]::Round($_.PrivateMemorySize64 / 1MB); Handles = $_.HandleCount
        Started = $(try { $_.StartTime.ToString('yyyy-MM-dd HH:mm') } catch { '' }) } }
    if ($prev -and $prev.SharedCommitGB -and $sharedGB -ne $null -and
        ($sharedGB - [double]$prev.SharedCommitGB) -ge 1) {
        $old = if (Test-Path $lastCsv) { @(Import-Csv $lastCsv) } else { @() }
        $oldIds = @{}; $old | ForEach-Object { $oldIds[$_.Id] = $_ }
        $newIds = @{}; $nowProcs | ForEach-Object { $newIds[[string]$_.Id] = $_ }
        @(
            "==== $ts  shared commit $($prev.SharedCommitGB) -> $sharedGB GB (prev sample $($prev.Time))"
            "Exited since previous sample:"
            ($old | Where-Object { -not $newIds.ContainsKey($_.Id) } | Sort-Object { [double]$_.PrivateMB } -Descending |
                Format-Table Name, Id, PrivateMB, Handles, Started -AutoSize | Out-String).TrimEnd()
            "Started since previous sample:"
            ($nowProcs | Where-Object { -not $oldIds.ContainsKey([string]$_.Id) } | Sort-Object PrivateMB -Descending |
                Format-Table Name, Id, PrivateMB, Handles, Started -AutoSize | Out-String).TrimEnd()
            "Top 40 processes now, by handles:"
            ($nowProcs | Sort-Object Handles -Descending | Select-Object -First 40 |
                Format-Table Name, Id, PrivateMB, Handles, Started -AutoSize | Out-String).TrimEnd()
            ""
        ) | Add-Content -Path (Join-Path $dir 'jumps.log')
    }
    $nowProcs | Export-Csv -Path $lastCsv -NoTypeInformation

    [pscustomobject]@{
        Time           = $ts
        UptimeHours    = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
        CommitGB       = [math]::Round($perf.CommittedBytes / 1GB, 2)
        CommitLimitGB  = [math]::Round($perf.CommitLimit / 1GB, 2)
        AvailableGB    = [math]::Round($perf.AvailableBytes / 1GB, 2)
        NonPagedMB     = [math]::Round($perf.PoolNonpagedBytes / 1MB)
        PagedMB        = [math]::Round($perf.PoolPagedBytes / 1MB)
        ProcPrivateGB  = $procPrivGB
        ProcessCount   = $procs.Count
        TotalHandles   = ($procs | Measure-Object HandleCount -Sum).Sum
        SharedCommitGB = $sharedGB
        UnaccountedGB  = $unaccGB
    } | Export-Csv -Path $sysCsv -Append -NoTypeInformation

    $procs | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{
            Time      = $ts
            Name      = $_.Name
            Count     = $_.Count
            PrivateMB = [math]::Round(($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB)
            Handles   = ($_.Group | Measure-Object HandleCount -Sum).Sum
        }
    } | Sort-Object PrivateMB -Descending | Select-Object -First 15 |
        Export-Csv -Path (Join-Path $dir 'processes.csv') -Append -NoTypeInformation

    $tags = [MemLogNative]::PoolTags() | ForEach-Object {
        [pscustomobject]@{ Time = $ts; Tag = $_[0].Trim([char]0)
            PagedMB = [math]::Round([long]$_[1] / 1MB, 1); NonPagedMB = [math]::Round([long]$_[2] / 1MB, 1) }
    }
    @(
        $tags | Sort-Object NonPagedMB -Descending | Select-Object -First 15
        $tags | Sort-Object PagedMB -Descending | Select-Object -First 15
    ) | Sort-Object Tag -Unique |
        Export-Csv -Path (Join-Path $dir 'pooltags.csv') -Append -NoTypeInformation
}
catch {
    "$ts  $($_.Exception.Message)" | Add-Content -Path (Join-Path $dir 'errors.log')
}
