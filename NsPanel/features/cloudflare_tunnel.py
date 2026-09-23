"""Cloud-managed Cloudflare Tunnel setup via the official `cloudflare` SDK.

Pure library: no printing, no panel imports. The route layer maps
`TunnelError` to an HTTP 400 whose detail is shown to the user as-is, so
every message here must be self-explanatory and must never contain the API
token or the tunnel token.

Flow (setup): verify token -> find zone -> create/reuse tunnel -> update
ingress -> upsert CNAME -> fetch tunnel token.
"""
import base64
import re
import secrets
from dataclasses import asdict, dataclass
from urllib.parse import urlparse


class TunnelError(Exception):
    """Raised for any failure; `stage` tags where it happened."""

    def __init__(self, stage: str, message: str):
        super().__init__(message)
        self.stage = stage
        self.message = message

    def __str__(self) -> str:
        return f"[{self.stage}] {self.message}"


@dataclass
class TunnelResult:
    token: str
    tunnel_id: str
    tunnel_name: str
    hostname: str
    service_url: str
    zone_id: str
    zone_name: str
    account_id: str
    dns_record_id: str

    def public_info(self) -> dict:
        """Everything except the tunnel token — safe to return and log."""
        d = asdict(self)
        d.pop("token")
        d["public_url"] = f"https://{self.hostname}"
        return d


# Lowercase FQDN with at least two labels; no wildcards, no underscores.
HOSTNAME_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
)

CATCH_ALL = "http_status:404"
DNS_COMMENT = "Managed by NsPanel"

PERM_ZONE_READ = "Zone > Zone: Read"
PERM_DNS_EDIT = "Zone > DNS: Edit"
PERM_TUNNEL_EDIT = "Account > Cloudflare Tunnel: Edit"


# ---------------------------------------------------------------------------
# Input normalisation
# ---------------------------------------------------------------------------

def normalize_hostname(hostname: str) -> str:
    """'HTTPS://Dev.Example.com/' -> 'dev.example.com'."""
    h = (hostname or "").strip().lower()
    if not h:
        raise TunnelError("input", "Hostname is required.")
    if "://" in h:
        h = urlparse(h).hostname or h
    h = h.strip("/").rstrip(".")
    if not HOSTNAME_RE.match(h):
        raise TunnelError(
            "input",
            f"'{h}' is not a valid public hostname (expected e.g. app.example.com).",
        )
    return h


def normalize_service_url(url: str, port: int | str | None = None) -> str:
    """Normalise the local origin used in the tunnel ingress rule.

    '5016' -> http://localhost:5016; 'localhost:5016/' -> http://localhost:5016;
    'http://127.0.0.1', port=5016 -> http://127.0.0.1:5016
    """
    s = str(url or "").strip()
    if not s:
        raise TunnelError("input", "Local service URL or port is required.")

    if s.isdigit():
        s = f"http://localhost:{s}"
    elif "://" not in s:
        s = "http://" + s

    parsed = urlparse(s)
    scheme = (parsed.scheme or "http").lower()
    if scheme not in ("http", "https"):
        raise TunnelError("input", f"Unsupported scheme '{scheme}' — use http or https.")
    host = parsed.hostname
    if not host:
        raise TunnelError("input", f"Could not parse a host from '{url}'.")

    try:
        target_port = int(port) if port not in (None, "") else parsed.port
    except ValueError as exc:
        bad = port if port not in (None, "") else parsed.netloc.rsplit(":", 1)[-1]
        raise TunnelError("input", f"Invalid port '{bad}'.") from exc
    if target_port is not None and not (1 <= target_port <= 65535):
        raise TunnelError("input", f"Port {target_port} is out of range (1-65535).")

    out = f"{scheme}://{host}"
    if target_port:
        out += f":{target_port}"
    if parsed.path and parsed.path != "/":
        out += parsed.path.rstrip("/")
    return out


def tunnel_service_name(hostname: str) -> str:
    return f"cloudflared.{hostname}"


def default_tunnel_name(hostname: str) -> str:
    return f"{hostname.replace('.', '-')}-tunnel"


# ---------------------------------------------------------------------------
# SDK plumbing
# ---------------------------------------------------------------------------

def _sdk():
    try:
        import cloudflare  # noqa: F401
        from cloudflare import Cloudflare
        return cloudflare, Cloudflare
    except ImportError as exc:
        raise TunnelError(
            "sdk", "The 'cloudflare' Python package is missing — re-run run.sh to install requirements."
        ) from exc


def _client(api_token: str):
    _, Cloudflare = _sdk()
    return Cloudflare(api_token=api_token, timeout=30, max_retries=2)


