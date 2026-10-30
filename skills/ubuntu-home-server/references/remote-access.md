# Remote access & agent sessions

Part of the [ubuntu-home-server](../SKILL.md) skill. Placeholders (`<USER>`, `<SERVER_IP>`, …) are
listed there; the real values are in the private global `CLAUDE.md`.

Tailscale instead of port forwarding, Tailscale Serve for HTTPS per app, and T3 Code +
Claude Code sessions run on the box from the phone.

## Reaching the apps from outside the LAN (Tailscale)

To use an app on the phone away from home, don't forward a router port, even with the
router's dynamic DNS. That puts the app on the public internet: a plain-HTTP login, constant
scanning, and every framework CVE becomes urgent, on the box that also holds the backups.
Use Tailscale instead. Nothing opens on the router, and only your own signed-in devices can
connect.

```bash
. /etc/os-release   # Tailscale publishes a repo per Ubuntu codename, new releases included
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$VERSION_CODENAME.noarmor.gpg \
  | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$VERSION_CODENAME.tailscale-keyring.list \
  | sudo tee /etc/apt/sources.list.d/tailscale.list
sudo apt-get update && sudo apt-get install -y tailscale
sudo tailscale up --hostname=<name> --timeout=8s   # prints a login URL, then times out
sudo tailscale status                              # shows the same URL until someone approves
```

- **Login over SSH:** `tailscale up` blocks until the login is approved. With `--timeout` it
  prints the URL and returns, and the pending login survives. The human opens the URL.
