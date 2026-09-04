# The tablet is plugged in but unreachable

Work down this list. The order matters — each step distinguishes a different cause, and
the two most common ones (a VPN, and the toggle being off) produce *different* errors
that are easy to confuse.

## Read the error, it names the cause

| Symptom | Meaning |
|---|---|
| Timeout / `HTTP 000` / no response at all | Packets are going somewhere else. Routing — see §2. |
| **Connection actively refused** on port 80 | Routing is *fine*, the tablet answered. Nothing is listening: the USB web interface is off — see §3. |
| Empty JSON, or an HTML error page | The interface is up but the tablet is asleep or mid-sync. Tap the screen and retry. |
| A tiny (<1 KB) "PDF" | An error page saved to disk. The GUID is wrong, or the document was deleted. |

"Refused" is good news. It means the cable, the driver and the route all work.

## 1. Is the USB network device there at all?

```powershell
Get-NetAdapter | Where-Object InterfaceDescription -match 'NDIS|RNDIS' |
    Select-Object Name, InterfaceDescription, Status, ifIndex
```

The tablet appears as a **Remote NDIS Network Device** (the description varies by
driver — it does not say "reMarkable"). Expect `Status: Up` and a host address in
`10.11.99.0/27`:

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -like '10.11.99.*'
```

No adapter at all → cable or driver. Try a different cable first; charge-only USB
cables are extremely common and carry no data.

## 2. A VPN steals the tablet's subnet

**This is the one that wastes an afternoon**, because everything looks correct: the
adapter is Up, the host has `10.11.99.x`, and the request still times out.

Corporate VPN clients routinely push a `10.0.0.0/8` split-tunnel route *and* a route for
`10.11.99.0/27` at a **lower metric** than the tablet's own interface. Same prefix,
better metric — the VPN wins, and every packet for the tablet goes down the tunnel and
is dropped.

Diagnose — this is the definitive test, not a guess:

```powershell
Find-NetRoute -RemoteIPAddress 10.11.99.1 | Select-Object -First 1 IPAddress, InterfaceAlias
```

If `InterfaceAlias` names your VPN adapter rather than the NDIS one, that is the cause.
To see it in full:

```powershell
Get-NetRoute -AddressFamily IPv4 |
    Where-Object DestinationPrefix -like '10.11.99.*' |
    Select-Object DestinationPrefix, InterfaceAlias, RouteMetric | Sort-Object DestinationPrefix
```

Two rows for `10.11.99.0/27` — one on the VPN at metric 1, one on the tablet's adapter
at metric 256 — is the signature.

Two fixes:

- **Disconnect the VPN.** Simplest, always works, costs you the VPN.
- **Add a more specific route** — a `/32` beats a `/27` regardless of metric, so this
  works while the VPN stays connected. Needs an elevated shell; `ActiveStore` keeps it
  non-persistent so it vanishes on reboot and changes nothing permanently:

  ```powershell
  # <ifIndex> is the NDIS adapter's ifIndex from §1
  New-NetRoute -DestinationPrefix 10.11.99.1/32 -InterfaceIndex <ifIndex> `
               -NextHop 0.0.0.0 -RouteMetric 1 -PolicyStore ActiveStore
  ```

  Some always-on VPN configurations monitor and remove added routes, and some block
  off-tunnel traffic outright. If the `/32` route does not stick or does not help,
  disconnect the VPN — do not keep fighting it.

## 3. The web interface toggle is off

Settings ▸ Storage ▸ **USB web interface**. It ships off, and firmware updates have
been observed turning it back off. This is the cause when the connection is *refused*
rather than timing out.

## 4. A proxy is intercepting the request

If `curl --noproxy '*' http://10.11.99.1/documents/` works but PowerShell does not, the
system proxy is eating it. PowerShell 7's `-NoProxy` fixes it and the scripts pass it
automatically; on PowerShell 5.1 there is no such switch — use PowerShell 7 for this,
or clear the proxy for the call.

## 5. Still nothing

`http://10.11.99.1/log.txt` returns the tablet's `xochitl` log if the server is up at
all — if *that* responds, the interface is running and the problem is the specific
request, not the transport.

Otherwise fall back to the cloud transport (`-Transport cloud`, see
[transports.md](transports.md)) and say clearly that the PDFs will be rmapi-rendered
rather than device-rendered.

---

# Other failures

## `pdf_to_pages.py` exits asking for PyMuPDF

```bash
python -m pip install pymupdf
```

It is a self-contained wheel — no Ghostscript, poppler, or ImageMagick needed. This is
why the script uses PyMuPDF rather than shelling out to `pdftoppm`.

## The export refuses because the name is ambiguous

Deliberate. Two notebooks in different folders can share a name, and quietly picking one
would silently summarise the wrong notes. Use the full path, or pass `-Id`.

## Rendering is taking minutes

Normal for a long notebook over USB — the tablet is doing the work on modest hardware.
The default timeout is 600 s. Do not lower it and then report a timeout as a failure.

## rmapi worked yesterday, fails today

reMarkable rolls out sync-protocol changes incrementally per account. Check for a newer
`ddvk/rmapi` release before concluding the account or the token is broken;
`RMAPI_FORCE_SCHEMA_VERSION=3` (or `4`) is the escape hatch.
