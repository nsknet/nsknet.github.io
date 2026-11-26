# Operations

How to install, reach, update and repair NsPanel on a server. For how the code
is built, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Supported hosts

- Ubuntu **22.04** or **24.04**, amd64 or arm64.
- **Python 3.12+** for the panel itself. Ubuntu 24.04 ships it; on 22.04 install it
  first (for example from the deadsnakes PPA). `run.sh` stops with a clear message
  when it is missing.
- Root. The panel installs packages and manages systemd units.

Each tool also checks the Ubuntu releases and CPU architectures its vendor serves
and stops with a message rather than half-installing.

## Install and first sign-in

As root:

```bash
/bin/bash -c "$(curl --proto =https -fsSL https://nsknet.github.io/nspanel.sh)"
```

or, from a clone:

```bash
sudo ./NsPanel/run.sh
```

The first start generates the admin password and prints it **once**. Only a scrypt
hash is kept, in `/etc/nspanel/auth.json` (0600). The panel listens on
`127.0.0.1:7777`; reach it over an SSH tunnel:

```bash
ssh -L 7777:localhost:7777 user@your-server
```

and open <http://localhost:7777>. The user name is `admin`.

## Reaching it from the LAN or a VPN

Install the panel as a service (**Settings → Panel service**). Choose:

- the **port** (default 7778);
- the **subnets** UFW opens that port to. Pick your LAN or VPN range. The panel
  is not built for the open internet;
- **HTTPS**, on by default, with a self-signed certificate in `/etc/nspanel/tls/`.
  The browser warns about it once. To use your own certificate, replace
  `cert.pem` and `key.pem` there and restart the service.

The service runs from its own clone in `/opt/nspanel`, separate from the checkout
`run.sh` uses.

## Passwords and sessions

| Task | How |
|---|---|
| Change the password | **Settings → Security**. This signs out every other session. |
| Forgot it (checkout) | `sudo ./run.sh --reset-password` prints a new one. |
| Forgot it (service only) | `cd /opt/nspanel/current && sudo .venv/bin/python -m core.passwords reset` prints a new one. It takes effect at the next sign-in, with no restart. Restart the service to end existing sessions. |
| Set a known password | `echo 'new-password' \| sudo .venv/bin/python -m core.passwords set`, run from the panel directory. |
| Pin it from the environment | `PANEL_PASSWORD=…` is re-applied on every start while set. It is meant for throwaway hosts. |

Sessions end after 30 minutes idle or 12 hours in total. After 5 failed sign-ins in
15 minutes, an address is locked out for 15 minutes. Restarting the panel clears
the lockout, and it also signs everyone out.

There is one admin account and no 2FA. Rely on the network boundary (SSH tunnel, LAN,
VPN) for anything stronger.

## Updating

**Settings → Panel service** shows:

- the running commit;
- whether `main` has newer commits that touch the panel;
- the CI result of the commit an update would install.

Red or unfinished CI blocks the update unless you choose *Update anyway*.

An update builds the new release next to the running one, switches to it and
restarts. If the new release does not answer `/healthz` within 60 seconds, the panel
switches back on its own. Updates, restarts and rollbacks wait until no job is running.

A plain checkout started with `run.sh` updates with `git pull`. Then restart it.

## Rolling back by hand

Use **Roll back** on the Panel service page. If the panel no longer loads, do it
over SSH. The bash side needs nothing from the broken release's Python:

```bash
cd /opt/nspanel/current
sudo bash -c 'for f in scripts/lib/*.sh; do source "$f"; done
              source scripts/panel_service.sh
              panel_service_rollback'
```

`/etc/nspanel/state.json` records the current and previous release. The last three
releases stay under `/opt/nspanel/releases/`. In an emergency you can point the
symlink yourself and restart:

```bash
sudo ln -sfn /opt/nspanel/releases/<sha>/NsPanel /opt/nspanel/current
sudo systemctl restart nspanel
```

## Where to look

| What | Where |
|---|---|
| Service log | `journalctl -u nspanel -f` |
| Is it up? | `curl -k https://127.0.0.1:7778/healthz` (or `http://`, without `-k`). It returns the version and commit. |
| Who did what | `/var/log/nspanel/audit.log` (JSON lines, 0600, rotated at 5 MB), or **Activity → Audit** |
| Job history | `/var/lib/nspanel/jobs.jsonl`, or **Activity → Jobs** |
| Service settings | `/etc/nspanel/nspanel.env` (port, bind address, TLS paths; no secrets) |
| Tool credentials | Each tool's `credentials.yml` (for example `/etc/redis/credentials.yml`, mode 0600) |

## Back up

The panel keeps no database. Back up:

- `/etc/nspanel/`: the password hash, the service settings and the Cloudflare tunnel tokens in `tunnels/`;
- `/var/www/`: sites, their nginx configs and logs, and the panel-managed units in `services/`;
- the tools' own data and credential files, for example `/var/lib/postgresql` and `/etc/redis/credentials.yml`.

`/opt/nspanel` can be rebuilt from the repository at any time.

## Troubleshooting

**Locked out by the firewall.** The panel only enables UFW from **Network → Firewall**.
Before enabling it, the panel allows the real SSH port (`sshd -T`) and the panel's
own port. Deleting or denying those ports asks you to type the port to confirm. If
you are locked out anyway, disable UFW from the provider's web console with
`ufw disable`.

**"UI out of date" banner.** One of two things happened. The tab still runs the
previous bundle after an update: reload the page. Or `static/dist` is older than
`frontend/` in the running checkout, because someone pulled sources without the
rebuilt bundle: wait for the *Build frontend* workflow to commit it, or run
`npm ci && npm run build` in `NsPanel/frontend`.

**A job seems stuck.** Stop it from its output window, or from **Activity → Jobs**.
The command gets SIGTERM, then SIGKILL 10 seconds later. Every job also stops after
3 hours. Package installs run one at a time, so a second install waits for the first
to finish.

**`apt` is locked.** The scripts wait for unattended-upgrades to release the dpkg
lock before installing. Let them wait. Don't remove the lock files.

## Uninstalling

Uninstall the service from a panel started with `run.sh`, because the service will
not remove itself. That removes the unit, its firewall rules, `/opt/nspanel`, the
TLS files and its settings. The admin password and the tunnel tokens stay.

## Known limits

- One admin account, no 2FA, no per-user audit beyond the client IP.
- Jobs and sessions live in memory: a restart ends every session, stops running
  jobs and drops job output. Finished jobs keep a line in the history.
- The vendor install commands are tested in CI on fresh GitHub runners (nginx,
  Redis, UFW on 22.04 and 24.04). The other tools have only static checks and should
  be tried on a non-production host first.
