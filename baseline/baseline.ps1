# System baseline: a point-in-time inventory written as CSVs to
#   data\<COMPUTERNAME>\baseline\<yyyy-MM-dd_HHmm>\
# Run it on a clean machine, then again whenever things feel heavier, and diff with compare.ps1.
# Runs fine as a normal user; run as admin to also capture optional Windows features.
#   -SkipFolderSizes   skip the disk scan (the slowest part)
#   -IdleSeconds N     how long to sample CPU (default 20)
param(
    [string]$DataRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data'),
    [switch]$SkipFolderSizes,
    [int]$IdleSeconds = 20,
    [int]$MinFolderMB = 50
)
$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$out = Join-Path (Join-Path (Join-Path $DataRoot $env:COMPUTERNAME) 'baseline') $stamp
New-Item -ItemType Directory -Force -Path $out | Out-Null
$errors = New-Object System.Collections.Generic.List[string]
function Step([string]$name, [scriptblock]$body) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Host ("{0,-22}" -f $name) -NoNewline
    try { & $body; Write-Host ("ok  ({0:N0} s)" -f $sw.Elapsed.TotalSeconds) }
    catch { Write-Host "FAILED: $($_.Exception.Message)"; $errors.Add("${name}: $($_.Exception.Message)") }
}
function Save($rows, [string]$file) { $rows | Export-Csv -Path (Join-Path $out $file) -NoTypeInformation -Encoding UTF8 }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Baseline -> $out  (admin: $isAdmin)"

Step 'system' {
    $os   = Get-CimInstance Win32_OperatingSystem
    $cs   = Get-CimInstance Win32_ComputerSystem
    $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS
    $cv   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $gpus = (Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name) [$($_.DriverVersion)]" }) -join '; '
    $rows = [ordered]@{
        Taken = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Computer = $env:COMPUTERNAME
        Manufacturer = $cs.Manufacturer; Model = $cs.Model; BIOS = "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))"
        OS = $os.Caption; Version = "$($cv.DisplayVersion) build $($cv.CurrentBuild).$($cv.UBR)"
        Installed = $os.InstallDate; LastBoot = $os.LastBootUpTime
        UptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
        CPU = $cpu.Name.Trim(); Cores = $cpu.NumberOfCores; Threads = $cpu.NumberOfLogicalProcessors
        RAMGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1); GPU = $gpus
    }
    Save ($rows.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Value = [string]$_.Value } }) 'system.csv'
}

Step 'idle cpu + memory' {
    $before = @{}; Get-Process | ForEach-Object { try { $before[$_.Id] = $_.TotalProcessorTime.TotalSeconds } catch {} }
    $samples = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples $IdleSeconds).CounterSamples.CookedValue
    $threads = [Environment]::ProcessorCount
    $perf = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $procs = Get-Process
    Save ([pscustomobject]@{
        IdleCpuAvgPct = [math]::Round(($samples | Measure-Object -Average).Average, 1)
        IdleCpuMaxPct = [math]::Round(($samples | Measure-Object -Maximum).Maximum, 1)
        CommitGB = [math]::Round($perf.CommittedBytes / 1GB, 2); CommitLimitGB = [math]::Round($perf.CommitLimit / 1GB, 2)
        AvailableGB = [math]::Round($perf.AvailableBytes / 1GB, 2); CacheGB = [math]::Round($perf.CacheBytes / 1GB, 2)
        NonPagedMB = [math]::Round($perf.PoolNonpagedBytes / 1MB); PagedMB = [math]::Round($perf.PoolPagedBytes / 1MB)
        ProcPrivateGB = [math]::Round(($procs | Measure-Object PrivateMemorySize64 -Sum).Sum / 1GB, 2)
        ProcessCount = $procs.Count; ThreadCount = ($procs | ForEach-Object { $_.Threads.Count } | Measure-Object -Sum).Sum
        HandleCount = ($procs | Measure-Object HandleCount -Sum).Sum
    }) 'resources.csv'
    $script:cpuPct = @{}
    $procs | ForEach-Object { try { if ($before.ContainsKey($_.Id)) {
        $script:cpuPct[$_.Id] = [math]::Round(100 * ($_.TotalProcessorTime.TotalSeconds - $before[$_.Id]) / $IdleSeconds / $threads, 2) } } catch {} }
}

