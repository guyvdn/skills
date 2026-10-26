# Disabling services and startup items

Part of the [windows-perf](../SKILL.md) skill. Steps 1–4 there find the culprit; this file is
what to do once you have one.

## Step 5 — Disable the offending service

```powershell
Stop-Service <ServiceName> -Force
Set-Service <ServiceName> -StartupType Disabled
```

If the process lingers after stopping the service:

```powershell
taskkill /PID <pid> /F
```

## Step 6 — Run the cleanup script

Disables known CPU-hungry and telemetry services and removes unnecessary startup
items. Requires admin PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Disable-UnnecessaryServices.ps1

# also disable IIS (opt-in; see the note below)
powershell -ExecutionPolicy Bypass -File scripts/Disable-UnnecessaryServices.ps1 -IncludeIIS
```

### Services the script disables

| Service | Description |
|---|---|
| `SNAPOService` | Sonitude audio APO — known CPU spinner, not needed with Bluetooth headphones |
| `CxUtilSvc` / `CxMonSvc` | Conexant audio utilities |
| `DiagTrack` | Windows Connected User Experiences & Telemetry |
| `HPAudioAnalytics` | HP audio analytics |
| `HpTouchpointAnalyticsService` | HP Touchpoint analytics |
| `hpLHAgent` / `hpLHWatchdog` | HP Insights telemetry agent |
| `Intel Analytics Service` | Intel telemetry |
| `dptftcs` | Intel Dynamic Tuning Technology **Telemetry** service |

### Services the script deliberately leaves alone

| Service | Why |
|---|---|
| `ipfsvc` | **Intel Innovation Platform Framework — not telemetry.** On modern Intel mobile parts this is the dynamic power and thermal manager; it trims sustained power limits so the chassis does not sit hot. Measured over 3 minutes on a 13th-gen P-series laptop, `ipf_helper.exe` and `ipf_uf.exe` both held 0% CPU. Disabling it saves nothing and removes thermal management. |
| `W3SVC` (IIS) | Opt-in via `-IncludeIIS`. Many developer machines host sites on local IIS, and an idle W3SVC costs almost nothing. Do not disable it on a .NET box without asking. |

Judge a service by its **display name and actual role**, not by the vendor prefix.
Run `Get-Service <name> | Select-Object Name, DisplayName` before assuming "Intel" or
"HP" means telemetry.

### Startup items the script removes

| Entry | Description |
|---|---|
| `MicrosoftEdgeAutoLaunch_*` | Edge silent background launch |
| `GoogleChromeAutoLaunch_*` | Chrome silent background launch |
| `Adobe Acrobat Synchronizer` | Acrobat collaboration sync |
| `StartLoad` | Yealink Wireless Presentation Pod |
| `ClickShare` | Barco ClickShare presentation tool |
