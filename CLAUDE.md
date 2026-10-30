# CLAUDE.md

Context for Claude Code working in this repo. Read this first every session.

## What this project is

A single Docker image that runs **ITFlow** (open-source MSP platform: client assets,
documentation, passwords, tickets, invoicing) on a **DigitalOcean MicroVM**, reached
privately over **Tailscale**. Owner: Adrian, who runs a small MSP (one client now,
a few more planned). The goal is cheap, pay-per-use hosting: the MicroVM bills per
second only while running and pauses when idle.

## Working rules (important)

- **Check every command's side effects before running or suggesting it.** Treat each
  command as if it runs immediately and any irreversible result must be dealt with.
  Say what a command changes, and flag anything destructive, billable, or permanent.
- **Always ask before:** `doctl` commands that create, delete, resume, or change
  anything; `git push`; deleting registry tags or packages; changing package
  visibility; anything touching real client data. Read-only commands
  (`doctl ... get/list`, `docker logs`, `cat`, `git status`) are fine.
- Never put secrets in the image, the Dockerfile, the repo, or MicroVM env vars.
  Secrets are generated at runtime on the VM (see entrypoint).
- Don't use Bright Data tools without asking first. Use normal web search.
- Prefer small, verifiable changes. After editing shell scripts, run
  `bash -n` and `shellcheck` on them.

## Repo layout

```
.github/workflows/build-image.yml   GitHub Actions: builds linux/amd64 image, pushes to ghcr.io
.gitattributes                      Forces LF line endings (see "Line endings" below)
.gitignore                          Ignores Windows *:Zone.Identifier files
docker build/                       Build context (note the space in the folder name; quote it)
  Dockerfile                        Debian 12 + Apache/PHP + MariaDB + Tailscale + supervisor
  entrypoint.sh                     First-boot init, then exec supervisord
  supervisord-itflow.conf           Runs mariadb, apache, cron, tailscaled
  apache-itflow.conf                Vhost for /var/www/itflow; blocks /.git
  itflow.cron                       ITFlow cron.php every minute; hourly backup check
  itflow-backup.sh                  Daily backup (DB + uploads + config.php), 14-day retention
CLAUDE.md                           This file
```

## Development environment

- Workstation: Windows with **WSL 2 running Debian**. All work happens inside Debian.
- Repo lives at `~/projects/ITFlow_Docker_MicroVM` (Linux filesystem, never `/mnt/c/...`).
- Editor: VS Code on Windows, connected via the WSL extension (bottom-left shows
  "WSL: Debian"). Claude Code runs through the VS Code extension in that window.
