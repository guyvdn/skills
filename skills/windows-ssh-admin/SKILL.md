---
name: windows-ssh-admin
description: 'Use this skill when asked to manage, configure, debloat or troubleshoot another Windows PC on the LAN from this one without installing an agent on it: enabling OpenSSH Server on the target with one admin paste, finding it on the network, running elevated PowerShell over SSH, and doing what plain SSH cannot (mapping drives, starting GUI apps, OneDrive downloads, Windows Update and BIOS installs, restarts). Also use when SSH-driven scripts on a Windows target fail in confusing ways: commands chained with `;` under cmd, PowerShell 5.1 parse errors, output that never arrives, or a UAC prompt nobody can answer.'
version: 1.0.0
compatibility: 'Target: Windows 10/11 with an admin account. Controller: any machine with OpenSSH (Git Bash on Windows works; examples use bash for the controller side and PowerShell 5.1 on the target).'
---

# Managing a Windows PC over SSH

Drive a second Windows PC (an old laptop next to a machine, a family PC) from the one you
are on. One paste on the target enables Windows' own OpenSSH server; after that everything
runs from here, nothing extra is installed or signed in on the target, and the work stays
recorded in this session.

Prefer this over installing an agent (Claude Code, a remote-desktop tool) on the target when
the target should stay lean: an agent updates itself, runs in the background and needs a
login of its own.

## Step 1 — Enable the SSH server (the only step on the target)

