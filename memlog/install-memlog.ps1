# Registers the MemLogger scheduled task for the current user: at logon, then every 30 minutes.
# Runs hidden (conhost --headless), on battery too, never overlapping, killed after 5 minutes.
# Re-running replaces the existing task. Remove with: Unregister-ScheduledTask MemLogger
param([string]$TaskName = 'MemLogger', [int]$EveryMinutes = 30)
$script = Join-Path $PSScriptRoot 'memlog.ps1'
$action = New-ScheduledTaskAction -Execute 'conhost.exe' `
    -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`""
$triggers = @(
    New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings `
    -Principal $principal -Description "Memory snapshot logger: $script" -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
"Registered '$TaskName': at logon + every $EveryMinutes min. First sample running now."
"Data: $(Join-Path (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'data') $env:COMPUTERNAME) 'memlog')"
