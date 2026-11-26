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

Job state is in memory and capped at `config.MAX_JOBS` (output at
`config.MAX_JOB_LINES` per job, oldest lines dropped). Each job runs in its own
process group: `POST /api/v1/jobs/{id}/cancel`, the per-job timeout and panel
shutdown stop the whole tree. Install/uninstall functions (`core/jobs._EXCLUSIVE`)
queue behind each other instead of fighting over the dpkg lock. A finished job's
summary is appended to `jobs.jsonl`, so the list survives a restart; its output
does not. `GET /api/v1/jobs` lists the jobs still in
memory (the Jobs screen and the header's "N running" chip), and `/stream/{id}`
replays a job from its first line, so its output can be reopened after a reload.

## Auth and CSRF

One admin account. The password is stored only as a scrypt hash
(`core/passwords.py`, `/etc/nspanel/auth.json`, 0600), shared by every panel on the
host. `POST /api/v1/auth/login` creates a server-side session (`core/session.py`,
in memory: a restart signs everyone out) and sets an HttpOnly, SameSite=Strict
cookie. Sessions end after 30 minutes idle or 12 hours. Five failed logins from one
IP within 15 minutes lock that IP out for 15 minutes; every attempt is audited with
the client IP.

Everything under `/api` and `/stream` needs a session (`core/auth.require_session`).
Public: the login route, `/healthz`, the SPA shell and static assets — the shell asks
`/api/v1/auth/me` and shows the login screen on 401.

On top of SameSite, every non-GET request must carry `X-NsPanel: 1`
(`core/auth.require_csrf_header`); requests marked `Sec-Fetch-Site: cross-site` or
with a foreign `Origin` are refused. The frontend's `postAction` sends the header.
Responses carry a CSP with `frame-ancestors 'none'` and `X-Frame-Options: DENY`.

Every error is `{status: "error", code, message, detail}`.

## Version

`core/version.py` reports the package version plus the git commit the process
started from (`GET /healthz`, `GET /api/v1/version`). The build writes
`static/dist/version.json` with the last commit that touched `frontend/`. The UI
shows "UI out of date" in two cases:

- the backend's checkout has newer `frontend/` commits than that file, so `static/dist` is stale;
- the page booted with a different `version.json` than the server now serves, because the
  tab stayed open across an update.

The commit is only in `version.json`, never compiled into the JS, so the same sources
always build the same bundle and CI can compare it byte for byte.

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
`gen_password`, `cred_set`, `_require_platform`, `_verify_sha256`, the `_fstab_*`
helpers; see docs/ADDING_A_TOOL.md). `lib/common.sh` also wraps `apt-get`, `dpkg -i`
and `add-apt-repository` so every call waits for the dpkg lock instead of failing on
a fresh VPS, and never stops at a "keep your modified config file?" prompt.

`/etc/fstab` is only edited through `_fstab_backup` / `_fstab_remove_field` /
`_fstab_verify_or_restore`: a change that makes `findmnt --verify` report new errors
is rolled back, so the panel cannot leave a host that fails to boot. `_ufw_allow_port`
never enables UFW; only `install_ufw` does, after allowing the real SSH port(s) and
the panel's port.

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
| `PANEL_PASSWORD` | unset | Pins the admin password: re-hashed on every start while set. |
| `NSPANEL_AUTH_FILE` | `/etc/nspanel/auth.json` | The password hash. |
| `NSPANEL_STATE_DIR` | `/var/lib/nspanel` | Job history (`jobs.jsonl`). |
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
| `/opt/nspanel` | The panel service's clone; `releases/<sha>/` worktrees and the `current` symlink (`scripts/panel_service.sh`) |
| `/etc/nspanel/` | `auth.json` (password hash), service env file (0600, no secrets), `state.json` (install/update times, last update check), `tunnels/*.env` (Cloudflare tunnel tokens, 0600) |
| `/var/lib/nspanel/jobs.jsonl` | Finished-job history shown on the Jobs screen after a restart |

No database. Sites and services are discovered by scanning those directories, so
the panel and the shell always agree about what exists.

## The panel as a service

`routes/panel.py`, `features/panel_service.py` and `scripts/panel_service.sh` run the
panel itself under systemd, from its own clone in `/opt/nspanel`. That clone is separate
from the checkout `run.sh` uses, so pulling or editing that checkout never changes what
the service runs.

- **Releases.** Each commit the service runs is a git worktree,
  `releases/<sha>/NsPanel` (sparse: only `NsPanel/`), with its own `.venv` built from
  `requirements.lock`. It is smoke-tested (imports, built frontend) and marked
  `.release-ok` before use. `current` is a symlink to the active release, swapped
  atomically (`ln -sfn` + `mv -T`); the unit runs `current`. `state.json` records the
  current and previous release. Older releases are pruned, keeping three. Installs made
  before releases existed ran `/opt/nspanel/NsPanel`; that directory stays as the
  previous release on their first update.
- The **update check** (`POST /api/v1/panel/check`) runs `git fetch`, counts only the
  commits after the current release that touch `config.SERVICE_UPDATE_PATHS`, and asks
  GitHub for the check runs of the branch tip (walking back past `[skip ci]` commits).
  The result is cached in `state.json` with the commit it was made against; once the
  release changes it is marked `stale` and the page checks again.
- **Update** re-checks, refuses while CI is red or running (unless `force`), and passes
  the exact commit it checked as `SVC_TARGET`, so the job never installs a newer commit
  nobody looked at.
- **Restarts and rollback.** After switching `current`, the service must answer
  `/healthz` within 60 s; otherwise `current` goes back to the previous release and the
  service is restarted (`panel_service_watchdog`). A job running inside the service
  shares its cgroup, so there the restart and the watchdog run in a transient unit
  (`systemd-run --on-active=3`) instead. The page then polls `GET /api/v1/panel` until
  the panel has gone down and come back, and reloads.
- Update, restart and rollback are refused while any job runs (a restart would stop
  it), and the script takes `/run/nspanel-service.lock` so two never overlap.
- **HTTPS** (default on): a self-signed certificate in `/etc/nspanel/tls/`; uvicorn
  serves it directly and the session cookie becomes `Secure`.
- The service **cannot uninstall itself**: the route refuses when `is_self` is true.
  Uninstalling never removes `auth.json` or `tunnels/`.

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
route, not editing five parallel tables. Paths from the earlier layout
(`/sites`, `/services`, `/firewall`, …) redirect to their new place.

How screens are built — data states, forms, dialogs, confirmations and the
shared components — is in [FRONTEND.md](FRONTEND.md). The theme (system, light or
dark) is applied before the first paint by `public/theme-init.js`, a file rather
than an inline script so it fits the Content-Security-Policy.

## Tests

`npm test` (vitest, in `frontend/`) covers the input rules, formatting, the data
store behaviour (errors, silent polls, stale responses), the dialog stack, the
confirm dialog, the data table and the firewall lockout logic.

`pytest` runs on any OS: `tests/conftest.py` fakes the job runner and stubs the
status probes, so nothing calls systemctl. The suite protects three things:
input validation, that values never reach the shell as text, and that every tool
module points at a bash function that actually exists.

`tests/integration/` is the exception: it runs real installs through
`bash_invoker.build_cmd`, exactly as a job would, and checks the result from the
outside (service active, Redis refuses a client without the password, UFW kept
SSH and the panel open). It changes the machine, so it is skipped unless
`NSPANEL_INTEGRATION=1` and running as root on Linux; CI runs it on throwaway
Ubuntu 22.04 and 24.04 runners when `scripts/` changes.
