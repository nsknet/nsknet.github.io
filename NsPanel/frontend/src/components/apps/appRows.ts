/** Sites and services folded into one list of apps, plus the small formatters
 *  the Apps screens share. */
import type { AppRow, AppState, AppType, ServiceApp, SiteApp } from '@/api/apps';
import { apiPath } from '@/utils/format';

/** Server timestamps arrive as "YYYY-MM-DD HH:MM" (server-local) → epoch ms, 0 if unparsable. */
export function parseModified(value: string | null | undefined): number {
  if (!value) return 0;
  const ms = Date.parse(value.trim().replace(' ', 'T'));
  return Number.isNaN(ms) ? 0 : ms;
}

/** systemctl's ActiveState → the coarse state. */
export function serviceState(status: string): AppState {
  if (status === 'active') return 'up';
  if (status === 'failed') return 'failed';
  if (status === 'inactive') return 'stopped';
  return 'other';
}

/** Site badge (running | ok | failed | stopped | configured | unknown) → the coarse state. */
export function siteState(status: string): AppState {
  if (status === 'running' || status === 'ok') return 'up';
  if (status === 'failed') return 'failed';
  if (status === 'stopped') return 'stopped';
  return 'other';
}

/** Service status label: systemd says active/inactive, people say running/stopped. */
export function serviceStatusLabel(status: string): string {
  if (status === 'active') return 'running';
  if (status === 'inactive') return 'stopped';
  return status || 'unknown';
}

export function fmtMem(mb: number | null | undefined, running: boolean): string {
  if (!running || mb === null || mb === undefined) return '—';
  return mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${mb.toFixed(mb < 10 ? 1 : 0)} MB`;
}

export function fmtCpu(cpu: number | null | undefined, running: boolean): string {
  if (!running || cpu === null || cpu === undefined) return '—';
  return `${cpu.toFixed(1)}%`;
}

export const TYPE_LABEL: Record<AppType, string> = {
  static: 'Static site',
  proxy: 'Reverse proxy',
  dotnet: '.NET site',
  service: 'Service',
  tunnel: 'Cloudflare tunnel',
};

export function siteRow(site: SiteApp): AppRow {
  const state = siteState(site.status);
  const running = site.type === 'dotnet' && state === 'up';
  return {
    key: `site:${site.name}`,
    kind: 'site',
    type: (['static', 'proxy', 'dotnet'].includes(site.type) ? site.type : 'static') as AppType,
    name: site.name,
    target: site.access,
    status: site.status,
    state,
    mem: running ? site.mem : null,
    cpu: running ? site.cpu : null,
    modified: site.modified,
    modifiedAt: parseModified(site.modified),
    to: apiPath`/apps/site/${site.name}`,
  };
}

export function serviceRow(service: ServiceApp): AppRow {
  const state = serviceState(service.status);
  const running = state === 'up';
  return {
    key: `service:${service.name}`,
    kind: 'service',
    type: service.isTunnel ? 'tunnel' : 'service',
    name: service.name,
    // Tunnel units run cloudflared with a token: show the route, not the command.
    target: service.tunnel ? `${service.tunnel.hostname} → ${service.tunnel.service_url}` : service.cmd,
    status: serviceStatusLabel(service.status),
    state,
    mem: running ? service.mem : null,
    cpu: running ? service.cpu : null,
    modified: service.modified,
    modifiedAt: parseModified(service.modified),
    to: apiPath`/apps/service/${service.name}`,
  };
}

/** Sites first, then services. A .NET site's own unit lives in the services
 *  directory too; it is represented by the site row, so it is not listed twice. */
export function buildApps(sites: SiteApp[], services: ServiceApp[]): AppRow[] {
  const dotnetSites = new Set(sites.filter((site) => site.type === 'dotnet').map((site) => site.name));
  return [
    ...sites.map(siteRow),
    ...services.filter((service) => !dotnetSites.has(service.name)).map(serviceRow),
  ];
}

/** A timestamped, filesystem-safe name for a downloaded log. */
export function logFileName(host: string, name: string, what = 'log'): string {
  const safe = (value: string) => value.replace(/[^a-zA-Z0-9._-]/g, '_');
  const pad = (value: number) => String(value).padStart(2, '0');
  const now = new Date();
  const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  return `${safe(host || 'server')}-${safe(name)}-${safe(what)}-${stamp}.log`;
}
