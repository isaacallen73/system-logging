# Diff two baseline runs. With no arguments: the oldest vs the newest run for this computer.
#   .\compare.ps1                                  # first baseline vs latest
#   .\compare.ps1 -Old <folder> -New <folder>      # any two runs
# Prints the report and saves it as compare-vs-<old>.txt inside the newer run's folder.
param(
    [string]$Old, [string]$New,
    [string]$DataRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data'),
    [int]$FolderDeltaMB = 100,
    [int]$ProcessDeltaMB = 100
)
$ErrorActionPreference = 'Stop'
if (-not $Old -or -not $New) {
    $runs = @(Get-ChildItem (Join-Path (Join-Path $DataRoot $env:COMPUTERNAME) 'baseline') -Directory | Sort-Object Name)
    if ($runs.Count -lt 2) { throw "Need at least two baseline runs; found $($runs.Count)." }
    if (-not $Old) { $Old = $runs[0].FullName }
    if (-not $New) { $New = $runs[-1].FullName }
}
$report = New-Object System.Collections.Generic.List[string]
function Say([string]$s = '') { $report.Add($s) }
function Load([string]$dir, [string]$file) {
    $p = Join-Path $dir $file; if (Test-Path $p) { @(Import-Csv $p) } else { $null } }
function KeyOf($row, [string[]]$cols) { ($cols | ForEach-Object { $row.$_ }) -join ' | ' }

# Keyed lists: what was added, removed, or changed in the watched columns.
function Diff-Keyed([string]$file, [string]$title, [string[]]$key, [string[]]$watch, [string[]]$show) {
    $a = Load $Old $file; $b = Load $New $file
    if ($a -eq $null -or $b -eq $null) { return }
    $ma = @{}; foreach ($r in $a) { $k = KeyOf $r $key; if (-not $ma.ContainsKey($k)) { $ma[$k] = $r } }
    $mb = @{}; foreach ($r in $b) { $k = KeyOf $r $key; if (-not $mb.ContainsKey($k)) { $mb[$k] = $r } }
    $added   = @($mb.Keys | Where-Object { -not $ma.ContainsKey($_) } | Sort-Object)
    $removed = @($ma.Keys | Where-Object { -not $mb.ContainsKey($_) } | Sort-Object)
    $changed = @($mb.Keys | Where-Object { $ma.ContainsKey($_) } | Sort-Object | ForEach-Object { $k = $_
        $d = @($watch | Where-Object { [string]$ma[$k].$_ -ne [string]$mb[$k].$_ } |
            ForEach-Object { "$_ '$($ma[$k].$_)' -> '$($mb[$k].$_)'" })
        if ($d.Count) { "$k : $($d -join '; ')" } })
    Say "== $title ($($a.Count) -> $($b.Count)): +$($added.Count) added, -$($removed.Count) removed, $($changed.Count) changed"
    foreach ($k in $added)   { $extra = ($show | ForEach-Object { $mb[$k].$_ } | Where-Object { $_ }) -join ' | '
                               Say "  + $k$(if ($extra) { "   [$extra]" })" }
    foreach ($k in $removed) { Say "  - $k" }
    foreach ($c in $changed) { Say "  ~ $c" }
    Say
}

function Side-By-Side([string]$file, [string]$title, [string]$keyCol) {
    $a = Load $Old $file; $b = Load $New $file
    if ($a -eq $null -or $b -eq $null) { return }
    Say "== $title"
    if ($keyCol) {
        $ma = @{}; $a | ForEach-Object { $ma[$_.$keyCol] = $_ }
        foreach ($r in $b) { foreach ($p in $r.PSObject.Properties.Name | Where-Object { $_ -ne $keyCol }) {
            $o = if ($ma[$r.$keyCol]) { $ma[$r.$keyCol].$p } else { '' }
            if ([string]$o -ne [string]$r.$p) { Say ("  {0,-28} {1,-14} -> {2}" -f "$($r.$keyCol) $p", $o, $r.$p) } } }
    } else {
        foreach ($p in $b[0].PSObject.Properties.Name) {
            Say ("  {0,-16} {1,-14} -> {2}" -f $p, $a[0].$p, $b[0].$p) }
    }
    Say
}

Say "Baseline comparison"
Say "  old: $Old"
Say "  new: $New"
Say

$sa = Load $Old 'system.csv'; $sb = Load $New 'system.csv'
if ($sa -and $sb) {
    $ha = @{}; $sa | ForEach-Object { $ha[$_.Key] = $_.Value }
    Say "== System"
    foreach ($r in $sb) { if ($ha[$r.Key] -ne $r.Value -or $r.Key -in 'Taken') {
        Say ("  {0,-12} {1}  ->  {2}" -f $r.Key, $ha[$r.Key], $r.Value) } }
    Say
}
Side-By-Side 'resources.csv' 'Idle resources (old -> new)'
Side-By-Side 'disks.csv' 'Disks' 'Drive'
Side-By-Side 'disk_health.csv' 'Disk health (wear, temperature, errors; admin runs only)' 'Disk'

# Boot times: median of the boots each run could see (the log keeps a rolling history).
$ba = Load $Old 'boot_times.csv'; $bb = Load $New 'boot_times.csv'
if ($ba -and $bb) {
    $median = { param($rows) $v = @($rows | ForEach-Object { [double]$_.BootMs } | Sort-Object)
        if ($v.Count) { [math]::Round($v[[int][math]::Floor(($v.Count - 1) / 2)] / 1000, 1) } else { '' } }
    Say "== Boot time (median seconds, power-on to usable desktop)"
    Say ("  {0} s over {1} boots  ->  {2} s over {3} boots" -f (& $median $ba), $ba.Count, (& $median $bb), $bb.Count)
    Say
}