Step 'processes' {
    $cim = @{}; Get-CimInstance Win32_Process | ForEach-Object { $cim[[int]$_.ProcessId] = $_ }
    Save (Get-Process | ForEach-Object {
        $c = $cim[$_.Id]
        [pscustomobject]@{
            Name = $_.ProcessName; Id = $_.Id; IdleCpuPct = $script:cpuPct[$_.Id]
            PrivateMB = [math]::Round($_.PrivateMemorySize64 / 1MB); WorkingSetMB = [math]::Round($_.WorkingSet64 / 1MB)
            Handles = $_.HandleCount; Threads = $_.Threads.Count
            Path = if ($c) { $c.ExecutablePath } else { '' }
            Company = $(try { $_.Company } catch { '' })
            Parent = if ($c) { $c.ParentProcessId } else { '' }
        }
    } | Sort-Object PrivateMB -Descending) 'processes.csv'
}

Step 'services' {
    Save (Get-CimInstance Win32_Service | Sort-Object Name | Select-Object Name, DisplayName, State, StartMode,
        @{n='DelayedStart';e={$_.DelayedAutoStart}}, StartName, PathName) 'services.csv'
}

Step 'scheduled tasks' {
    Save (Get-ScheduledTask | ForEach-Object {
        [pscustomobject]@{
            Task = "$($_.TaskPath)$($_.TaskName)"; State = [string]$_.State; Author = $_.Author
            Triggers = ($_.Triggers | ForEach-Object { $_.CimClass.CimClassName -replace '^MSFT_Task|Trigger$', '' }) -join ','
            Actions = ($_.Actions | ForEach-Object { if ($_.Execute) { "$($_.Execute) $($_.Arguments)".Trim() } else { $_.ClassId } }) -join ' | '
        }
    } | Sort-Object Task) 'scheduled_tasks.csv'
}

Step 'startup items' {
    # Win32_StartupCommand covers the Run keys and Startup folders. StartupApproved = Task Manager's on/off switch.
    $approved = @{}
    foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
                   'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
                   'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder') {
        if (Test-Path $k) { $p = Get-ItemProperty $k
            $p.PSObject.Properties | Where-Object { $_.Value -is [byte[]] } | ForEach-Object {
                $approved[$_.Name] = if ($_.Value[0] -band 1) { 'Disabled' } else { 'Enabled' } } }
    }
    Save (Get-CimInstance Win32_StartupCommand | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Location = $_.Location; User = $_.User; Command = $_.Command
            Status = if ($approved.ContainsKey($_.Name)) { $approved[$_.Name] } else { 'Enabled' } }
    } | Sort-Object Location, Name) 'startup.csv'
}

Step 'installed programs' {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Save (Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
        ForEach-Object { [pscustomobject]@{ Name = $_.DisplayName; Version = $_.DisplayVersion; Publisher = $_.Publisher
            InstallDate = $_.InstallDate; SizeMB = if ($_.EstimatedSize) { [math]::Round($_.EstimatedSize / 1KB) } else { '' }
            Scope = if ($_.PSPath -match 'HKEY_CURRENT_USER') { 'User' } else { 'Machine' } } } |
        Sort-Object Name, Version -Unique) 'programs.csv'
}

Step 'store apps' {
    Save (Get-AppxPackage | Select-Object Name, Version, Publisher, IsFramework, SignatureKind | Sort-Object Name) 'store_apps.csv'
}

Step 'drivers' {
    Save (Get-CimInstance Win32_SystemDriver | Sort-Object Name | Select-Object Name, DisplayName, State, StartMode, PathName) 'kernel_drivers.csv'
    Save (Get-CimInstance Win32_PnPSignedDriver | Where-Object DeviceName |
        Select-Object DeviceName, DeviceClass, DriverProviderName, DriverVersion, InfName | Sort-Object DeviceClass, DeviceName) 'device_drivers.csv'
}

Step 'listening ports' {
    $names = @{}; Get-Process | ForEach-Object { $names[$_.Id] = $_.ProcessName }
    $tcp = Get-NetTCPConnection -State Listen | ForEach-Object {
        [pscustomobject]@{ Proto = 'TCP'; Address = $_.LocalAddress; Port = $_.LocalPort; Process = $names[[int]$_.OwningProcess] } }
    $udp = Get-NetUDPEndpoint | ForEach-Object {
        [pscustomobject]@{ Proto = 'UDP'; Address = $_.LocalAddress; Port = $_.LocalPort; Process = $names[[int]$_.OwningProcess] } }
    # PortKey groups the random high ports (49152+) Windows hands out, so compare.ps1 diffs on
    # "which process listens on a fixed port" rather than churning on temporary ones.
    Save (@($tcp) + @($udp) | Sort-Object Proto, Port, Address -Unique | ForEach-Object {
        $_ | Add-Member PortKey $(if ([int]$_.Port -ge 49152) { 'dynamic' } else { [string]$_.Port }) -PassThru }) 'listening.csv'
}

