/** Nginx sites, flattened into the shape the screens render. */
import { defineStore } from 'pinia';
import { computed } from 'vue';

import { endpoints, fetchData } from '@/api/client';
import type { RawSite, Site } from '@/api/types';

import { createResource } from './resource';

/** "example.com → :5000" — the one-line summary shown in the sites table. */
function accessLabel(site: RawSite): string {
  const target = site.backend?.proxy_target;
  const port = target?.match(/:(\d+)$/)?.[1];
  const arrow = target ? ` → ${port ? `:${port}` : target}` : '';

  if (site.access.kind === 'domain') return `${site.access.value}${arrow}`;
  if (site.access.kind === 'port') return `:${site.access.value}${arrow}`;
  return '';
}

function toSite(site: RawSite): Site {
  let dll = site.backend?.dll ?? '';
  if (dll && !dll.endsWith('.dll')) dll += '.dll';

  return {
    slug: site.name,
    name: site.name,
    type: site.type,
    access: accessLabel(site),
    status: site.status.badge || 'ok',
    pid: site.status.pid ?? null,
    autostart: site.status.enabled ?? null,
    mem: site.status.memory_mb ?? null,
    cpu: site.status.cpu_percent ?? null,
    modified: site.last_modified ?? '',
    dll,
    internalPort: site.backend?.internal_port ?? null,
    env: site.backend?.aspnetcore_env ?? null,
    created: site.created_at ? site.created_at.slice(0, 10) : '',
    configPath: site.paths?.nginx_conf ?? '',
    unitPath: site.paths?.systemd_unit ?? '',
    webRoot: site.paths?.public ?? '',
    proxyTarget: site.backend?.proxy_target ?? null,
  };
}

export const useSitesStore = defineStore('sites', () => {
  const sites = createResource<Site[]>([], async () =>
    (await fetchData<RawSite[]>(endpoints.sites)).map(toSite),
  );

  const usedPorts = computed(() =>
    sites.data.value
      .map((site) => Number(site.internalPort))
      .filter((port) => Number.isFinite(port) && port > 0),
  );

  function bySlug(slug: string): Site | undefined {
    return sites.data.value.find((site) => site.slug === slug);
  }

  return {
    sites: sites.data,
    loading: sites.loading,
    loaded: sites.loaded,
    load: sites.load,
    usedPorts,
    bySlug,
  };
});
