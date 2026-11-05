# SampleBlankSite

The placeholder ASP.NET Core (.NET 10) app NsPanel deploys when you create a
**.NET Core site**. It proves the site, systemd unit and nginx proxy work, and
doubles as a first-boot health check for the server.

## Endpoints

| Path | Purpose |
|---|---|
| `/` | Welcome page: where to upload your build and which DLL name systemd expects. |
| `/check` | Server health dashboard (see below). Results are cached for 5 seconds. |
| `/check.json` | The same data as JSON, for scripts. |
| `/health` | Liveness probe, returns `OK` without touching the system. |

`/check` is public on purpose — it is a setup page. Replace the app (or remove
the route) once the server is confirmed healthy.

### What `/check` reports

Everything is read as the unprivileged service user (`www-data`), mostly from
`/proc`, `/sys` and `/etc`:

- **Overall score** with a list of warnings/critical issues (disk ≥ 85/95 %,
  memory ≥ 90/95 %, load above core count, failed systemd units, stopped
  services, closed service ports, no internet/DNS, unsynchronised clock,
  pending reboot or security updates).
- **System**: hostname, OS, kernel, architecture, virtualization, uptime,
  time zone, NTP sync, swap.
- **CPU / memory / disk / load** usage.
- **Services** NsPanel can install (nginx, MariaDB/MySQL, PostgreSQL, MongoDB,
  SQL Server, Redis, RabbitMQ, Elasticsearch, Kibana, OpenObserve, Docker,
  Samba, CoreDNS, cloudflared, fail2ban, ufw): systemd state, version and a
  loopback port probe.
- **Network**: interfaces and addresses, outbound internet and DNS checks.
- **Top memory consumers**, **listening TCP ports**, installed **.NET SDKs and
  runtimes**, and how this request reached the app (forwarded headers, client IP).

## How NsPanel uses it

`_deploy_sample_dotnet` in `NsPanel/scripts/nginx.sh` extracts
`SampleBlankSite.tar` (from the local clone, falling back to
`https://nsknet.github.io/SampleBlankSite.tar`) into the site's `public/`
directory and renames every `SampleBlankSite.*` file to the DLL name the
operator chose, so the systemd unit already points at the right file when the
real app is uploaded.

## Rebuilding the tarball

The tarball is committed at the repository root so GitHub Pages serves it.
The `Build SampleBlankSite` workflow rebuilds, smoke-tests and commits it
whenever this folder changes. To do it by hand:

```bash
dotnet publish SampleBlankSite.csproj -c Release -o ./publish
tar --owner=0 --group=0 --numeric-owner --sort=name --mtime='2000-01-01 00:00Z' \
    -cf ../SampleBlankSite.tar -C ./publish $(cd publish && ls -A)
```

The build is framework-dependent and RID-neutral (`UseAppHost=false`), so it
runs on x64 and arm64 hosts with the ASP.NET Core 10 runtime installed.
