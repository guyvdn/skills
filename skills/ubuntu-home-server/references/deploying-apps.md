# Deploying apps

Part of the [ubuntu-home-server](../SKILL.md) skill. Placeholders (`<USER>`, `<SERVER_IP>`, …) are
listed there; the real values are in the private global `CLAUDE.md`.

Docker, and the shape every app on the box follows. Backups of `/srv` are in
[updates-backups.md](updates-backups.md).

## Docker

Install from Docker's own apt repo (`/etc/apt/keyrings/docker.asc` plus a deb822
`/etc/apt/sources.list.d/docker.sources`; it supports Ubuntu 26.04). Install `docker-ce`,
`docker-ce-cli`, `containerd.io`, `docker-buildx-plugin` and `docker-compose-plugin`. Write
`/etc/docker/daemon.json` **before** the first container starts:

```json
{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }
```

Give every app `restart: unless-stopped`, because unattended-upgrades reboots the box at
05:00 when an update requires it. Docker's repo isn't among unattended-upgrades' origins,
so Docker itself only updates when you upgrade it by hand.

## Deploying an app

Each app gets the same shape, so backups, reboots and secrets need no per-app thought:

```
/srv/<app>/
  compose.yml        # restart: unless-stopped; bind mounts only, no named volumes
  .env               # secrets: root:root 600, never on a share or in git
  data/              # bind-mounted state (SQLite etc.)
  src/               # source, when the image is built here
  backup-pre.sh      # only if data/ can't be copied while live
```

- **Build on the box.** It's x86_64, so an image built for an arm64 Pi (`platform:
  linux/arm64`) has to be rebuilt anyway. Building here needs no cross-compile, no image
  tar and no registry. Ship committed source and build:
  `git archive HEAD | ssh <box> 'sudo tar -x -C /srv/<app>/src'`, then
  `sudo docker compose -f /srv/<app>/compose.yml up -d --build`. The box needs no git
  credentials, and uncommitted changes can't leak into a deploy.
  - **From Windows**, archive with `git -c core.autocrlf=false archive …`: with
    `autocrlf=true`, `git archive` emits the CRLF working-tree form, which breaks shell
    scripts in the image. PowerShell also can't `<`-redirect a file into `ssh`, so
    `git archive -o x.tar.gz`, `scp` it to `/tmp`, then untar into a fresh `src.new` and
    swap it in, so files deleted from the repo don't linger in the build context.
- **Docker as sudo.** The login user isn't in the `docker` group (that group is
  root-equivalent); with NOPASSWD sudo, `ssh <box> 'sudo docker …'` works unattended.
- **Every app defines a healthcheck**, in `compose.yml` (`healthcheck:`) or in the
  Dockerfile (`HEALTHCHECK`). Beszel's container "Health" column shows Docker's
  healthcheck status, and a container without one shows "None"
  (`docker inspect -f '{{json .State.Health}}' <container>` returns `null`). For a static
  `nginx:alpine` site (it ships `wget` and `curl`):
  ```yaml
  healthcheck:
    test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1/photos.json"]
    interval: 30s
    timeout: 5s
    retries: 3
    start_period: 10s
  ```
  - **Probe a content file, not `/`**, so an empty bind mount also counts as unhealthy.
  - **Use `127.0.0.1`, not `localhost`:** on Alpine, `localhost` can resolve to `::1`, where
    the server may not listen.
  - After a deploy, `sudo docker ps` should show `(healthy)` once `start_period` has passed.
- **SQLite:** live `*.db*` files must not be backed up as-is, so a `backup-pre.sh` writes a
  consistent copy (`VACUUM INTO`, or the `sqlite3` backup API) into a path under
  `/srv/<app>` that the backup does include, renamed into place only once complete.
  - **Add the app's live database to `backup-run`'s excludes yourself**
    (`--exclude "/srv/<app>/data/*.db*"`). The exclude list is per path, not a global
    `*.db*` rule, so without that line restic also stores a possibly torn live copy.
  - **Run the copy with the host's `python3`** (it ships SQLite) against the bind-mounted
    file rather than `docker exec`: it then also works while the app is stopped, which is
    exactly when a restore or a cutover needs it.
  - **A failing hook aborts the whole nightly backup** (`backup-run` is `set -e`), for
    every app, and the failure is reported like any other. Loud is right, but keep hooks
    simple and fail only on a real problem.
- **Exclude bulk content that lives elsewhere.** A photo folder whose originals are in the
  cloud and on the dev PC only fills the card and slows the job; add an
  `--exclude "/srv/<app>/site/photos"` and restore by redeploying. If it already went into a
  snapshot, `restic forget <id> --prune` reclaims the space; with the monthly retention it
  would otherwise sit there for six months.
- **Static sites:** a small `nginx:alpine` container with the site bind-mounted read-only.
  Because `/srv/<app>` belongs to that app alone, mirroring with deletes is safe here,
  unlike a folder shared with other projects. If the content isn't in git (e.g. a gitignored
  photo folder), `git archive` can't ship it: mirror the working tree instead. Windows has
  no rsync, so diff a local file list against `find <dir> -type f -printf '%P\t%s\t%T@\n'`
  on the box by size + whole-second mtime, pipe the changed files through Windows'
  `%SystemRoot%\System32\tar.exe -c -T <list>` into `ssh … 'sudo tar -x --no-same-owner'`
  (call it by absolute path: Git Bash's GNU tar comes first on `PATH`), then delete what's
  gone. Guard the delete step: refuse to remove a large share of the server's files, so an
  empty source folder can't wipe the site.
- **Retiring the old host:** before deleting an app's files from where it used to run,
  search the consumers' config for the old **host:port**, not only the URL path. Another
  server or a cast automation may be fetching the same files on a port you didn't know about.
- **Ports:** record each one in the private `CLAUDE.md` port table before using it. An app
  gets no HA sensors of its own from Glances, only a share of the Docker totals (see
  [monitoring.md](monitoring.md)).
