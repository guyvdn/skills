---
name: windows-printer-duplicates
description: 'Use this skill only when the user explicitly asks about a printer that appears twice in Windows, a print queue stuck offline, documents sitting in the wrong queue, or a default printer that keeps changing on its own — covers WSD auto-discovery duplicates, rescuing queued jobs by repointing the port instead of editing spool files, which steps need elevation, and why Windows 11 hides the "Default" label.'
version: 1.0.0
---

# Duplicate and stuck Windows print queues

One physical printer, two entries in **Printers & scanners**. Jobs go to the dead one and sit
there. This is almost always WSD auto-discovery adding its own copy alongside the queue the
user installed from the vendor's driver.

**Start with the audit.** Read-only, needs no admin.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Test-PrinterQueues.ps1
```

It groups queues that point at the same device, names the keeper and the duplicate, reports
jobs stranded on an offline queue, and prints the exact fix commands. `-Json` for machine use.

## The insight: jobs belong to the queue, not to the port

A queued job is spooled against the **queue**. The port is just where the spooler sends the
bytes, and it is a mutable property. So a queue that is stuck offline can be pointed at a
working port and its existing jobs drain out to the real printer:

```powershell
Set-Printer -Name "<stuck queue>" -PortName "<port of the working queue>"
```

One line, **no elevation**, and fully reversible — set the old port name back. Almost every
guide online instead tells you to cancel the jobs and reprint, or to go digging for the
`.SHD`/`.SPL` pair in `C:\Windows\System32\spool\PRINTERS` and hand-edit the binary `.SHD` so
it names a different printer. That folder is not readable without admin, the edit is
unsupported, and it is unnecessary whenever both queues target the same physical device.

> Jobs spooled `RAW` (check with `Get-PrintJob | Select-Object Datatype`) are already
> rendered into the printer's own language, so they print unchanged over the new port. A
> `NT EMF` job is re-rendered by the destination driver instead — still fine for the same
> device, but expect a different driver's defaults (tray, duplex) to apply.

## The full rescue

```powershell
# 1. See both queues, their ports, drivers and job counts
Get-Printer | Select-Object Name, PortName, DriverName, PrinterStatus
Get-Printer | ForEach-Object { Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue }

# 2. Drain the stuck queue through the good port
Set-Printer -Name "Foo XY-100 series Printer" -PortName "BRWxxxxxxxxxxxx"

# 3. Confirm it emptied - and that the queue now reports real device status
Get-PrintJob -PrinterName "Foo XY-100 series Printer"      # expect nothing back
Get-Printer  -Name "Foo XY-100 series Printer" | Select-Object PrinterStatus

# 4. Hand the default to the keeper BEFORE deleting, then delete
$keep = Get-CimInstance Win32_Printer -Filter "Name='Foo XY-100 series'"
Invoke-CimMethod -InputObject $keep -MethodName SetDefaultPrinter
Remove-Printer -Name "Foo XY-100 series Printer"
```

A status flipping from `Offline` to something device-specific (`TonerLow`, `Normal`,
`PaperOut`) is the confirmation that the new port really reaches the printer — an unreachable
port cannot report toner.

## Picking the keeper

| Signal | Keeper | Duplicate |
|---|---|---|
| Port | `Standard TCP/IP Port` — RAW `:9100` or LPR `:515`, name like `BRWxxxxxxxxxxxx` | `WSD-<guid>` |
| Driver | The vendor's own (`Foo XY-100 series`) | `… Class Driver`, `Microsoft IPP Class Driver` |
| Status | `Normal` / a real device state | `Offline` |
| Options | Full vendor dialog — trays, toner save, duplex | Generic subset |

Keep the vendor-driver queue on the TCP/IP port. The in-box class driver prints, but it
exposes only a generic option set, and its WSD port is the part that goes dead: WSD depends
on multicast discovery, so a DHCP lease change, a subnet hop, or a router that drops mDNS/SSDP
silently orphans it. A hostname-based TCP/IP port survives an address change; only an IP-based
one has the same fragility, so prefer the `BRW…`-style hostname port where the vendor offers it.

## What needs elevation, and what does not

| Action | Elevated? |
|---|---|
| `Get-Printer`, `Get-PrintJob`, `Get-PrinterPort` | No |
| `Set-Printer -PortName` | No |
| `Remove-Printer` | No (a per-user queue); yes for a machine-wide one |
| `Remove-PrinterPort` | **Yes** |
| Reading `C:\Windows\System32\spool\PRINTERS` | **Yes** |
| Setting the default printer, `LegacyDefaultPrinterMode` | No — both are `HKCU` |

`Remove-PrinterPort` failing with *"An error occurred while performing the specified
operation"* usually just means no elevation — but it says the same thing when a queue still
references the port, so check that first. **Settings → Printers & scanners → Print server
properties → Ports** removes it without an admin shell.

Clean up the orphaned WSD port once the duplicate queue is gone. Leaving it lets discovery
re-create the duplicate later.

## The default-printer trap

Windows 11 ships with **"Let Windows manage my default printer"** on, which means the default
silently follows the last printer you printed to. Two consequences:

- Settings shows **no "Default" label at all** in the printer list, so there is nothing to
  read. `Get-CimInstance Win32_Printer | Where-Object Default | Select-Object -ExpandProperty Name`
  answers it, and `shell:PrintersFolder` still draws the classic green check.
- Any default you set gets undone by the next print to another printer.

The switch is `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Windows` →
`LegacyDefaultPrinterMode`: **`1` = pinned** (the label comes back), `0` or absent = Windows
manages it. The UI toggle is at the bottom of Printers & scanners.

```powershell
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' `
    -Name LegacyDefaultPrinterMode -Value 1
```

Turn this on before handing the default to the keeper queue, or the fix undoes itself.

## Gotchas

- **Do not delete the duplicate while it still holds jobs** — they go with it. Drain first.
- `Set-Printer -PortName` is instant; there is no need to stop the spooler. Reach for
  `Restart-Service Spooler` only if a job is wedged in `Deleting` or `Error` state — and note
  it needs admin and discards nothing else.
- `Get-PrintJob` throws rather than returning empty on some virtual queues; wrap it.
- `Get-PrinterPort` reports `Protocol` through its value map, so it reads back as `LPR`/`RAW`,
  **not** the documented `2`/`1`. Comparing against the number silently mislabels every LPR
  port as generic TCP/IP.
- A printer offline because someone ticked **Use Printer Offline** is a different fault with
  the same symptom — that is `Win32_Printer.WorkOffline`, and it is cleared from the queue's
  own menu, not by changing the port.
- Two queues may share one port quite legitimately (different defaults, e.g. a duplex one and
  a single-sided one). Confirm the duplicate is unwanted before removing it.