Generate a dedicated key on the controller first (`ssh-keygen -t ed25519 -N "" -C
"controller->target" -f ~/.ssh/<target>_ed25519`) and put its `.pub` line in the block
below. The user pastes it into **PowerShell as Administrator** on the target:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic; Start-Service sshd
if (-not (Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -EA 0)) { New-NetFirewallRule -Name OpenSSH-Server-In-TCP -DisplayName 'OpenSSH Server (sshd)' -Protocol TCP -LocalPort 22 -Action Allow -Direction Inbound }
Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -RemoteAddress LocalSubnet -Profile Any -Enabled True
Set-Content C:\ProgramData\ssh\administrators_authorized_keys '<PUBKEY LINE>' -Encoding ascii
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant '*S-1-5-32-544:F' '*S-1-5-18:F'
Get-Service sshd | select Status, StartType
whoami; hostname; Get-NetIPAddress -AddressFamily IPv4 | ? IPAddress -like '192.168.*' | select InterfaceAlias,IPAddress
```

- **Ask for the last lines of output back**: the username (`whoami`) and the IP address are
  what you need to connect. If the user only says "done", scan for it (Step 2) and try the
  controller's own username, which is often the same Microsoft account.
- **`Add-WindowsCapability` often looks stuck for 5–15 minutes**, longer on a PC that was
  off for months (Windows Update first finishes its backlog). Have the user check from a
  second admin window: `Get-WindowsCapability -Online -Name OpenSSH.Server*` (State
  `Installed` = done) and `Get-Service TrustedInstaller` (Running = still busy). After 15
  minutes, fall back to `winget install --id Microsoft.OpenSSH.Preview -e` (same server and
  same key file, no Windows Update) and run the remaining lines.
- **If the lines after the install never ran** (pasting while a long command runs loses
  them easily), port 22 stays closed. Every line is idempotent, so have the user paste the
  block from `Set-Service` on again.
- Admins authenticate against `administrators_authorized_keys`, not `~\.ssh\authorized_keys`,
  and the file must be owned by Administrators/SYSTEM only (hence the SIDs, which also work
  on non-English Windows). **Key-authenticated admin sessions are elevated**; there is no UAC
  in an SSH session.

## Step 2 — Find it and connect

```powershell
# Every host with port 22 open, in about two seconds. List each /24 of the LAN (a /23 has two).
$ips = foreach ($net in '192.168.1') { 1..254 | % { "$net.$_" } }
$t = foreach ($ip in $ips) { $c = New-Object Net.Sockets.TcpClient; [pscustomobject]@{ ip=$ip; c=$c; t=$c.ConnectAsync($ip,22) } }
[Threading.Thread]::Sleep(2000); $t | ? { $_.t.Status -eq 'RanToCompletion' } | % ip; $t | % { $_.c.Close() }
```

- **Compare the host key before you trust a new address.** `ssh-keyscan -t ed25519 <ip> |
  ssh-keygen -lf -`. A laptop on a USB-C dock has two addresses (dock Ethernet and WiFi)
  with the same host key; the router may name both the same.
- **"Host key has changed" right after enabling SSH is usually a recycled DHCP address**:
  `known_hosts` still holds whatever had that IP before. Fingerprint the stored line
  (`sed -n <n>p ~/.ssh/known_hosts | ssh-keygen -lf -`); if it matches another machine you
  know, `ssh-keygen -R <ip>` and accept the new key.
- Ask the user to reserve the target's address in the router (DHCP reservation) once it
  works; its normal connection (WiFi or dock) decides which MAC to reserve.

## Step 3 — Run things on it

- **The default shell is cmd**, not PowerShell. Chain with `&`, never `;` (cmd passes
  `script.ps1;` on as a file name). `%` must be doubled inside `powershell -Command "…"`
  sent through cmd, and nested quotes break quickly.
- **Ship scripts instead of one-liners**: write the `.ps1` locally, `scp` it, run
  `ssh … 'powershell -NoProfile -ExecutionPolicy Bypass -File x.ps1 & del x.ps1'`.
- **Write those files with an editor or file tool, not a bash heredoc**: Git Bash collapsed
  `\\server\share` to `\server\share` in a heredoc, which broke a `net use` silently.
- **Parse-check before shipping**, with the same Windows PowerShell 5.1 the target runs:
  `powershell.exe -NoProfile -Command '$e=$null; [void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path x.ps1),[ref]$null,[ref]$e); $e | % Message'`.
  A parse error makes a scheduled task exit 1 without writing a single log line.
- Long jobs: run the SSH command in the background and read its output when it finishes;
  output from `Write-Output` inside a `-File` script arrives only at the end.
- `wmic` is gone on Windows 11 24H2; use `Get-CimInstance`.

## Step 4 — What SSH cannot do: the desktop session

An SSH login is a separate network logon. It has the user's HKCU and admin rights, but:

| Needs the user's desktop session | Why |
|---|---|
| `net use` / mapped drive letters | A mapping made over SSH lives only in the SSH logon session |
| Starting a GUI app the user should see | It would start invisibly in the SSH session |
| Reading OneDrive cloud-only files | Hydration goes through the OneDrive client running on the desktop |
| `winget` Store installs, `Get-StartApps` | Need the interactive user context |

Run those through a one-shot scheduled task with `-LogonType Interactive` (it runs in the
logged-on user's session). [scripts/Invoke-InDesktopSession.ps1](scripts/Invoke-InDesktopSession.ps1)
does the register-run-wait-collect-unregister cycle; `scp` it and the payload script over, then:

```bash
ssh -i <key> <user>@<ip> 'powershell -NoProfile -ExecutionPolicy Bypass -File Invoke-InDesktopSession.ps1 -ScriptPath C:\Users\<user>\payload.ps1 -Elevated'
```

`-Elevated` adds `-RunLevel Highest`: the task gets the admin token without a UAC prompt,
so installers that would otherwise ask can run silently. The user must be signed in.

**Run as SYSTEM instead** (`New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType
ServiceAccount`) for Windows Update API installs: the Update Session COM object refuses to
install from a network logon. Searching works over SSH directly:

```powershell
$s = New-Object -ComObject Microsoft.Update.Session; $q = $s.CreateUpdateSearcher(); $q.ServerSelection = 2
$q.Search("IsInstalled=0 and Type='Driver'").Updates | % { '{0} | {1:yyyy-MM-dd}' -f $_.Title, $_.DriverVerDate }
```

That list includes OEM firmware (`Lenovo Ltd. - Firmware - 1.63.0.0` is a BIOS capsule).
To install one: in a SYSTEM task, `AcceptEula()`, add it to a `Microsoft.Update.UpdateColl`,
`CreateUpdateDownloader().Download()`, `CreateUpdateInstaller().Install()`, then restart.
**Get the user's go-ahead for firmware**, check `root\wmi BatteryStatus.PowerOnline` first,
and tell them to leave the machine alone on the charger during the flash.

## Restart and wait

```bash
ssh … 'shutdown /r /t 15 /c "Restart by <who>: leave the charger in"'
```

Then poll port 22 until it goes away and comes back (a reboot took 50–70 s, a BIOS flash
about 4 minutes), and verify with `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime`.

## Gotchas

- **Never kill `consent.exe`.** A UAC prompt runs on the secure desktop; killing it from
  SSH left a laptop ignoring keyboard and mouse at the lock screen until a remote restart.
  Kill the process that raised the prompt instead, or ask the user to answer it, and run
  the elevated step from SSH, which needs no prompt.
- **PowerShell 5.1 reads hex literals above `0x7FFFFFFF` as negative `Int32`**: passing
  `0x80000001` to a `uint` P/Invoke parameter throws a conversion error at runtime, which a
  `| Out-Null` hides. Use decimal (`[uint32]2147483649`).
- **`"$name:"` inside a double-quoted string is a drive-qualified variable** (`$env:`,
  `$function:`), so `"REFUSED $latest: …"` is a parse error. Write `"${latest}:"`.
- **Non-ASCII characters in a script without a BOM** are read as ANSI by PowerShell 5.1 and
  can break string literals (a `█` in a regex did). Keep shipped scripts ASCII.
- **Recursive `Get-ChildItem` over a user profile can take tens of minutes** (Defender scans
  each file; OneDrive keeps tens of thousands of placeholders). For sizes use
  `robocopy <dir> NUL /L /S /NFL /NDL /NJH /BYTES /R:0 /W:0 /XJ` and read the summary; for
  file lists, name the folders instead of recursing from the profile root.
- **Secrets**: generate them on the controller into a temp file, send the file (`scp`, or
  as SSH stdin), delete it on both sides. In an agent session the clipboard may be
  unreachable (`Set-Clipboard` succeeds, `Get-Clipboard` returns nothing), so confirm the
  user has stored a password before you delete the only copy.
- The target's language changes command output (`Systeemfout 67`, `De opdracht is
  voltooid`); match on exit codes and objects, not on English text.
