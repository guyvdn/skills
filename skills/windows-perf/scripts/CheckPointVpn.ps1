<#
  On-demand Check Point Endpoint Security VPN.
  Assumes the services TracSrvWrapper (VPN) and EPWD (watchdog) are set to Manual, so
  nothing starts at boot (and no smart-card / eID prompt). This starts or stops them.

    CheckPointVpn.ps1          start services + tray GUI   (one UAC prompt)
    CheckPointVpn.ps1 -Stop    stop services, close GUI    (one UAC prompt)

  Needs Windows sudo (Settings > System > Advanced, mode "Input closed").
  See references/on-demand-apps.md in the windows-perf skill.
#>
param(
    [switch]$Stop,
    [string]$Gui = 'C:\Program Files (x86)\CheckPoint\Endpoint Connect\TrGUI.exe'
)

if ($Stop) {
    # Watchdog first, or it restarts the VPN service.
    sudo pwsh -NoProfile -Command "Stop-Service EPWD -Force; Stop-Service TracSrvWrapper -Force; Get-Process TrGUI,TracCAPI -ErrorAction SilentlyContinue | Stop-Process -Force"
    return
}

if ((Get-Service TracSrvWrapper).Status -ne 'Running' -or (Get-Service EPWD).Status -ne 'Running') {
    sudo pwsh -NoProfile -Command "Start-Service TracSrvWrapper; Start-Service EPWD"
}

# EPWD normally launches the GUI itself; start it unelevated if it did not.
for ($i = 0; $i -lt 10 -and -not (Get-Process TrGUI -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
if (-not (Get-Process TrGUI -ErrorAction SilentlyContinue)) { Start-Process $Gui }
