# nsknet.github.io

This repository hosts **NsPanel** — a lightweight, browser-based admin panel for a single Ubuntu VPS — together with a collection of server bootstrap scripts.

---

## NsPanel — VPS Admin Panel

NsPanel is built with **FastAPI** (Python) on the backend and a **Vue.js** SPA on the frontend. It is a thin UI wrapper over a modular library of bash scripts: bash remains the engine for all install and configuration logic, while Python handles status checks, metadata, and the HTTP surface.

### Run it after cloning

On the **Ubuntu VPS you want to manage**, run as root:

```bash
git clone https://github.com/nsknet/nsknet.github.io.git
cd nsknet.github.io/NsPanel
sudo ./run.sh
```

`run.sh` will:

1. Verify it is running as root and that Python 3 is available.
2. Create a virtualenv (`.venv/`) and install `requirements.txt` (auto-installs `python3-venv` / `python3-pip` via APT if missing).
3. Set the session credentials (printed in the startup banner).
4. Print the URL, credentials, and SSH tunnel instructions.
5. Start `uvicorn` on port `7777`.

> Requires Python 3.12+. The panel manages system services and installs packages, so it must run as **root**.

### Accessing the panel

The panel binds to `0.0.0.0:7777` but is intended to be reached over an SSH tunnel from your local machine:

```bash
ssh -L 7777:localhost:7777 user@your-server
```

Then open <http://localhost:7777> in your browser.

**Credentials:** username `admin`, password shown in the startup banner.

### Sections

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

### Supported tools

One-click install and status for: Cloudflared, CoreDNS, .NET SDK (6–10), Elasticsearch, Fail2ban, Kibana, MariaDB, MongoDB, SQL Server, NGINX, OpenObserve, PHP-FPM, PostgreSQL, RabbitMQ, Redis, and Samba. Tools are auto-discovered from `NsPanel/modules/` — adding one requires only a single new Python file.

---