- Docker: Docker Desktop with WSL integration enabled for Debian.
- Tools in Debian: `git`, `gh` (GitHub CLI, used for auth and PRs), `doctl`
  (DigitalOcean CLI, token in `~/.config/doctl`; it can create and destroy billable
  resources, so every doctl write needs Adrian's approval).

## Git workflow

- **Pre-production (now):** commit directly to `main`. Nothing is in use yet, so
  branches add steps without protecting anything. Every push to `main` that touches
  `docker build/` or the workflow triggers a real image build (harmless, new tag).
- **Once ITFlow holds real client data:** switch to branches and PRs:
  `git switch -c <short-description>` -> make changes -> build and run locally
  -> `git status` and `git diff` -> commit -> `git push -u origin <branch>` ->
  `gh pr create --fill` -> `gh pr merge --merge` -> `git switch main && git pull`.
- Pushing and merging need Adrian's approval (the repo is public).
- Keep this file free of secrets, client names, and the tailnet name.

## How the image works

- Base `debian:12-slim`. Packages mirror the official ITFlow install script
  (github.com/itflow-org/itflow-install-script) minus certbot.
- ITFlow is cloned at build time on `master`, then `git reset --hard` to the pinned
  `ARG ITFLOW_REF` (currently `v26.10`) so ITFlow's in-app updater still tracks master.
- **entrypoint.sh, first boot only** (guarded by marker `/var/lib/itflow-init.done`):
  start a temporary MariaDB with `--skip-networking`, create DB + user with a random
  password (`openssl rand`), import `db.sql` only if the DB is empty (strips the dump's
  `/*M!999999` sandbox line), write `config.php` (`$config_https_only = false` on
  purpose: Tailscale terminates HTTPS, Apache only sees HTTP). Later boots skip init.
  It must never delete or overwrite existing data.
- Entrypoint output is also written to `/var/log/itflow-entrypoint.log`. Its fds 3/4
  save real stdout/stderr so supervisord's output is not tee'd into that file.
- **Debug hold:** if env `ITFLOW_DEBUG_HOLD=1` and init fails, the container runs
  `sleep infinity` instead of exiting, so you can read the log on the MicroVM.
- supervisord (PID 1) runs mariadb, apache, cron, and tailscaled
  (`--tun=userspace-networking`, since containers have no TUN device).
- Tailscale is authenticated by hand after first boot (no auth keys in env):
  `tailscale up --hostname=itflow` then `tailscale serve --bg 80`. Key expiry should
  be disabled for that node in the Tailscale admin. MagicDNS and HTTPS certificates
  must be enabled in the tailnet.
- Env vars the image reads: `ITFLOW_BASE_URL` (e.g. `itflow.<tailnet>.ts.net`,
  used on first boot only) and `ITFLOW_DEBUG_HOLD`.

## DigitalOcean MicroVM constraints (public preview)

- Runs **one container image**, **linux/amd64 only**.
- Image must be **public** (e.g. ghcr.io, Docker Hub) or **private in DOCR**.
  A private ghcr.io package will fail to pull.
- **All settings are fixed at creation** (image, size, timeout, ports, networking,
  env). Changing anything means a new MicroVM, which starts with an empty disk.
- Use **Public networking** (outbound internet via NAT, needed by Tailscale).
  VPC networking has no internet access.
- Pauses after the idle timeout (default 5 min, max 4 h; plan is 1 h). Resumes on a
  request to its DO endpoint, `doctl compute microvm exec`, or a console session.
  **Tailscale traffic does not wake it.** Paused = no compute charge.
- The DO endpoint requires a DO API token in the Authorization header, so it's not
  usable from a normal browser. Only the HTTP port is reachable during the preview.
- **Runtime differs from Docker** (containerd, found 2026-10-30): `/dev` is a bare
  tmpfs with no `/dev/fd` or `/dev/std*` links, and `/run` is an empty 64 MB tmpfs
  that hides the image's `/run` (so `/var/lock -> /run/lock` dangles). The entrypoint
  recreates these. Reproduce locally with `--tmpfs /run:rw,nosuid,size=65536k,mode=755`
  and `rm -f /dev/fd /dev/std*` before running the entrypoint.
- File transfer (`doctl compute microvm download/upload`) is disabled for the account;
  `exec` and `console` work.
- No swap; out-of-memory kills processes. Use 2 GB RAM or more.
- Cron and backups only run while awake. The backup script is catch-up style for this.
- A failed MicroVM cannot be recovered; delete it and create a new one.
- There is no log viewer. Read logs with
  `doctl compute microvm exec <id> -- cat /var/log/itflow-entrypoint.log`
  (only works if the VM is running, e.g. held by `ITFLOW_DEBUG_HOLD=1`).
- doctl subcommands used so far: `list`, `get`, `exec`, `console`, `resume`,
  `delete` under `doctl compute microvm`. Verify flags with `--help` before use.

Planned create settings: image `ghcr.io/dt3233/itflow:<short-sha>`, Public networking,
HTTP port 80, 2 GB, idle timeout 1 h, env `ITFLOW_BASE_URL` and `ITFLOW_DEBUG_HOLD=1`.

## Build and release flow

1. Edit files in `docker build/` and commit to `main`.
2. GitHub Actions builds linux/amd64 and pushes
   `ghcr.io/dt3233/itflow:<short-sha>` and `:latest`. The last workflow step prints
   the reference. Use the short-sha tag for MicroVMs, never `latest`.
3. The ghcr.io package must be Public (one-time setting; effectively irreversible).
4. Create a new MicroVM from that tag. Data does not carry over between MicroVMs;
   migrate via backups.

## Local testing (WSL Debian + Docker Desktop)

From `docker build/`:

```
docker build --platform linux/amd64 -t itflow-local .
docker run --rm -it --platform linux/amd64 --name itflow-test \
  -p 127.0.0.1:8080:80 -e ITFLOW_DEBUG_HOLD=1 -e ITFLOW_BASE_URL=localhost itflow-local
```

Expected: first line `=== entrypoint start ...`, then "First boot setup complete.",
then supervisord starts mariadb, apache, cron, tailscaled (tailscaled sits at
NeedsLogin, which is normal). `http://localhost:8080` shows ITFlow setup.
Read the log: `docker exec itflow-test cat /var/log/itflow-entrypoint.log`.
Stop: `docker stop itflow-test` (Ctrl+C won't stop a debug-held container).
Bind to `127.0.0.1` so the port isn't exposed to the LAN.

To test the published image the way DO sees it: `docker logout ghcr.io`, then
`docker pull ghcr.io/dt3233/itflow:<short-sha>`.

## Line endings

A clone on Windows (not WSL) converted scripts to CRLF and broke the image with
`exec /usr/local/bin/entrypoint.sh: no such file or directory`. Fixes in place:
`.gitattributes` (`* text=auto eol=lf`) and a `sed -i 's/\r$//'` step in the
Dockerfile. Work from the clone inside WSL (`~/projects/...`), not `/mnt/c/...`.

## Current status and open problem

- The image builds and runs correctly in local Docker (verified 2026-10-30): init
  completes and all four services start.
- **Repo sync:** the workflow is on `main` and its first run succeeded (2026-10-29,
  commit `304cd76`), so `ghcr.io/dt3233/itflow:304cd76` should exist. `.gitattributes`
  and the Dockerfile CRLF `sed` step were added after that.
- Local Docker in Debian currently needs `sudo` (user not in the `docker` group).
- **On the MicroVM it has failed twice.**
  1. `workload container exited (code 1)`. That image predates the logging and
     debug-hold changes, and was created with VPC networking.
  2. Second attempt failed; the reason was not captured. Likely cause: no image
     existed on ghcr.io yet (the workflow was empty) or the package was private.
- **Next steps, in order:**
  1. Push the latest commits to `main`; confirm the Actions run is green.
  2. Make the `itflow` package public; verify with `docker logout ghcr.io` and an
     anonymous `docker pull ghcr.io/dt3233/itflow:<short-sha>`.
  3. Delete the old failed MicroVM (with approval). Create a new one with Public
     networking and `ITFLOW_DEBUG_HOLD=1`.
  4. If it fails, read `doctl compute microvm get <id>` and the entrypoint log to
     find what differs from local Docker.
- After it runs: Tailscale login and serve, ITFlow web setup, then confirm the VM
  actually pauses when idle (Tailscale keepalives might keep it awake, which would
  cost about $28/month instead of $1-3). Then set up copying backups off the VM.

## Fallback

If MicroVMs don't work out, the same image runs on a $6 DigitalOcean Droplet (or at
home) with Tailscale on the host, cron running on schedule, and no pause/wake issues.
