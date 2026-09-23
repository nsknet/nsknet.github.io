# nsknet.github.io

This repository is two things at once:

- **[NsPanel](NsPanel/)** — a browser-based admin panel for a single Ubuntu VPS.
- **A GitHub Pages site** — which is why `nspanel.sh`, `index.html` and
  `SampleBlankSite.tar` sit at the repository root: the installer and the .NET
  site template are fetched from `nsknet.github.io/…`.

---

## Quick start

On the Ubuntu VPS you want to manage, as root:

```bash
/bin/bash -c "$(curl -fsSL nsknet.github.io/nspanel.sh)"
```

Prompts for a branch when several exist, then auto-selects the default after 10s.

Pick a branch explicitly:

```bash
/bin/bash -c "$(curl -fsSL nsknet.github.io/nspanel.sh)" dev
# or: BRANCH=dev /bin/bash -c "$(curl -fsSL nsknet.github.io/nspanel.sh)"
```

Or clone and run it yourself:

```bash
git clone --depth=1 https://github.com/nsknet/nsknet.github.io.git
cd nsknet.github.io/NsPanel && sudo ./run.sh
```

The panel binds to `127.0.0.1:7777`. Reach it over an SSH tunnel:

```bash
ssh -L 7777:localhost:7777 user@your-server
```

Then open <http://localhost:7777> — username `admin`, password printed in the banner.

---

## What is here

| Path | Purpose |
|---|---|
| [`NsPanel/`](NsPanel/) | The panel: FastAPI backend, Vue 3 SPA, bash scripts. [Docs](NsPanel/docs/ARCHITECTURE.md). |
| [`SampleBlankSite/`](SampleBlankSite/) | Source of the .NET template the panel deploys for new .NET sites. |
| `SampleBlankSite.tar` | Published build of the above, served by Pages. |
| `nspanel.sh` | The curl-and-run installer. |
| [`mini-scripts/`](mini-scripts/) | Standalone helpers (Cloudflared setup, Proxmox VM cloning). |

Full documentation lives in [NsPanel/README.md](NsPanel/README.md).
