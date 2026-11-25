/** Nginx sites, flattened into the shape the screens render. */
import { defineStore } from 'pinia';
import { computed } from 'vue';

import type { PortOwner, SiteApp } from '@/api/apps';
import { endpoints, fetchData } from '@/api/client';
import type { RawSite } from '@/api/types';

import { createResource } from './resource';

/** "example.com → :5000" — the one-line summary shown in the apps table. */
function accessLabel(site: RawSite): string {
  const target = site.backend?.proxy_target;
  const port = target?.match(/:(\d+)$/)?.[1];
  const arrow = target ? ` → ${port ? `:${port}` : target}` : '';

  if (site.access.kind === 'domain') return `${site.access.value}${arrow}`;
  if (site.access.kind === 'port') return `:${site.access.value}${arrow}`;
  return '';
}

/** Raw API site → view model. Exported for the Overview, whose dashboard call carries sites too. */
export function toSite(site: RawSite): SiteApp {
  let dll = site.backend?.dll ?? '';
  if (dll && !dll.endsWith('.dll')) dll += '.dll';

  return {
    slug: site.name,
    name: site.name,
    type: site.type,
    access: accessLabel(site),
    accessKind: site.access?.kind ?? '',
    accessValue: String(site.access?.value ?? ''),
    status: site.status?.badge || 'unknown',
    pid: site.status?.pid ?? null,
    autostart: site.status?.enabled ?? null,
    mem: site.status?.memory_mb ?? null,
    cpu: site.status?.cpu_percent ?? null,
    modified: site.last_modified ?? '',
    dll,
    internalPort: site.backend?.internal_port ?? null,
    env: site.backend?.aspnetcore_env ?? null,
    created: site.created_at ?? '',
    configPath: site.paths?.nginx_conf ?? '',
    unitPath: site.paths?.systemd_unit ?? '',
    webRoot: site.paths?.public ?? '',
    logDir: (site.paths as { log_dir?: string } | undefined)?.log_dir ?? '',
    proxyTarget: site.backend?.proxy_target ?? null,
  };
}

export const useSitesStore = defineStore('sites', () => {
  const sites = createResource<SiteApp[]>([], async () =>
    (await fetchData<RawSite[]>(endpoints.sites)).map(toSite),
  );

  /** Every port a site already takes: the public port of port-mode sites and
   *  the internal Kestrel port of .NET sites. */
  const portOwners = computed<PortOwner[]>(() => {
    const owners: PortOwner[] = [];
    for (const site of sites.data.value) {
      if (site.accessKind === 'port' && /^\d+$/.test(site.accessValue)) {
        owners.push({ port: Number(site.accessValue), owner: site.name, role: `public port of site ${site.name}` });
      }
      const internal = Number(site.internalPort);
      if (Number.isFinite(internal) && internal > 0) {
        owners.push({ port: internal, owner: site.name, role: `internal port of site ${site.name}` });
      }
    }
    return owners;
  });

  const usedPorts = computed(() => portOwners.value.map((owner) => owner.port));

  function bySlug(slug: string): SiteApp | undefined {
    return sites.data.value.find((site) => site.slug === slug);
  }

  return {
    sites: sites.data,
    loading: sites.loading,
    loaded: sites.loaded,
    error: sites.error,
    load: sites.load,
    portOwners,
    usedPorts,
    bySlug,
  };
});
