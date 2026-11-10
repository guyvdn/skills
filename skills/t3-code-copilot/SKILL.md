---
name: t3-code-copilot
description: 'Use this skill when someone wants to use GitHub Copilot CLI inside T3 Code, add Copilot (or any other ACP agent) as a T3 Code provider, or run Copilot CLI under a second GitHub account (a work, client or Enterprise Managed User account) without disturbing the account `gh` or another Copilot login uses. Covers adding Copilot as a local ACP command, the provider instance shape in T3''s settings.json, isolating the login with COPILOT_HOME, the token variables that silently override it, what the provider''s "Available" status and "Sign in" button do and do not mean, and how to verify which account a thread really uses.'
version: 1.0.0
---

# GitHub Copilot CLI in T3 Code, on a chosen account

T3 Code has no built-in Copilot provider, but it runs any **ACP** (Agent Client Protocol) agent,
and Copilot CLI is one: `copilot --acp` starts it as an ACP server. T3's own docs cover this in
`docs/user/providers-acp.md` of the T3 Code repo, not in the README. Read that first if the UI
has moved.

## Copilot CLI login: what you need to know

- Copilot CLI has **its own OAuth login**. It does **not** reuse `gh`'s active account. The list
  of signed-in accounts lives in `<COPILOT_HOME>/config.json` (default `~/.copilot`). The token
  goes in the OS credential store, keyed by host and login (on Windows, Credential Manager
  targets like `https://github.com:<login>.copilot-cli`). It goes in a plain-text file under
  the home only when there is no credential store.
- **`GH_TOKEN`, `GITHUB_TOKEN` or `COPILOT_GITHUB_TOKEN` override the stored login.** If one is
  set in the environment T3 runs in, the agent uses that token's account, whatever you logged in as.
- `COPILOT_HOME` moves the config and state directory (account list, logs, session state). One
  directory per account is the cleanest isolation: each home names its own account, so nothing
  else picks that login up by accident.
- The account needs a **Copilot seat** (personal or assigned by its org). Without one, login
  succeeds and every request fails with a no-access error.
- Data-residency tenants (`<tenant>.ghe.com`): log in with
  `copilot login --host https://<tenant>.ghe.com`. **Also** add `COPILOT_GH_HOST=<tenant>.ghe.com`
  to the T3 provider instance's environment, next to `COPILOT_HOME`. It affects Copilot only and
  leaves `gh` alone. It is unverified whether a `--host` login remembers its host on its own, and
  without the variable the agent T3 launches may default to github.com.
- In an interactive `copilot` session, `/user` manages the signed-in accounts.

## Setup

### 1. Check the starting state (read-only)

```powershell
copilot --version; copilot --help | Select-String -- '--acp'
"GH_TOKEN=$([bool]$env:GH_TOKEN) GITHUB_TOKEN=$([bool]$env:GITHUB_TOKEN) COPILOT_GITHUB_TOKEN=$([bool]$env:COPILOT_GITHUB_TOKEN)"
```

The CLI must support `--acp`. All three token variables should be `False`.

### 2. Add the provider instance

**Preferred: the UI.** **Settings → Providers → Add provider → Show more → Local ACP command**.

| Field | Value |
|---|---|
| Executable | Full, literal path to `copilot.exe`. For winget: `C:\Users\<you>\AppData\Local\Microsoft\WinGet\Links\copilot.exe` |
| Arguments | `--acp`, one argument per row |
| Environment | `COPILOT_HOME` = a dedicated folder, e.g. `C:\Users\<you>\.copilot-<account>` |
| Display name | Something that names the account, e.g. `Copilot (Work)` |

T3 launches the executable **directly, without a shell**: no `~`, no `%VAR%`, no `$env:`
expansion in the path, the arguments or the environment values. Write them out in full.

The alternative is **ACP Registry** (same dialog, search "GitHub Copilot"): T3 then downloads and
manages its own copy of the CLI under `~/.t3/tools/`. A Registry instance also has an
**Executable override** that points it at a local binary instead. Either way works. The local
command is the simpler choice if you already keep a Copilot CLI install up to date.

**Scripted alternative: edit `settings.json`.** The provider list lives in
`~/.t3/userdata/settings.json` under `providerInstances`. Back it up first. This shape was read
from T3's source and accepted by T3 0.1.8, which kept the entry and listed the provider. Restart T3
if it doesn't appear.

```powershell
$p = "$HOME\.t3\userdata\settings.json"; Copy-Item $p "$p.bak-$(Get-Date -f yyyyMMdd)"
$s = Get-Content $p -Raw | ConvertFrom-Json -AsHashtable
if (-not $s.providerInstances) { $s.providerInstances = [ordered]@{} }
$s.providerInstances['copilotWork'] = [ordered]@{
  driver = 'acpRegistry'; enabled = $true; displayName = 'Copilot (Work)'
  config = [ordered]@{ source = 'local'
    commandPath = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\copilot.exe"; commandArgs = @('--acp') }
  environment = @([ordered]@{ name = 'COPILOT_HOME'; value = "$HOME\.copilot-work"; sensitive = $false })
}
$s | ConvertTo-Json -Depth 20 | Set-Content $p -Encoding utf8NoBOM
New-Item -ItemType Directory -Force "$HOME\.copilot-work" | Out-Null
```

`driver` is `acpRegistry` for a Registry agent **and** for a local command.
`config.source: "local"` marks a local command. PowerShell expands the variables above before it
writes the file; T3 never expands them itself. The JSON round trip can reformat date strings, and
the backup covers that.

### 3. Log in to that home, as the right account

The user has to do this, because they pick the account in the browser. `--device-code` prints a
code they can enter in whichever browser window is signed in as the target account, which avoids
the browser silently authorizing the default account:

```bash
COPILOT_HOME=/c/Users/<you>/.copilot-work copilot login --device-code
```

```powershell
$env:COPILOT_HOME = "$HOME\.copilot-work"; copilot login --device-code; Remove-Item Env:COPILOT_HOME
```

Without the `Remove-Item`, every later `copilot` run in that terminal would use the work home.
A successful login ends with `Signed in successfully as <login>.`

### 4. Verify

```powershell
Get-Content "$HOME\.copilot-work\config.json"   # loggedInUsers / lastLoggedInUser = the target login
Get-Content "$HOME\.copilot\config.json"        # the default home: unchanged
```

## What the provider card does and does not tell you

- **Status "Available"** appeared before any thread had run, so it doesn't prove the login or the
  seat. Treat it as "T3 can launch the command".
- The **Account → Sign in** button was still showing after a successful login in step 3, so it
  isn't a "not logged in" warning. Per T3's docs, an instance's environment applies to both
  sign-in and chat, so the button writes to the same `COPILOT_HOME`. You don't need it if step 3
  succeeded.
- The real test is **a thread**: start one with the new provider and send a trivial prompt. If it
  answers, the model picker lists that account's models and you're done. An authentication
  error means the login didn't land in this home (check for a token variable). An access error
  most likely means the account has no Copilot seat.
- Before that first thread, T3's logs didn't mention the new instance, so they can't confirm
  anything until a thread has run.

## Known issue

A Copilot run can stay at **Working** while a background shell it started is still running:
https://github.com/pingdotgg/t3code/issues/27301
