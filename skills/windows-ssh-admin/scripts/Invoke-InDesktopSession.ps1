<#
.SYNOPSIS
    Runs a script in the logged-on user's desktop session and returns its output.

.DESCRIPTION
    Run this ON the target, from an SSH session. An SSH login is a separate network logon:
    drive mappings it makes, GUI apps it starts and OneDrive hydration don't reach the
    user's desktop. This registers a one-shot scheduled task with -LogonType Interactive for
    the console user, runs the payload in their session, waits, prints everything the payload
    wrote (stdout, stderr, warnings) and removes the task again.

.PARAMETER ScriptPath
    Full path of the .ps1 to run (on the target).

.PARAMETER Elevated
    Run with the user's admin token (RunLevel Highest), without a UAC prompt.

.PARAMETER TimeoutSeconds
    How long to wait for the payload. The task is stopped after that.

.EXAMPLE
    .\Invoke-InDesktopSession.ps1 -ScriptPath C:\Users\me\map-drive.ps1

.EXAMPLE
    .\Invoke-InDesktopSession.ps1 -ScriptPath C:\Users\me\install-store-app.ps1 -Elevated -TimeoutSeconds 900
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [switch]$Elevated,
    [int]$TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptPath)) { throw "Payload not found: $ScriptPath" }
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $user) { throw 'Nobody is signed in on the console; an interactive task has no session to run in.' }

$task = 'InDesktopSession-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$log = Join-Path $env:PUBLIC "$task.log"
$cmd = "& { & '$ScriptPath' } *> '$log'"
$action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$cmd`""
$level = if ($Elevated) { 'Highest' } else { 'Limited' }
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel $level
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeoutSeconds)

Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
try {
    Start-ScheduledTask -TaskName $task
    $t0 = Get-Date
    do { Start-Sleep -Seconds 2 } while ((Get-ScheduledTask -TaskName $task).State -eq 'Running' -and ((Get-Date) - $t0).TotalSeconds -lt $TimeoutSeconds)
    $state = (Get-ScheduledTask -TaskName $task).State
    if ($state -eq 'Running') { Stop-ScheduledTask -TaskName $task; Write-Warning "Payload still running after $TimeoutSeconds s; stopped." }
    '[{0}] {1} as {2} ({3}), result {4}, {5:N0} s' -f $task, (Split-Path $ScriptPath -Leaf), $user, $level, (Get-ScheduledTaskInfo -TaskName $task).LastTaskResult, ((Get-Date) - $t0).TotalSeconds
    if (Test-Path $log) { Get-Content $log }
} finally {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $log -Force -ErrorAction SilentlyContinue
}
