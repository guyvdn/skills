<#
.SYNOPSIS
    Installs a SYSTEM scheduled task that blocks idle sleep while a given program runs.

.DESCRIPTION
    For a PC that streams jobs to a laser, CNC or 3D printer over USB: Windows' idle timer
    doesn't know a job is running, so the PC can sleep mid-cut. The task polls for the
    process and holds ES_CONTINUOUS | ES_SYSTEM_REQUIRED while it exists (the display may
    still turn off). Closing the lid still sleeps the PC. Run elevated.

    Verify with the app open: `powercfg /requests` lists [PROCESS] ...\powershell.exe under SYSTEM.

.PARAMETER ProcessName
    Process name without .exe, as shown by Get-Process (e.g. FalconDesignSpace, LightBurn).

.PARAMETER TaskName
    Scheduled task name. Use different names to watch several apps.

.PARAMETER PollSeconds
    How often to check for the process.

.PARAMETER Uninstall
    Remove the task and its script.

.EXAMPLE
    .\Install-KeepAwake.ps1 -ProcessName FalconDesignSpace

.EXAMPLE
    .\Install-KeepAwake.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install', Mandatory)][ValidatePattern('^[\w .-]+$')][string]$ProcessName,
    [string]$TaskName = 'KeepAwakeWhileAppRuns',
    [Parameter(ParameterSetName = 'Install')][ValidateRange(5, 600)][int]$PollSeconds = 30,
    [Parameter(ParameterSetName = 'Uninstall', Mandatory)][switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:ProgramData $TaskName
$script = Join-Path $dir 'keepawake.ps1'

function Stop-Helper {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like "*$script*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Uninstall) {
    Stop-Helper
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    "Removed $TaskName."
    return
}

$ProcessName = $ProcessName -replace '\.exe$', ''
New-Item -ItemType Directory -Force $dir | Out-Null
# Flags in decimal on purpose: Windows PowerShell 5.1 reads 0x80000001 as a negative Int32,
# which then fails to convert to UInt32 at the call, silently if the output is discarded.
@"
# Blocks idle sleep while $ProcessName runs (installed by Install-KeepAwake.ps1).
Add-Type -Namespace Win32 -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);'
`$ES_CONTINUOUS = [uint32]2147483648
`$ES_SYSTEM_REQUIRED = [uint32]1
`$awake = `$false
while (`$true) {
    `$running = [bool](Get-Process -Name '$ProcessName' -ErrorAction SilentlyContinue)
    if (`$running -and -not `$awake) { [Win32.Power]::SetThreadExecutionState(`$ES_CONTINUOUS -bor `$ES_SYSTEM_REQUIRED) | Out-Null; `$awake = `$true }
    elseif (-not `$running -and `$awake) { [Win32.Power]::SetThreadExecutionState(`$ES_CONTINUOUS) | Out-Null; `$awake = `$false }
    Start-Sleep -Seconds $PollSeconds
}
"@ | Set-Content $script -Encoding ASCII

$action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Stop-Helper
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "Blocks idle sleep while $ProcessName runs." -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
"$TaskName installed and $((Get-ScheduledTask -TaskName $TaskName).State): watching '$ProcessName' every $PollSeconds s."
"Verify: open the app, wait $PollSeconds s, then run 'powercfg /requests' and look under SYSTEM:."
