# NsPanel

A browser-based admin panel for a single Ubuntu VPS: **FastAPI** on the back,
a **Vue 3** SPA on the front, and **bash** doing the actual work.

- [Architecture](docs/ARCHITECTURE.md) — the layers, the two response envelopes, how a job runs
- [Adding a tool](docs/ADDING_A_TOOL.md) — one Python file plus one bash script

---

## Run it

On the VPS, as root:

```bash
sudo ./run.sh
```

`run.sh` creates `.venv/`, installs the package, generates a one-off password and
starts uvicorn on `127.0.0.1:7777`. Reach it over an SSH tunnel:

```bash
ssh -L 7777:localhost:7777 user@your-server
```

Then open <http://localhost:7777> — username `admin`, password from the banner.

| Variable | Default | Meaning |
|---|---|---|
| `NSPANEL_HOST` | `127.0.0.1` | Bind address |
| `NSPANEL_PORT` | `7777` | Bind port |
| `NSPANEL_DEV` | unset | `1` enables uvicorn auto-reload |
| `PANEL_PASSWORD` | random each launch | Pin the Basic Auth password |

> Requires Python 3.12+ and root — the panel manages system services and installs packages.

---

## Sections

| Section | What it does |
|---|---|
| **Dashboard** | CPU, RAM, disk, uptime, sites and tools at a glance |
| **System** | Host specs, timezone, utilities, swap, network interfaces, disks |
| **Firewall** | UFW rules — add, delete, activate |
| **Sites** | Nginx virtual hosts — static, reverse proxy, .NET Core |
| **Services** | Custom systemd units, including Cloudflare tunnels |
| **Tools** | One-click install and live status for pre-scripted packages |
| **DNS** | CoreDNS host records |
| **Task manager** | Live process list with kill |
| **Audit logs** | Append-only record of every panel action |

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

- **Single user, no rate limiting.** One operator, over an SSH tunnel.
- **Job state is in memory**, capped at 200 jobs. Live logs are lost on restart; `audit.log` persists.
- **Root required.** `run.sh` refuses to start otherwise.
