<#
.SYNOPSIS
    Turns off every monitor now. Any mouse move or key press wakes them.
.DESCRIPTION
    Broadcasts WM_SYSCOMMAND / SC_MONITORPOWER (2 = off) to all top-level windows.
    PostMessage, not SendMessage: a broadcast SendMessage blocks until every window
    answers, so one hung app hangs the script.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Invoke-ScreenOff.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    # Wait before switching off, so the key-up of the hotkey that launched this
    # (or the Enter that ran it) does not wake the screens straight back up.
    [int]$DelayMilliseconds = 700
)

Add-Type -Namespace Win32 -Name User32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);'

Start-Sleep -Milliseconds $DelayMilliseconds

# HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2 = off
[Win32.User32]::PostMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr]2) | Out-Null
