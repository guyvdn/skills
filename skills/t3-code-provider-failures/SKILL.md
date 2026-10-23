---
name: t3-code-provider-failures
description: 'Use this skill when T3 Code shows "Provider turn failed", a Claude thread in T3 Code never answers after a message is sent, or thread titles and branch names stop being generated — especially right after restarting T3 Code or the PC, or after a Claude Code update. Covers reading T3 Code''s own logs to find which Claude Code executable a thread actually ran, the stale npm-installed Claude Code it silently falls back to, and why `npm uninstall -g` reports "up to date" without removing it.'
version: 1.0.0
---

# T3 Code: "Provider turn failed"

T3 Code drives Claude through the Claude Agent SDK, which spawns a Claude Code executable for
each thread. When that spawn picks the wrong executable, the turn fails or hangs with no reply,
and the UI shows only **Provider turn failed**.

## Where the evidence is

All under `%USERPROFILE%\.t3\userdata\logs\`:

| File | What it holds |
|---|---|
| `provider\events.<thread-id>.log` | One per thread: every SDK message in and out, timestamped (UTC) |
| `server.trace.ndjson` (+ `.1`…`.9`, rotated at ~10 MB) | Server spans; failures have `"exit":{"_tag":"Failure","cause":"..."}` |

The two checks that find the cause:

```bash
cd ~/.t3/userdata/logs
# 1. Which executable did each thread's sessions use?
grep -ho '"pathToClaudeCodeExecutable":"[^"]*"' provider/events.*.log | sort | uniq -c
# 2. What failed, and why?
grep -h '"_tag":"Failure"' server.trace.ndjson server.trace.ndjson.1 \
  | grep -o '"cause":".\{0,300\}' | sort | uniq -c
```

The thread that failed shows a `query.open` and a `prompt.offer` at the end of its provider
log, and **nothing after it**. The `query.open` payload names the executable.

## Cause: fallback to a stale npm install

`pathToClaudeCodeExecutable` should be the native install,
`%USERPROFILE%\.local\bin\claude.exe`. If it shows
`...\node_modules\@anthropic-ai\claude-code\cli.js` instead, T3 Code fell back to an old
npm-installed Claude Code. That version usually cannot serve current models or SDK options, so
the turn dies.

**What triggers the fallback:** T3 Code resolves the executable when a session starts. If
`claude.exe` is missing at that moment, it takes the next Claude it can find. The native
auto-updater replaces `claude.exe` in place, so a T3 Code session that starts during an update
finds no exe. Signs of this:

- `claude.exe`'s modified time is a minute or two after the failure.
- The server trace has `generateThreadTitle` / `generateBranchName` failures with
  `Claude CLI command failed: The system cannot find the path specified.` at the same time.

Once the update finishes, the exe is back, so the fault comes and goes. As long as the stale
copy exists, every update that overlaps a session start can trigger it again.

## Fix: remove the stale copy

Check what `claude` resolves to and how old each copy is:

```powershell
Get-Command claude -All | Select-Object Source
& "$env:USERPROFILE\.local\bin\claude.exe" --version
```

Find which npm folder holds the old one: the `claude.cmd` shim names the `cli.js` it runs.
Then uninstall it **from that folder**:

```powershell
npm uninstall -g --prefix "$env:APPDATA\npm" @anthropic-ai/claude-code
```

**Trap:** a plain `npm uninstall -g @anthropic-ai/claude-code` prints `up to date` and removes
nothing when the copy sits under an *earlier* global prefix. That happens after a switch to a
Node version manager (nvm-windows / nvm4w moves the prefix to its own folder, e.g.
`C:\nvm4w\nodejs`). Check with `npm prefix -g`. `--prefix` points npm at the old folder.

Verify that `Get-Command claude -All` lists only `.local\bin\claude.exe`, then restart T3 Code
and resend the message that failed.

Removing the fallback does not stop the update race, but a session that starts mid-update now
fails with "not found" instead of quietly running an outdated Claude, and retrying works.

## Ruled out — not the cause

These also appear as failures in the server trace on a healthy machine. Ignore them:

- `ProcessSpawnError` for `glab`, `tea`, `fj`, `jj`, `cafe`; `TailscaleCommandSpawnError`;
  `CodexAppServerSpawnError` — T3 Code probing for optional tools that are not installed.
- `BitbucketResponseError ... HTTP 401` — Bitbucket integration not signed in.
- `ProjectionStoreThreadNotFoundError` for a brand-new thread id — a lookup before the thread
  is created.
