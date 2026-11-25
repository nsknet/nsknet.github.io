# NsPanel

A browser-based admin panel for a single Ubuntu VPS: **FastAPI** on the back,
a **Vue 3** SPA on the front, and **bash** doing the actual work.

- [Architecture](docs/ARCHITECTURE.md) — the layers, the two response envelopes, how a job runs
- [Adding a tool](docs/ADDING_A_TOOL.md) — one Python file plus one bash script
- [Frontend guide](docs/FRONTEND.md) — layout, data states, forms, dialogs and components

---

## Run it

On the VPS, as root:

```bash
sudo ./run.sh
```

`run.sh` creates `.venv/`, installs the pinned dependencies from `requirements.lock`
and starts uvicorn on `127.0.0.1:7777`. On the first start it generates the admin
password and prints it **once**; only a scrypt hash is stored (`/etc/nspanel/auth.json`).
Reach the panel over an SSH tunnel:

```bash
ssh -L 7777:localhost:7777 user@your-server
```

Then open <http://localhost:7777> and sign in as `admin`. Change the password from
the rail (key icon). Forgot it? `sudo ./run.sh --reset-password` prints a new one.

| Variable | Default | Meaning |
|---|---|---|
| `NSPANEL_HOST` | `127.0.0.1` | Bind address |
| `NSPANEL_PORT` | `7777` | Bind port |
| `NSPANEL_DEV` | unset | `1` enables uvicorn auto-reload |
| `PANEL_PASSWORD` | unset | Pin the admin password (re-applied on every start while set) |

> Requires Python 3.12+ and root — the panel manages system services and installs packages.

### Run it as a service

To keep the panel running on the LAN, open **Panel service** in the rail. Then pick a
port (default `7778`), the subnets to open the port to, whether to serve HTTPS (on by
default), optionally a new admin password, and click **Install service**. It:

- clones the repo into `/opt/nspanel` and builds a **release** for the current commit:
  `releases/<sha>/NsPanel`, with its own virtualenv and pinned dependencies, checked
  (imports, built frontend) before anything is switched to it;
- points `/opt/nspanel/current` at that release and writes the `nspanel.service` unit
  (which runs `current`) and `/etc/nspanel/nspanel.env` (root-only, no secrets), then
  enables it on boot. The service shares the host's admin password hash with `run.sh`;
- with HTTPS, creates a self-signed certificate for the host's name and addresses in
  `/etc/nspanel/tls/` (replace `cert.pem`/`key.pem` with your own if you have one);
- adds UFW rules for the chosen subnets, commented `NsPanel service`. If UFW is off,
  it is not switched on.

The same page shows the installed commit, when it was last updated, and whether `main`
has new commits that touch the panel. Commits elsewhere in the repo, such as sample-site
rebuilds, are not counted. It also shows the **CI result** of the commit an update would
install; a red or still-running CI blocks the update unless you choose *Update anyway*.

**Update & restart** builds the new release beside the running one, so a failed build
changes nothing. Then it switches `current` and restarts. If the new version does not
answer `/healthz` within a minute, `current` is switched back and the service restarted
on the previous release; the page says so. **Roll back** does the same by hand. Three
releases are kept on disk. Update, restart and rollback wait until no job is running.

To uninstall, use a panel started with `run.sh`, not the service itself. Uninstalling
keeps the admin password and Cloudflare tunnel tokens in `/etc/nspanel`.

---

## Sections

| Section | What it does |
|---|---|
| **Overview** | What needs attention (full disks, failed services and jobs, updates), live CPU/RAM/disk, apps and tools at a glance |
| **Apps** | Sites (nginx: static, reverse proxy, .NET) and services (systemd units, Cloudflare tunnels) in one list; create, logs, config, unit editor with diff |
| **Tools** | One-click install and live status for pre-scripted packages |
| **Network** | Firewall (UFW rules with lockout protection for SSH and the panel), DNS (CoreDNS records), interfaces (DHCP/static with automatic rollback) |
| **System** | Host facts, timezone, swap and maintenance; storage (mount, unmount, format with safety checks); processes (search, signal, protected PIDs) |
| **Activity** | Jobs (live output, cancel) and the audit log (who, what, from where) |
| **Settings** | Panel service (install, HTTPS, update with CI check, rollback) and security (password, sessions, theme, version) |

## Supported tools

Auto-discovered from `modules/` — Cloudflared, CoreDNS, .NET SDK (6–10),
Elasticsearch, Fail2ban, Kibana, MariaDB, MongoDB, SQL Server, NGINX,
OpenObserve, PHP-FPM, PostgreSQL, RabbitMQ, Redis, Samba.

Icons from [dashboardicons.com](https://dashboardicons.com/icons).

---

## Layout

```
NsPanel/
├── app.py config.py run.sh pyproject.toml
├── core/       auth, job runner, bash invocation, audit log, schemas
├── features/   system state in Python (status, units, sites, disks, DNS)
├── modules/    one file per installable tool (auto-discovered)
├── routes/     the HTTP surface
├── scripts/    bash — the engine; scripts/lib/ holds shared helpers
├── static/     logo/ (tool icons) and dist/ (the built SPA, committed)
├── frontend/   Vue 3 + Vite source for static/dist
├── tests/      pytest; runs on any OS, nothing touches systemd
└── docs/
```

---

## Working on it

```bash
# Backend
pip install -e ".[dev]"
ruff check . && pytest

# Frontend (rebuild static/dist after any change under frontend/)
cd frontend && npm ci
npm run dev        # Vite on :7778, proxying the API to a running panel
npm run build      # writes ../static/dist
npm run typecheck
```

`static/dist/` is committed so a VPS can `git clone` and run without Node;
CI rebuilds and commits it whenever `frontend/` changes.

---

## Notes

- **One admin account**, sign-in rate limited per IP. Meant for an SSH tunnel, LAN or VPN, not the open internet. No 2FA.
- **Jobs**: output lives in memory (200 jobs, 20,000 lines each); a short history survives restarts. Package installs run one at a time; any job can be cancelled and times out after 3 hours.
- **Audit log**: JSON lines with user and client IP, `/var/log/nspanel/audit.log` (0600, rotated at 5 MB).
- **Root required.** `run.sh` refuses to start otherwise.
- **Supported hosts:** Ubuntu 22.04 and 24.04 (Python 3.12+ for the panel itself, so 22.04 needs the deadsnakes PPA). Each tool also checks the releases and CPU architectures its vendor repository serves and stops with a clear message otherwise.