Step 'updates + PATH' {
    Save (Get-HotFix | Select-Object HotFixID, Description, InstalledOn | Sort-Object HotFixID) 'hotfixes.csv'
    Save (@('Machine', 'User') | ForEach-Object { $scope = $_
        ([Environment]::GetEnvironmentVariable('Path', $scope) -split ';') | Where-Object { $_ } |
            ForEach-Object { [pscustomobject]@{ Scope = $scope; Entry = $_ } } }) 'path.csv'
}

if ($isAdmin) {
    Step 'optional features' {
        Save (Get-WindowsOptionalFeature -Online | Where-Object State -eq 'Enabled' |
            Select-Object FeatureName, State | Sort-Object FeatureName) 'features.csv'
    }
}

Step 'disks' {
    Save (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [pscustomobject]@{ Drive = $_.DeviceID; Label = $_.VolumeName; FileSystem = $_.FileSystem
            SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1)
            UsedGB = [math]::Round(($_.Size - $_.FreeSpace) / 1GB, 1) } }) 'disks.csv'
}

if (-not $SkipFolderSizes) {
    Step 'folder sizes (slow)' {
        if (-not ('BaselineDirSizer' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.IO; using System.Collections.Generic;
public class BaselineDirSizer {
  // Recursively sums file sizes. Skips junctions/symlinks and OneDrive-style cloud placeholders
  // (not actually on disk). Records every folder at depth <= maxDepth, or deeper under deepPrefix.
  public Dictionary<string, long[]> Sizes = new Dictionary<string, long[]>(StringComparer.OrdinalIgnoreCase);
  public int Denied = 0;
  int maxDepth, deepDepth; string deepPrefix;
  const FileAttributes Cloud = (FileAttributes)0x400000 | FileAttributes.Offline;
  public BaselineDirSizer(int maxDepth, string deepPrefix, int deepDepth) {
    this.maxDepth = maxDepth; this.deepPrefix = deepPrefix; this.deepDepth = deepDepth; }
  public long[] Walk(DirectoryInfo d, int depth) {
    long bytes = 0, files = 0;
    FileSystemInfo[] items;
    try { items = d.GetFileSystemInfos(); } catch { Denied++; return new long[] { 0, 0 }; }
    foreach (var i in items) {
      try {
        if ((i.Attributes & FileAttributes.ReparsePoint) != 0) continue;
        if ((i.Attributes & FileAttributes.Directory) != 0) {
          var s = Walk((DirectoryInfo)i, depth + 1); bytes += s[0]; files += s[1];
        } else if ((i.Attributes & Cloud) == 0) { bytes += ((FileInfo)i).Length; files++; }
      } catch { Denied++; }
    }
    if (depth <= maxDepth || (deepPrefix != null && depth <= deepDepth &&
        d.FullName.StartsWith(deepPrefix, StringComparison.OrdinalIgnoreCase)))
      Sizes[d.FullName] = new long[] { bytes, files };
    return new long[] { bytes, files };
  }
}
'@
        }
        # Depth 3 everywhere (C:\Users\<you>, C:\Program Files\Foo), depth 5 under the profile
        # (C:\Users\<you>\AppData\Local\Foo) where per-app caches pile up.
        $sizer = New-Object BaselineDirSizer 3, $env:USERPROFILE, 5
        $root = [IO.DirectoryInfo]"$env:SystemDrive\"
        [void]$sizer.Walk($root, 0)
        $minBytes = $MinFolderMB * 1MB
        Save ($sizer.Sizes.GetEnumerator() | Where-Object { $_.Value[0] -ge $minBytes } | ForEach-Object {
            [pscustomobject]@{ Path = $_.Key; SizeMB = [math]::Round($_.Value[0] / 1MB); Files = $_.Value[1] } } |
            Sort-Object Path) 'folders.csv'
        if ($sizer.Denied) { $errors.Add("folder sizes: $($sizer.Denied) items not readable (normal without admin)") }
    }
}

if ($errors.Count) { $errors | Set-Content -Path (Join-Path $out 'errors.txt') -Encoding UTF8 }
Write-Host "Done. $((Get-ChildItem $out).Count) files in $out"
