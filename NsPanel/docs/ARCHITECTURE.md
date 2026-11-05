# Architecture

NsPanel is a browser UI over a library of bash scripts. Two rules decide where
any new code goes:

1. **Bash is the engine.** Installing, configuring, writing config files — all
   of it lives in `scripts/`. Python never re-implements install logic.
2. **Status is Python.** `which`, `systemctl is-active`, `dpkg -l`, `psutil`,
   port checks. A status probe never shells out to a script.

## Layers

```
routes/     HTTP surface. Validates input, launches a job, returns an envelope.
core/       Plumbing: auth, job runner, bash invocation, audit log, contracts.
features/   Reading and writing system state in Python (status, units, sites).
modules/    One file per installable tool. Auto-discovered.
scripts/    Bash. The actual work.
frontend/   Vue 3 + Vite source; builds to static/dist/ (committed).
```

A route should read like a paragraph: validate, build, launch, return. If it
grows branches and string-building, the logic belongs in `features/` (state) or
`scripts/` (actions).

## The two response envelopes

Every endpoint returns one of two shapes, defined in `core/schemas.py`:

```jsonc
// A read
{ "status": "success", "data": <anything> }

// An accepted action, running in the background
{ "status": "success", "job_id": "...", "title": "Starting 'app'", "extra": {} }
```

There is also `MessageResponse` (`{status, message}`) for the rare action that
finishes synchronously — a DNS record edit, a process kill.

The frontend therefore has exactly two things to handle: unwrap `data`, or open
an SSE stream on `job_id`.

## How an action runs

```
POST /api/v1/services/demo/restart
  |- routes/services.py validates that the unit exists
  |   `- core/jobs.launch(["systemctl", "restart", "demo"], ...)
  |       |- core/runner.create_job()   -> job id, in-memory line buffer
  |       |- core/runner.start_job()    -> asyncio subprocess, stdout captured
  |       `- core/audit.log()           -> append-only line
  `- { job_id, title }

GET /stream/{job_id}
  `- routes/stream.py -> runner.stream_job() -> SSE `line` events, then `done`
```

Job state is in memory and capped at `config.MAX_JOBS`; restarting the panel
loses live logs but not the audit log. `GET /api/v1/jobs` lists the jobs still in
memory (the Jobs screen and the header's "N running" chip), and `/stream/{id}`
replays a job from its first line, so its output can be reopened after a reload.

## Auth and CSRF

Basic Auth covers everything except `/logout`. Because browsers re-send cached
Basic credentials on any request — including a form another website submits —
every non-GET request must also carry `X-NsPanel: 1` (`core/auth.require_csrf_header`),
and requests marked `Sec-Fetch-Site: cross-site` are refused. The frontend's
`postAction` sends the header.

### Calling a bash function

`core/bash_invoker.build_cmd("install_nginx", script="nginx.sh")` produces:

```bash
bash -c '<source lib/*.sh>; source "$1" && "$2" "${@:3}"' -- <script> install_nginx <args...>
```

Arguments are positional parameters, never spliced into the script text, so a
value that slipped past validation still cannot break out of its slot.
`core/jobs.systemctl_chain()` gives the same guarantee for multi-step systemd
commands. `tests/test_jobs.py` asserts this with hostile inputs.

Everything in `scripts/lib/` is sourced first, so any script may call the shared
helpers (`log_header`, `log_step`, `_ufw_allow_port`, `_register_panel_service`,
`gen_password`, `cred_set`). `lib/common.sh` also wraps `apt-get` so every call
waits for the dpkg lock instead of failing on a fresh VPS.

Only that one target script is sourced. A function that calls into another
script must source it itself (see the top of `system.sh`);
`tests/test_scripts.py` fails when it does not.

Jobs run with stdin closed and `DEBIAN_FRONTEND=noninteractive`: a script must
never prompt. Passwords go to SQL over stdin or an environment variable and are
never echoed into the job log — the log only says which file holds them.

Secrets (`DB_PASSWORD`) and firewall scope (`ALLOWED_SUBNETS`) travel through the
job environment, never argv — argv is echoed into the live log.

## Configuration

`config.py` is the only place paths and network settings are defined.
Environment overrides, all set by `run.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `NSPANEL_HOST` | `127.0.0.1` | Bind address. The panel is meant to be reached over an SSH tunnel. |
| `NSPANEL_PORT` | `7777` | Bind port. |
| `NSPANEL_DEV` | unset | `1` enables uvicorn auto-reload. |
| `PANEL_PASSWORD` | random per launch | Basic Auth password. Printed at startup only when the panel generated it. |
| `NSPANEL_SERVICE` | unset | `1` when running as the systemd service (set in its env file). |
| `NSPANEL_AUDIT_LOG` | `/var/log/nspanel/audit.log` | Falls back next to the code when that path is not writable. |

## State lives on the filesystem

| Location | Purpose |
|---|---|
| `/var/www/nginx/sites/<name>/info.yml` | Site metadata, written by bash |
| `/var/www/nginx/conf.d/` | Nginx vhost configs |
| `/var/www/nginx/log/` | Per-site access/error logs |
| `/var/www/services/` | Panel-managed systemd units (and symlinks to APT ones) |
| `/etc/coredns/hosts` | CoreDNS records |
| `/var/log/nspanel/audit.log` | Append-only action log |
| `/opt/nspanel` | The panel service's own sparse clone (`scripts/panel_service.sh`) |
| `/etc/nspanel/` | Service env file (password, 0600) and `state.json` (install/update times, last update check) |

No database. Sites and services are discovered by scanning those directories, so
the panel and the shell always agree about what exists.

## The panel as a service

`routes/panel.py`, `features/panel_service.py` and `scripts/panel_service.sh` run the
panel itself under systemd, from its own clone in `/opt/nspanel`. That clone is separate
from the checkout `run.sh` uses, so pulling or editing that checkout never changes what
the service runs.

- The **update check** (`POST /api/v1/panel/check`) runs `git fetch`. It counts only the
  commits that touch `config.SERVICE_UPDATE_PATHS`, then caches the result in `state.json`
  together with the HEAD it was made against. Once HEAD moves, the cached result is
  marked `stale` and the page checks again.
- **Restarts** are scheduled with `systemd-run --on-active=3`. A job that runs inside the
  service shares its cgroup, so a direct `systemctl restart` would kill the job before
  its exit status reached the browser. After the job ends, the page polls
  `GET /api/v1/panel` until the panel has gone down and come back, then reloads to pick
  up the new bundle.
- The service **cannot uninstall itself**: the route refuses when `is_self` is true.

## Frontend

`frontend/` is a Vue 3 + TypeScript app built by Vite into `static/dist/`, which
is committed so a VPS can `git clone` and run without Node. `app.py` serves
`static/dist` with an index.html fallback for client routes (hash history, so a
reload always requests `/`), real 404s under `/api`, `/stream`, `/logo` and
`/assets`, `Cache-Control: no-cache` on index.html and `immutable` on the hashed
bundle. Tool icons come from `static/logo/` under `/logo`.

Screen state worth keeping across a reload (filters, search, sort) lives in the
URL query via `composables/useQueryRef.ts`; query-only navigations do not
refetch the screen's stores.

One route table in `frontend/src/router/index.ts` owns the nav rail, the
breadcrumbs and which stores a screen loads — adding a screen means adding one
route, not editing five parallel tables.

## Tests

`pytest` runs on any OS: `tests/conftest.py` fakes the job runner and stubs the
status probes, so nothing calls systemctl. The suite protects three things:
input validation, that values never reach the shell as text, and that every tool
module points at a bash function that actually exists.
