# NsPanel — VPS Admin Panel

A lightweight, browser-based admin panel for a single Ubuntu VPS. Built with **FastAPI** (Python) on the backend and a **Vue.js** SPA on the frontend. The panel is a thin UI wrapper over a modular library of bash scripts — bash remains the engine for all install and configuration logic; Python handles status checks, metadata, and the HTTP surface.

---

## Quick Start

On the VPS, run as root:

```bash
sudo ./run.sh
```

`run.sh` will:

1. Verify it is running as root and that Python 3 is available.
2. Create a virtualenv (`.venv/`) and install `requirements.txt`.
3. Set the session password (printed in the startup banner).
4. Print the URL, credentials, and SSH tunnel instructions.
5. Start `uvicorn` on port `7777`.

---

## Accessing the Panel

The panel binds to `0.0.0.0:7777`. It is intended to be accessed over an SSH tunnel from your local machine:

```bash
ssh -L 7777:localhost:7777 user@your-server
```

Then open `http://localhost:7777` in your browser.

**Credentials:** username `admin`, password shown in the startup banner.

---

## Sections

| Section | Description |
|---|---|
| **Dashboard** | Aggregated overview — CPU, RAM, disk, uptime, installed sites and tools at a glance |
| **System** | Host specs, timezone presets, common utilities, virtual RAM (swap) management |
| **Firewall** | UFW rule management — add/remove ports, activate firewall |
| **Sites** | Nginx virtual host management — static files, reverse proxy, .NET Core apps |
| **Services** | Custom systemd service lifecycle — create, start, stop, edit unit files |
| **Tools** | One-click installation and status dashboard for pre-scripted server packages |
| **DNS** | CoreDNS host record management — map domains to IPs without a restart |
| **Logs** | Append-only audit trail of every panel action |

---

## Supported Tools

All tools below are auto-discovered from `modules/`. Adding a new tool requires only a single new Python file — no other edits.

| Tool | Port(s) | Notes |
|---|---|---|
| <img src="static/logo/cloudflare.png" width="20" height="20" valign="middle"> &nbsp;**Cloudflared** | — | Cloudflare Tunnel — expose local services without opening firewall ports |
| <img src="static/logo/coredns.png" width="20" height="20" valign="middle"> &nbsp;**CoreDNS** | 53 | Lightweight DNS server — map domains to IPs, forward the rest upstream |
| <img src="static/logo/net.png" width="20" height="20" valign="middle"> &nbsp;**.NET SDK** | — | .NET SDK 6 / 7 / 8 / 9 / 10 — required for hosting .NET Core sites |
| <img src="static/logo/elasticsearch.png" width="20" height="20" valign="middle"> &nbsp;**Elasticsearch** | 9200 | Elasticsearch 8.x distributed search and analytics engine |
| <img src="static/logo/fail2ban.png" width="20" height="20" valign="middle"> &nbsp;**Fail2ban** | — | SSH brute-force protection — bans IPs after repeated auth failures |
| <img src="static/logo/kibana.png" width="20" height="20" valign="middle"> &nbsp;**Kibana** | 5601 | Dashboard UI for Elasticsearch (localhost only) |
| <img src="static/logo/mariadb.png" width="20" height="20" valign="middle"> &nbsp;**MariaDB** | 3306 | MariaDB via APT — MySQL-compatible relational database |
| <img src="static/logo/mongodb.png" width="20" height="20" valign="middle"> &nbsp;**MongoDB** | 27017 | MongoDB 9.x community edition document database |
| <img src="static/logo/mssql.png" width="20" height="20" valign="middle"> &nbsp;**SQL Server 2025** | 1433 | Microsoft SQL Server 2025 via APT |
| <img src="static/logo/nginx.png" width="20" height="20" valign="middle"> &nbsp;**NGINX** | 80 / 443 | Reverse proxy and static web server — required for hosting sites |
| <img src="static/logo/openobserve.png" width="20" height="20" valign="middle"> &nbsp;**OpenObserve** | 5080 | Logs, metrics, traces and dashboards (localhost only) |
| <img src="static/logo/php.png" width="20" height="20" valign="middle"> &nbsp;**PHP-FPM** | — | PHP-FPM via the `ondrej/php` PPA, runs as `www-data` for nginx |
| <img src="static/logo/postgresql.png" width="20" height="20" valign="middle"> &nbsp;**PostgreSQL 16** | 5432 | PostgreSQL 16 via PGDG |
| <img src="static/logo/rabbitmq.png" width="20" height="20" valign="middle"> &nbsp;**RabbitMQ** | 5672 / 15672 | RabbitMQ 4.x message broker with management UI |
| <img src="static/logo/redis.png" width="20" height="20" valign="middle"> &nbsp;**Redis** | 6379 | In-memory key-value store — cache, session, SignalR backplane; password-protected |
| <img src="static/logo/samba.png" width="20" height="20" valign="middle"> &nbsp;**Samba** | 445 | SMB/CIFS file sharing with password auth — one share, one login user |

