---
name: github-multi-account
description: 'Use this skill when one Windows machine works for several GitHub accounts (personal, employer, client) and a folder of repos must commit, push and run `gh` as its own account, or when commits, pushes, PRs or `gh` calls in a client folder come out as the wrong account. Covers per-folder git identity with includeIf, an isolated gh config dir per account, getting that dir into terminals (a direnv-style .envrc.ps1), T3 Code provider environments and Claude Code sessions (a SessionStart/CwdChanged hook writing GH_TOKEN to CLAUDE_ENV_FILE), and the traps: gh auth switch is global, a second-dir login clobbers the shared keyring slot, gh auth token ignores -u, and the PowerShell tool drops env-file paths.'
version: 1.0.0
---

# One machine, several GitHub accounts

Two separate tools pick the account, and they do it differently:

- **git** (commit author, push credentials) can be scoped per folder in global git config.
- **`gh`** (PRs, issues, API) has **one active account for the whole machine**. A folder setting
  only reaches it through an environment variable, and every kind of shell gets its environment
  differently. So `gh` is the half that goes wrong.

A wrong `gh` account rarely shows up as an auth error. A repo in the client's org returns a plain
`Not Found`, which reads like a missing repo.

## Check first: which half is wrong

Run inside a repo of the folder:

```bash
git config user.email; git config credential.https://github.com.username
printf 'protocol=https\nhost=github.com\n\n' | git credential fill | grep username
gh api user --jq .login
```

The first two lines are git and the last is `gh`. If git is right and `gh` is wrong, skip step 1.

## 1. git: includeIf per folder

In `~/.gitconfig`, with the credential helper set to `gh auth git-credential`:

```ini
[includeIf "gitdir/i:D:/<Client>/"]
	path = ~/.gitconfig-<client>
```

`~/.gitconfig-<client>`:

```ini
[user]
	email = <id>+<account>@users.noreply.github.com
[credential "https://github.com"]
	username = <account>
```

`gh auth git-credential` hands out the token for that username, so the account must also be logged
in to the **default** `gh` config as a non-active account. Run `gh auth login`, then
`gh auth switch -u <personal>` to switch back. Linked worktrees match too, because their gitdir lives under the
main repo's `.git`. **Never set `user.email` repo-locally** in a repo other people clone.

## 2. gh: an isolated config dir per account

Create `~/.gh-<client>` holding only the client account, stored in its own `hosts.yml`:

```bash
# Seed from the keyring token git already uses: no browser login needed
T=$(printf 'protocol=https\nhost=github.com\nusername=<account>\n\n' | git credential fill | sed -n 's/^password=//p')
printf '%s' "$T" | GH_CONFIG_DIR='C:\Users\<you>\.gh-<client>' gh auth login \
  --hostname github.com --git-protocol https --insecure-storage --with-token
gh auth switch -u <personal>          # REQUIRED: the login above clobbered the shared slot
gh api user --jq .login               # must print <personal> again
```

Without a keyring token, run an interactive `gh auth login --insecure-storage` with
`GH_CONFIG_DIR` set instead (add `--scopes project` if the account uses Projects v2), then do the
same `switch` and check.

## 3. Get the dir into every kind of shell

Each one needs its own mechanism, and none covers the others:

| Where `gh` runs | Mechanism |
|---|---|
| Your interactive pwsh | `<Client>\.envrc.ps1` with `$env:GH_CONFIG_DIR = "$env:USERPROFILE\.gh-<client>"`, loaded by a direnv-style walker in the pwsh profile that sources the nearest `.envrc.ps1` on every location change and unloads it on leaving |
| A T3 Code provider dedicated to the client (e.g. Copilot, see `t3-code-copilot`) | Add `GH_CONFIG_DIR` to the provider instance's `environment` list in `~/.t3/userdata/settings.json`. Agent shells do **not** load your pwsh profile |
| Claude Code sessions (any host) | `gh-identity.sh` in this folder, wired as a SessionStart **and** CwdChanged hook (below) |

Claude Code hook, in `~/.claude/settings.json`, under both `SessionStart` and `CwdChanged`:

```json
{ "hooks": [ { "type": "command", "command": "bash \"<path>/gh-identity.sh\"", "timeout": 10 } ] }
```

Edit the `MAP` array at the top of the script. It finds the repo's git common dir, so a worktree
outside the folder still matches, and writes `export GH_TOKEN=...` to `CLAUDE_ENV_FILE`. Claude
Code empties that file on every CwdChanged, so leaving the folder drops the token.

Why `GH_TOKEN` and not `GH_CONFIG_DIR` here: the PowerShell tool skips any env-file value
containing `/` or `\`. It also ignores the whole file if one line isn't a plain assignment. A
token has neither problem, so it reaches Bash and PowerShell alike.

**Do not** put `GH_TOKEN` in a Copilot provider's environment. It overrides Copilot's own login.
Use `GH_CONFIG_DIR` there.

## Verify

```bash
gh api user --jq .login                                   # outside: <personal>
GH_CONFIG_DIR='C:\Users\<you>\.gh-<client>' gh api user --jq .login   # <account>
```

For the hook, pipe a payload into the script:
`jq -nc --arg c 'D:\<Client>\<repo>' '{cwd:$c}' | CLAUDE_ENV_FILE=out.txt bash gh-identity.sh`.
`out.txt` should hold one `export GH_TOKEN=` line. Repeat with a path outside the folder: the file
should stay empty. For the end-to-end check, run a headless session in a client repo and have it run
`gh api user` from both the Bash and the PowerShell tool.

## Traps

- **`gh auth switch` is machine-wide.** It flips every running session and tool. Never use it to
  "be" the client account for a task.
- **A login into a separate `GH_CONFIG_DIR` still overwrites the default keyring slot** (seen on
  gh 2.74.1, `--with-token --insecure-storage`). Afterwards the default dir's `gh auth status` says
  `<personal>` while it actually sends the client's token. Always `switch` back and check with
  `gh api user`, not with `gh auth status`.
- **`--insecure-storage` is what isolates the dir.** Without it the token goes to the shared keyring
  and the dir is isolated in name only. For the same reason, **never run `gh auth refresh`** against
  the dir: it moves the token back to the keyring. Re-run the full `login` to change scopes.
- **`gh auth token -u <user>` ignores `-u`.** It returns the active account's token, so
  `GH_TOKEN=$(gh auth token -u x)` does not pin anything. Read the token from the isolated dir
  (`GH_CONFIG_DIR=... gh auth token`) or from `git credential fill` with a `username=` line.
- **Env-file values with slashes never reach PowerShell.** See step 3.
- `gh auth git-credential` honours `GH_TOKEN` too. That is harmless inside the folder, because it is
  the same account the includeIf picks.