- **Disable key expiry** for the server in the admin console (machine's ⋯ menu), or it
  drops off the tailnet after 180 days. `tailscale status --json` shows `KeyExpiry` as null
  once it's off.
- **Keep it patched.** Its repo isn't in unattended-upgrades' origins. Add
  `Unattended-Upgrade::Origins-Pattern:: "origin=Tailscale,codename=${distro_codename}";` in
  its own file (e.g. `53unattended-upgrades-tailscale`), and check it with the dry run's
  "Allowed origins".
- **On the phone:** install the app with the same account and accept the VPN prompt. Only
  tailnet traffic goes through it (no exit node), so the rest of the phone's traffic is
  unchanged. With MagicDNS, `http://<name>:<port>` works. Test with WiFi off.
- Apps need no change. Docker's published ports listen on all interfaces, the tailnet one
  included.

### Coding-agent sessions from the phone (T3 Code + Claude Code)

T3 Code is a web UI for Claude Code/Codex sessions. On the server, reached over Tailscale,
it lets the phone start and follow agent sessions while the dev PC is off.

- **Run it as a separate user without sudo or the `docker` group.** The admin user has
  NOPASSWD sudo, and docker group membership is root by another name. An agent session
  there could otherwise change anything on a box that holds the backups and live apps.
  The cost is that sessions can't deploy, so deploys stay on the dev PC.
  ```bash
  sudo useradd --create-home --shell /bin/bash claude && sudo chmod 750 /home/claude
  sudo loginctl enable-linger claude      # its user services run with nobody logged in
  sudo -iu claude bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
  sudo -iu claude bash -c 'curl -fsSL https://t3.codes/install.sh | sh'
  ```
  Auto mode refuses to create the user or pipe installers to a shell on Claude's behalf.
  Put these lines in a script, copy it over and have the human run it with `!`.
- **Claude login needs a TTY.** The human runs, in their own terminal,
  `ssh -t <admin>@<server> "sudo -iu claude /home/claude/.local/bin/claude"`. Give the full
  path: `~` would expand to the admin's home before sudo runs. Check afterwards with
  `claude -p "reply with just OK"`.
- **Service:** run `t3 service install` as the user, with
  `XDG_RUNTIME_DIR=/run/user/<uid>` and `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus`,
  because `sudo -iu` doesn't set them. It creates a systemd *user* unit `t3code.service` on
  127.0.0.1:3773.
- **Publish it tailnet-only, as root:** `sudo tailscale serve --bg --https=443
  http://127.0.0.1:3773`, after enabling HTTPS certificates in the tailnet's DNS settings.
  That way the agent user doesn't need to be a Tailscale operator. `tailscale serve status`
  must say "(tailnet only)", which means Funnel is off.
- **More apps on the same name get their own HTTPS port**, e.g.
  `sudo tailscale serve --bg --https=8443 http://127.0.0.1:<app-port>`. Not a path such as
  `/app` (most apps aren't built for a URL prefix), and not the app's own port number
  (Docker already binds it on every interface, the tailnet IP included). `--bg` persists in
  tailscaled's state across reboots. A real HTTPS origin is also what lets Chrome on
  Android install a web app with a manifest as an app instead of a browser shortcut.
- **Pairing:** `t3 pair --tailscale --ttl 10m --label phone` prints a one-time QR code and
  link on the `ts.net` name. Have the human run it, so the QR code renders in their
  terminal. Paired sessions expire after 30 days. Manage them with
  `t3 auth session list|revoke` and `t3 auth pairing list|revoke`.
- **Give the agent user its own `~/.claude/CLAUDE.md`.** The dev PC's global instructions
  don't exist there, so without one a session doesn't know it's on the server, that it has
  no sudo, that it mustn't deploy or take the live apps' ports, or that `D:\…` paths in a
  repo's docs don't apply. Keep it short: constraints, git/token rules, secrets, backup
  excludes, one line per cloned project.
- **Backups:** exclude what can be downloaded again: `~/.t3/runtime` and
  `~/.local/share/claude` (~570 MB of binaries that grow with every update), and once
  projects are cloned, `**/node_modules`, `**/.next`, a per-user Node under `~/.local`, and
  the pnpm store. One cloned Next.js project took the home from 0.6 to 1.9 GB, and 40 MB
  of it was worth keeping. Prove the patterns with `restic backup --dry-run <home>
  --exclude …` (`-q` and `-vv` can't be combined). Keep the rest: agent state, `.env`
  files, unpushed work.
- **T3's "Add to another machine" dialog** clones a local project onto the server and can
  copy git-ignored files along. Pick HTTPS (the token), take only the `.env` file, then
  fix its Windows paths and `chmod 600` it (it arrives 664).
- **GitHub access:** Claude can't create a token, but it can open the form pre-filled
  (`https://github.com/settings/personal-access-tokens/new?name=…&target_name=<owner>&expires_in=90&contents=write&pull_requests=write`).
  Repository selection can't be pre-filled, so the human picks it. They copy the token
  and Claude sends it from the clipboard straight to the agent user's
  `~/.git-credentials` (600, `credential.helper store`) without printing it:
  `"https://<user>:$t@github.com" | ssh … 'sudo -u claude sh -c "umask 077; cat > /home/claude/.git-credentials"'`.
  Check the prefix (`github_pat_`) before sending. **PowerShell pipes to native commands
  with CRLF**, so the line ends in `\r`, the host no longer matches `github.com`, and git
  falls back to a prompt ("could not read Username… terminal prompts disabled"). Strip it
  on the box with `sed -i 's/\r$//'`. Verify with `git ls-remote` against a **private**
  repo: a public one succeeds without any credentials and proves nothing. For anything multi-line as the agent user, copy a script over and
  run `sudo -iu claude bash script.sh`. `sudo -iu … bash -c "…"` mangles newlines and
  quoting.
- **`gh` for the agent user:** without it, a session opens and merges PRs through raw API
  calls. Install from GitHub's own apt repo (`cli.github.com/packages`, keyring in
  `/etc/apt/keyrings`), not Ubuntu's `gh`, which is frozen per release. Like the Docker and
  Tailscale repos, it isn't in unattended-upgrades' allowed origins. Log it in from the
  token already in `~/.git-credentials`, so nothing is pasted twice:
  `sed -n 's#^https://[^:]*:\([^@]*\)@github\.com\r\?$#\1#p' ~/.git-credentials | gh auth login --git-protocol https --insecure-storage --with-token`.
  There's no keyring on a headless box, so the token is stored in `~/.config/gh/hosts.yml`.
  A token renewal now means updating both files. Auto mode
  refuses this login as persistence, so the human runs it.
