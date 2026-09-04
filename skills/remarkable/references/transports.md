# The two transports

## USB web interface — preferred

A small HTTP server the tablet itself runs, on a link-local USB network. No auth, no
account, no subscription, no third-party binary. **Enable it on the tablet:**
Settings ▸ Storage ▸ *USB web interface*. It is off by default and some firmware
updates turn it back off.

Host gets an address in `10.11.99.0/27` (usually `.2`, sometimes higher); the tablet is
always `10.11.99.1`.

### Endpoints

| Method | Path | Returns |
|---|---|---|
| GET/POST | `/documents/` | JSON array — root folder contents |
| GET/POST | `/documents/{guid}` | JSON array — that folder's contents |
| GET | `/download/{guid}/pdf` | rendered PDF of the document |
| GET | `/download/{guid}/rmdoc` | raw notebook archive (software 3.9+) |
| GET | `/thumbnail/{guid}` | PNG of the last-opened page only |
| POST | `/upload` | multipart upload (not used by this skill) |
| GET | `/log.txt` | the tablet's `xochitl` log — useful when something is wrong |

### Listing fields

Exactly these, verified against software 3.x:

```json
{ "ID": "…guid…", "VisibleName": "Architecture notes",
  "VissibleName": "Architecture notes", "Type": "DocumentType",
  "Parent": "…guid…", "fileType": "notebook",
  "ModifiedClient": "2026-08-30T09:14:22Z", "CurrentPage": 11,
  "Bookmarked": false }
```

- `Type` is `DocumentType` or `CollectionType` (a folder). There is no recursive
  listing — walk it folder by folder.
- **Both spellings of the name are present.** `VissibleName` is the historical
  firmware field and is always there; `VisibleName` was added later. Read either.
- **There is no `pageCount`.** `CurrentPage` is the page the user last had open,
  not a count. The only reliable page count comes from the exported PDF.
- `fileType` distinguishes `notebook` from an imported `pdf` / `epub`.

### The charset lie — fix this or every accented title is corrupted

The server sends `Content-Type: application/json; charset=ISO-8859-1` and then
puts **UTF-8 bytes in the body**. Any client that believes the header mangles
every non-ASCII character: a notebook called `Sync Analyse–Dev–Test` comes back
as `Sync Analyseâ€“Devâ€“Test`, and the corruption then propagates into filenames.

`Invoke-RestMethod` believes the header. Read the raw bytes and decode them as
UTF-8 yourself — `Get-RemarkableDocs.ps1` does this in `Invoke-RmWeb`. The
mangling is easy to miss because it only shows up on notebooks whose titles
happen to contain an accent, a dash, or a quote.

### Names are free text — sanitise before they become filenames

Notebook titles routinely contain characters Windows cannot store: `DP3/GHC Sync`
and `UI/UX` both appeared in a single real folder. Map the invalid set to `-`
before writing anything to disk, and keep the original title in the document's
own front matter so nothing is lost.

### Why the PDF from here is the good one

`/download/{guid}/pdf` is rendered by the tablet, with the same renderer that draws the
screen. That means correct pen widths and pressure, highlighter transparency, Paper Pro
colour, template/grid backgrounds, and — for an annotated import — the original PDF with
the ink composited on top. No third-party renderer reproduces all of that.

### Gotchas

- **Corporate proxies.** `Invoke-RestMethod` honours the system proxy, which will
  happily try to resolve `10.11.99.1` upstream and fail. PowerShell 7's `-NoProxy`
  avoids this; the scripts use it when available. On 5.1, unset the proxy for the call.
- **Rendering is slow.** A long notebook can take minutes to produce a PDF. A timeout
  is not the same as a failure.
- **Sleep.** The interface stops answering when the tablet sleeps. Tap the screen.

## Cloud via rmapi — fallback

Use when the tablet is not at hand. Requires a reMarkable **Connect** subscription for
cloud sync to be populated at all.

### Setup, once

```powershell
go install github.com/ddvk/rmapi@latest    # lands in %USERPROFILE%\go\bin
```

`ddvk/rmapi` is the maintained community fork; the original `juruen/rmapi` is archived.

Authentication is interactive and cannot be automated — it wants a one-time code:

1. Open <https://my.remarkable.com/device/browser/connect> and copy the 8-character code.
   Each code is single-use and dies on the first attempt, successful or not.
2. Run `rmapi` once and paste it. The device token is stored at `~/.rmapi`
   (override with `RMAPI_CONFIG`).

Because it is interactive, hand this to the user to run themselves rather than trying
to drive it from a tool call.

### Commands the scripts use

```
rmapi find --json / "."      # whole tree as JSON
rmapi geta "/path/to/doc"    # annotated PDF, written into the cwd
```

`geta` chooses its own output filename, so `Export-RemarkableDoc.ps1` runs it in an
empty temp directory and moves whatever PDF appears.

### Where it is worse

`geta` rasterises strokes with rmapi's own renderer. Expect: template backgrounds
missing or approximated, some pen styles flattened to a uniform stroke, and
highlighter handled crudely. Fine for transcription, wrong if the user wants a
faithful visual copy. Say which transport produced a PDF when the fidelity matters.

Also note reMarkable has been rolling out a newer sync protocol incrementally; if
`rmapi` starts failing where it used to work, check for an upstream release before
assuming the account is broken. `RMAPI_FORCE_SCHEMA_VERSION` (3 or 4) is the escape
hatch.

## Third transport: a folder of exports

If neither works, the user can export from the tablet or the desktop app by hand and
drop files in a folder. Steps 3–5 of the skill work unchanged on any PDF.