def _call(stage: str, permission: str | None, fn, *args, **kwargs):
    """Invoke one SDK call, translating SDK exceptions into TunnelError."""
    cf, _ = _sdk()
    try:
        return fn(*args, **kwargs)
    except cf.AuthenticationError as exc:
        raise TunnelError(stage, "Cloudflare rejected the API token (invalid, expired, or revoked).") from exc
    except cf.PermissionDeniedError as exc:
        need = f" (needs '{permission}')" if permission else ""
        raise TunnelError(stage, f"API token lacks permission{need}: {_msg(exc)}") from exc
    except cf.RateLimitError as exc:
        raise TunnelError(stage, "Cloudflare API rate limit reached — wait a minute and retry.") from exc
    except cf.NotFoundError as exc:
        raise TunnelError(stage, f"Cloudflare returned 404: {_msg(exc)}") from exc
    except cf.APIConnectionError as exc:
        raise TunnelError(stage, "Could not reach the Cloudflare API (network error or timeout).") from exc
    except cf.APIStatusError as exc:
        raise TunnelError(stage, f"Cloudflare API error {exc.status_code}: {_msg(exc)}") from exc
    except TunnelError:
        raise
    except Exception as exc:  # defensive: SDK/model surprises
        raise TunnelError(stage, f"Unexpected error: {exc}") from exc


def _msg(exc) -> str:
    """Short human text from an SDK error (its body carries CF error list)."""
    body = getattr(exc, "body", None)
    if isinstance(body, dict):
        errs = body.get("errors") or []
        if errs:
            return "; ".join(str(e.get("message", e)) for e in errs if isinstance(e, dict)) or str(exc)
    return getattr(exc, "message", None) or str(exc)


def _verify_token(cf) -> None:
    try:
        v = _call("verify", None, cf.user.tokens.verify)
    except TunnelError as exc:
        # A malformed token (wrong length/characters) comes back as a generic
        # 400 "Invalid request headers" rather than a 401 — say what it means.
        if "400" in exc.message:
            raise TunnelError(
                "verify",
                "Cloudflare rejected the API token as malformed — "
                "paste the full token exactly as issued.",
            ) from exc
        raise
    status = getattr(v, "status", None)
    if status != "active":
        raise TunnelError("verify", f"API token is not active (status = '{status}').")


def _find_zone(cf, hostname: str):
    zones = _call("zone", PERM_ZONE_READ, lambda: list(cf.zones.list()))
    matches = [
        z for z in zones
        if hostname == z.name.lower() or hostname.endswith("." + z.name.lower())
    ]
    if not matches:
        names = ", ".join(sorted(z.name for z in zones)) or "none"
        raise TunnelError(
            "zone",
            f"No Cloudflare zone manages '{hostname}'. Zones visible to this token: {names}. "
            f"Check the hostname or add the domain to Cloudflare.",
        )
    return max(matches, key=lambda z: len(z.name))


def _tunnels(cf):
    return cf.zero_trust.tunnels.cloudflared


def _create_tunnel(cf, account_id: str, tunnel_name: str):
    secret = base64.b64encode(secrets.token_bytes(32)).decode("utf-8")
    return _call(
        "tunnel", PERM_TUNNEL_EDIT, _tunnels(cf).create,
        account_id=account_id, name=tunnel_name, config_src="cloudflare", tunnel_secret=secret,
    )


def _get_ingress(cf, account_id: str, tunnel_id: str) -> list[dict]:
    """Current ingress rules (hostname/service dicts), or [] when unset/unreadable."""
    try:
        cfg = _tunnels(cf).configurations.get(tunnel_id, account_id=account_id)
    except Exception:
        return []
    rules = []
    try:
        for r in (cfg.config.ingress or []):
            rules.append({"hostname": getattr(r, "hostname", None), "service": getattr(r, "service", None)})
    except AttributeError:
        return []
    return rules