> Icons sourced from [dashboardicons.com](https://dashboardicons.com/icons).

---

## Architecture

### Backend
- **FastAPI** serves a JSON REST API under `/api/v1/`.
- **HTTP Basic Auth** (single admin user) guards all routes except `/logout`.
- **Bash is the engine.** Each install/configure action finds the relevant function in `scripts/`, sources it, and executes it with arguments. No install logic lives in Python.
- **Status in Python.** `which`, `systemctl`, `dpkg`, `psutil`, and port checks — status never touches bash.
- **Live output via SSE.** Long-running scripts run as background jobs; their stdout is streamed to the browser over Server-Sent Events at `/stream/{job_id}`.

### Frontend
- **Vue.js SPA** served as static files by FastAPI's `StaticFiles` mount.
- Screen routing and state management handled in-browser (no page reloads).
- Live output displayed in an overlay reading the SSE stream.

### Data & State
| Location | Purpose |
|---|---|
| `/var/www/nginx/sites/<name>/info.yml` | Site metadata (written by bash scripts) |
| `/var/www/nginx/conf.d/` | Nginx virtual host configs |
| `/var/www/nginx/log/` | Per-site Nginx access/error logs |
| `/var/www/services/` | Custom systemd unit files |
| `/etc/coredns/hosts` | CoreDNS host records (managed by the DNS screen) |
| `audit.log` | Append-only panel action log |

---

## Project Structure

```
NsPanel/
├── app.py              # FastAPI entry point
├── config.py           # Paths and constants
├── run.sh              # Launch script (sudo ./run.sh)
├── requirements.txt
│
├── core/
│   ├── auth.py         # HTTP Basic Auth
│   ├── runner.py       # Subprocess job manager + SSE broadcaster
│   ├── bash_invoker.py # Locates and builds bash function commands
│   └── audit.py        # Append-only action logger
│
├── features/
│   ├── system.py       # CPU / RAM / disk / network stats
│   ├── sites.py        # Nginx site discovery and metadata
│   ├── services.py     # systemctl helpers and tool_status()
│   ├── panel_services.py
│   └── dns.py          # CoreDNS host file reader/writer
│
├── modules/            # One file per installable tool (auto-discovered)
│   ├── base.py         # Module abstract base class
│   ├── registry.py     # Auto-discovery via pkgutil
│   ├── nginx.py
│   ├── postgres.py
│   ├── redis.py
│   └── ...             # cloudflared, coredns, dotnet, elasticsearch,
│                       # fail2ban, kibana, mariadb, mongodb, mssql,
│                       # openobserve, php, rabbitmq, samba
│
├── routes/             # HTTP route handlers
│   ├── dashboard.py
│   ├── system.py
│   ├── firewall.py
│   ├── sites.py
│   ├── services.py
│   ├── tools.py
│   ├── dns.py
│   ├── logs.py
│   ├── stream.py
│   └── auth.py
│
├── scripts/            # Bash install/configure scripts
│   ├── nginx.sh
│   ├── postgres.sh
│   ├── redis.sh
│   ├── coredns.sh
│   ├── firewall.sh
│   ├── service.sh
│   ├── system.sh
│   └── ...
│
└── static/
    ├── logo/           # Tool icons (PNG)
    └── js/             # Vue.js SPA source
```

---

## Adding a New Tool

Drop a single file in `modules/`. The registry auto-discovers any `Module` subclass — no other edits required.

```python
# modules/mytool.py
from features import services
from modules.base import Module

class MyToolModule(Module):
    name          = "mytool"
    display_name  = "My Tool"
    description   = "Does something useful."
    bash_function = "install_mytool"   # function in scripts/mytool.sh
    logo          = "mytool.png"       # file in static/logo/

    def is_installed(self) -> bool:
        return services.which("mytool") is not None

    def get_status(self) -> dict:
        return services.tool_status(
            binary="mytool",
            service="mytool",
            ports=[1234],
        )
```

Optional class attributes on `Module`:
- `requires_password = True` — renders a password field in the install dialog; value passed to bash via `DB_PASSWORD`.
- `firewall_ports = [port, ...]` — lets the user choose which subnets to expose via UFW before installing.
- `install_params = [...]` — extra dynamic install-time inputs (string, number, checkbox, select).
- `uninstall_function` / `change_password_function` — additional lifecycle bash functions.

---

## Notes

- **Single user, no rate limiting.** Designed for one operator accessing their own VPS over an SSH tunnel.
- **Job state is in-memory.** Live log streams are lost if the panel process restarts; `audit.log` persists.
- **CRLF auto-normalization.** On startup, `run.sh` and `app.py` convert any Windows-style line endings in `.sh` files to LF so scripts run cleanly on Linux.
- **Root required.** `run.sh` refuses to start if not run as root — the panel manages system services and installs system packages.