# Processes: compare by name, since IDs change every boot.
$pa = Load $Old 'processes.csv'; $pb = Load $New 'processes.csv'
if ($pa -and $pb) {
    # (Measure-Object ignores scriptblock properties in PowerShell 5.1, so sum by hand.)
    $agg = { param($rows) $h = @{}; $rows | Group-Object Name | ForEach-Object {
        $mb = 0.0; $cpu = 0.0
        foreach ($r in $_.Group) { if ($r.PrivateMB) { $mb += [double]$r.PrivateMB }; if ($r.IdleCpuPct) { $cpu += [double]$r.IdleCpuPct } }
        $h[$_.Name] = [pscustomobject]@{ N = $_.Count; MB = $mb; Cpu = $cpu } }; $h }
    $ga = & $agg $pa; $gb = & $agg $pb
    Say "== Processes by name ($($pa.Count) -> $($pb.Count) processes)"
    $gb.Keys | Where-Object { -not $ga.ContainsKey($_) } | Sort-Object { $gb[$_].MB } -Descending | ForEach-Object {
        Say ("  + {0,-40} x{1,-3} {2,7:N0} MB  idle cpu {3:N1}%" -f $_, $gb[$_].N, $gb[$_].MB, $gb[$_].Cpu) }
    $ga.Keys | Where-Object { -not $gb.ContainsKey($_) } | Sort-Object | ForEach-Object { Say "  - $_" }
    $gb.Keys | Where-Object { $ga.ContainsKey($_) -and [math]::Abs($gb[$_].MB - $ga[$_].MB) -ge $ProcessDeltaMB } |
        Sort-Object { $gb[$_].MB - $ga[$_].MB } -Descending | ForEach-Object {
        Say ("  ~ {0,-40} {1,7:N0} -> {2,7:N0} MB" -f $_, $ga[$_].MB, $gb[$_].MB) }
    Say
}

Diff-Keyed 'programs.csv'        'Installed programs' @('Name')               @('Version')                     @('Version', 'Publisher', 'SizeMB')
Diff-Keyed 'store_apps.csv'      'Store apps'         @('Name')               @('Version')                     @('Version', 'Publisher')
Diff-Keyed 'services.csv'        'Services'           @('Name')               @('StartMode', 'State', 'PathName') @('DisplayName', 'StartMode', 'State', 'PathName')
Diff-Keyed 'scheduled_tasks.csv' 'Scheduled tasks'    @('Task')               @('State', 'Actions')            @('State', 'Triggers', 'Actions')
Diff-Keyed 'startup.csv'         'Startup items'      @('Name', 'Location')   @('Command', 'Status')           @('Status', 'Command')
Diff-Keyed 'kernel_drivers.csv'  'Kernel drivers'     @('Name')               @('StartMode', 'State', 'PathName') @('DisplayName', 'StartMode', 'PathName')
Diff-Keyed 'device_drivers.csv'  'Device drivers'     @('DeviceClass', 'DeviceName') @('DriverVersion', 'DriverProviderName') @('DriverProviderName', 'DriverVersion')
Diff-Keyed 'listening.csv'       'Listening ports'    @('Proto', 'PortKey', 'Process') @()                      @('Address', 'Port')
Diff-Keyed 'path.csv'            'PATH entries'       @('Scope', 'Entry')     @()                              @()
Diff-Keyed 'features.csv'        'Windows features'   @('FeatureName')        @()                              @()
Diff-Keyed 'hotfixes.csv'        'Windows updates'    @('HotFixID')           @()                              @('Description', 'InstalledOn')

# Folders: biggest growth first. Folders under the size floor are absent, so "new" may mean "grew past it".
$fa = Load $Old 'folders.csv'; $fb = Load $New 'folders.csv'
if ($fa -and $fb) {
    $ma = @{}; $fa | ForEach-Object { $ma[$_.Path] = [double]$_.SizeMB }
    $mb = @{}; $fb | ForEach-Object { $mb[$_.Path] = [double]$_.SizeMB }
    $deltas = @(($ma.Keys + $mb.Keys) | Sort-Object -Unique | ForEach-Object {
        $o = if ($ma.ContainsKey($_)) { $ma[$_] } else { 0 }; $n = if ($mb.ContainsKey($_)) { $mb[$_] } else { 0 }
        [pscustomobject]@{ Path = $_; Old = $o; New = $n; Delta = $n - $o } } |
        Where-Object { [math]::Abs($_.Delta) -ge $FolderDeltaMB })
    Say "== Folders that changed by >= $FolderDeltaMB MB (parents include their children)"
    $deltas | Sort-Object Delta -Descending | ForEach-Object {
        Say ("  {0,8:+#,0;-#,0} MB  {1,8:N0} -> {2,8:N0}  {3}" -f $_.Delta, $_.Old, $_.New, $_.Path) }
    Say
}

$report | ForEach-Object { Write-Host $_ }
$file = Join-Path $New "compare-vs-$(Split-Path $Old -Leaf).txt"
$report | Set-Content -Path $file -Encoding UTF8
Write-Host "Saved: $file"