def _set_ingress(cf, account_id: str, tunnel_id: str, rules: list[dict]) -> None:
    _call(
        "ingress", PERM_TUNNEL_EDIT, _tunnels(cf).configurations.update,
        tunnel_id=tunnel_id, account_id=account_id, config={"ingress": rules},
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def setup_cloudflare_tunnel(
    api_token: str,
    hostname: str,
    url: str,
    port: int | str | None = None,
    tunnel_name: str | None = None,
) -> TunnelResult:
    """Create (or reuse) a cloud-managed tunnel routing `hostname` -> `url`.

    An existing tunnel with the same name is reused when it is cloud-managed;
    a local-managed one is deleted and recreated. Ingress rules for other
    hostnames on that tunnel are preserved. Any existing DNS record for the
    hostname is replaced by the tunnel CNAME.
    """
    token = (api_token or "").strip()
    if not token:
        raise TunnelError("input", "Cloudflare API token is required.")
    hostname = normalize_hostname(hostname)
    service_url = normalize_service_url(url, port)
    tunnel_name = (tunnel_name or "").strip() or default_tunnel_name(hostname)

    cf = _client(token)
    _verify_token(cf)

    zone = _find_zone(cf, hostname)
    zone_id, zone_name, account_id = zone.id, zone.name, zone.account.id

    # --- tunnel: reuse / recreate / create --------------------------------
    existing = _call(
        "tunnel", PERM_TUNNEL_EDIT,
        lambda: list(_tunnels(cf).list(account_id=account_id, is_deleted=False)),
    )
    target = next((t for t in existing if t.name == tunnel_name), None)
    if target and getattr(target, "config_src", "cloudflare") == "cloudflare":
        tunnel_id = target.id
    else:
        if target:
            # Local-managed tunnel cannot take remote ingress config; recreate it.
            _call("tunnel", PERM_TUNNEL_EDIT, _tunnels(cf).delete, target.id, account_id=account_id)
        tunnel_id = _create_tunnel(cf, account_id, tunnel_name).id

    # --- ingress ---------------------------------------------------------
    others = [
        r for r in _get_ingress(cf, account_id, tunnel_id)
        if r["hostname"] and r["hostname"] != hostname and r["service"] != CATCH_ALL
    ]
    _set_ingress(cf, account_id, tunnel_id, [
        *others,
        {"hostname": hostname, "service": service_url},
        {"service": CATCH_ALL},
    ])

    # --- DNS CNAME -------------------------------------------------------
    target_cname = f"{tunnel_id}.cfargotunnel.com"
    records = _call(
        "dns", PERM_DNS_EDIT,
        lambda: list(cf.dns.records.list(zone_id=zone_id, name=hostname)),
    )
    if not records:
        rec = _call(
            "dns", PERM_DNS_EDIT, cf.dns.records.create,
            zone_id=zone_id, name=hostname, type="CNAME", content=target_cname,
            proxied=True, ttl=1, comment=DNS_COMMENT,
        )
        dns_record_id = rec.id
    else:
        primary = records[0]
        dns_record_id = primary.id
        if primary.type != "CNAME" or primary.content != target_cname or not primary.proxied:
            _call(
                "dns", PERM_DNS_EDIT, cf.dns.records.edit,
                dns_record_id=primary.id, zone_id=zone_id, name=hostname, type="CNAME",
                content=target_cname, proxied=True, ttl=1, comment=DNS_COMMENT,
            )
        # Conflicting duplicates (old A records, etc.) — best effort cleanup.
        for extra in records[1:]:
            try:
                cf.dns.records.delete(dns_record_id=extra.id, zone_id=zone_id)
            except Exception:
                pass

    # --- tunnel token ----------------------------------------------------
    tunnel_token = _call("token", PERM_TUNNEL_EDIT, _tunnels(cf).token.get, tunnel_id, account_id=account_id)

    return TunnelResult(
        token=str(tunnel_token),
        tunnel_id=tunnel_id,
        tunnel_name=tunnel_name,
        hostname=hostname,
        service_url=service_url,
        zone_id=zone_id,
        zone_name=zone_name,
        account_id=account_id,
        dns_record_id=dns_record_id or "",
    )


def delete_cloudflare_tunnel(api_token: str, hostname: str, tunnel_id: str) -> dict:
    """Remove the hostname's CNAME and ingress rule; delete the tunnel if unused.

    Returns {"dns_deleted": int, "ingress_updated": bool, "tunnel_deleted": bool}.
    """
    token = (api_token or "").strip()
    if not token:
        raise TunnelError("input", "Cloudflare API token is required.")
    hostname = normalize_hostname(hostname)
    tunnel_id = (tunnel_id or "").strip()
    if not tunnel_id:
        raise TunnelError("input", "Tunnel ID is missing from the service metadata.")

    cf = _client(token)
    _verify_token(cf)
    zone = _find_zone(cf, hostname)
    zone_id, account_id = zone.id, zone.account.id

    # DNS: only remove the CNAME we created (pointing at this tunnel).
    target_cname = f"{tunnel_id}.cfargotunnel.com"
    records = _call(
        "dns", PERM_DNS_EDIT,
        lambda: list(cf.dns.records.list(zone_id=zone_id, name=hostname)),
    )
    dns_deleted = 0
    for rec in records:
        if rec.type == "CNAME" and rec.content == target_cname:
            _call("dns", PERM_DNS_EDIT, cf.dns.records.delete, dns_record_id=rec.id, zone_id=zone_id)
            dns_deleted += 1

    # Ingress: drop our rule; keep the tunnel if other hostnames still use it.
    rules = _get_ingress(cf, account_id, tunnel_id)
    others = [r for r in rules if r["hostname"] and r["hostname"] != hostname and r["service"] != CATCH_ALL]
    ingress_updated = False
    tunnel_deleted = False
    if others:
        _set_ingress(cf, account_id, tunnel_id, [*others, {"service": CATCH_ALL}])
        ingress_updated = True
    else:
        try:
            # Clear stale connections first so the delete does not 400.
            try:
                _tunnels(cf).connections.delete(tunnel_id, account_id=account_id)
            except Exception:
                pass
            _call("tunnel", PERM_TUNNEL_EDIT, _tunnels(cf).delete, tunnel_id, account_id=account_id)
            tunnel_deleted = True
        except TunnelError as exc:
            if "404" not in exc.message:
                raise
            tunnel_deleted = True  # already gone

    return {"dns_deleted": dns_deleted, "ingress_updated": ingress_updated, "tunnel_deleted": tunnel_deleted}
