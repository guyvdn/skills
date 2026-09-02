---
name: claude-code-sessions
description: 'Identify the Claude Code sessions running on this machine — map each one''s friendly name to its session id, working directory and pid. Use when the user asks which session this is, what their session id is, which other Claude sessions are running, or wants one session told something / handed work ("tell the other session", "inform the session in D:\foo"); when a user supplies a session UUID that ListAgents does not show; and before resuming or attaching to a session by id. NOT for finding a past conversation by topic, branch or PR — that is a transcript search, not this registry.'
version: 1.0.0
compatibility: 'Windows, PowerShell 5.1+ or PowerShell 7+. Reads only the local session registry, so it sees no cloud or Remote Control sessions.'
---

# Claude Code sessions on this machine

Answers "which session is this, what else is running, and what do I call it".

## The registry

Claude Code writes one file per live session:

```
<config>/sessions/<pid>.json
```

where `<config>` is `$env:CLAUDE_CONFIG_DIR` if set, otherwise `~/.claude`. Each file holds
the session's **friendly name**, `sessionId`, `cwd`, `kind`, `pid`, `startedAt` and `version`.

**This is the only place the name is joined to the id.** Nothing else exposes both:

| Source | Gives you | Missing |
| --- | --- | --- |
| `/status` | model, context, config | the name **and** the id |
| The status line | whatever its script prints | the name is not in the JSON it receives |
| An agent's `ListAgents` | names, plus a short opaque ref | the session id and the cwd |
| `<config>/projects/<slug>/*.jsonl` | session ids (as filenames) | the name |

## Run it

```powershell
# live sessions, as a table
powershell -ExecutionPolicy Bypass -File skills/claude-code-sessions/scripts/Get-ClaudeSessions.ps1

# structured, for an agent or a script
powershell -ExecutionPolicy Bypass -File skills/claude-code-sessions/scripts/Get-ClaudeSessions.ps1 -Json

# include crashed sessions that left a registry file behind
powershell -ExecutionPolicy Bypass -File skills/claude-code-sessions/scripts/Get-ClaudeSessions.ps1 -IncludeStale
```

Output:

```
Name        SessionId                            Cwd                Kind          Pid Alive IsHere
----        ---------                            ---                ----          --- ----- ------
infra-a0    0f3c1d84-2b55-4a10-9e77-1c9d4a6b2e30 D:\work\infra     interactive 21420  True   True
webapp-f0   7ab29e51-6c04-4d8e-b3f2-5e8a1c7d9042 D:\work\webapp    interactive 21244  True  False
```

`IsHere` marks the row whose `cwd` is the current directory — usually the session you are in.

## Gotchas

- **The name is the address; the id mostly is not.** Cross-session messaging between Claude
  sessions is addressed by **name** (`infra-a0`). A session UUID does not resolve — an
  agent's `ListAgents` shows names and a short opaque ref, and that ref is **not** derived from
  the session id, so a UUID and a listing cannot be matched by eye. When telling an agent about
  another session, give it the **name or the working directory**. Run this script if you only
  have a UUID.

- **The files are keyed by pid, and pids get reused.** A crashed session can leave its file
  behind, so "the pid exists" is not "the session is alive". The script also compares the
  process's real creation time against the `procStart` FILETIME in the file, and reports a
  reused pid as stale. Do not simplify that check away — without it a dead session reads as
  live as soon as something else takes its pid.

- **One registry per config profile.** `$env:CLAUDE_CONFIG_DIR` selects it. If you run more than
  one profile (e.g. `~/.claude` and a second one for client work), a session started under the other
  profile does **not** appear — pass `-ConfigDir` to look there.

- **Local only.** Cloud sessions and Remote Control sessions on other machines write nothing
  here. An empty result means "none on this machine", never "none at all".

- **Do not put this in the status line.** Tried and reverted: rendering own-name-plus-peers works
  fine with two sessions and grows unbounded past that, pushing the rest of the status line off
  the terminal. The status line JSON also carries `session_id` but **not** the name, so it would
  need this same registry lookup on every render. A command you run when you need it is the right
  shape.

## Related lookups

Once you have a session id:

```powershell
# resume it
claude --resume <sessionId>

# its transcript - <slug> is the cwd with every non-alphanumeric character replaced by '-',
# e.g. D:\work\infra -> D--work-infra
Get-ChildItem "$env:USERPROFILE\.claude\projects\<slug>\<sessionId>.jsonl"
```

`claude agents` lists background sessions, which is a different set from this registry.

To find a *past* conversation by what it was about — a PR, a branch, a file, a topic — search the
transcripts under `<config>/projects/`; this registry only knows about sessions that are running.
