/** Installable tools, with their version strings tidied for display. */
import { defineStore } from 'pinia';

import { endpoints, fetchData } from '@/api/client';
import type { RawTool, Tool } from '@/api/types';

import { createResource } from './resource';

/** Tool version commands print a sentence; show just the number when we find one. */
function shortVersion(raw: string | null): string | null {
  if (!raw) return null;
  const number = raw.match(/\d+\.\d+(?:\.\d+)*\b/);
  if (number) return number[0];

  let version = raw.replace('nginx/', '');
  const postgres = version.indexOf('PostgreSQL) ');
  if (postgres >= 0) version = version.slice(postgres + 'PostgreSQL) '.length);
  const leadingV = version.match(/\bv(\d+)/i);
  if (leadingV) version = version.slice(version.indexOf(leadingV[0]) + 1);
  return version || null;
}

function toTool(raw: RawTool): Tool {
  const { module, status } = raw;
  const extra = Object.entries(status.extra ?? {});
  return {
    id: module.name,
    name: module.display_name,
    desc: module.description,
    installed: status.installed,
    version: shortVersion(status.version),
    state: status.service_state === 'n/a' && status.installed ? 'installed' : status.service_state,
    ports: status.ports?.length ? status.ports.join(', ') : null,
    logo: module.logo ? `/logo/${module.logo}` : module.name.slice(0, 2).toUpperCase(),
    color: '#6b7280',
    diag: extra.length ? (extra as [string, string][]) : undefined,
    requiresPassword: module.requires_password,
    firewallPorts: module.firewall_ports ?? [],
    installParams: module.install_params ?? [],
    canUninstall: module.can_uninstall,
    canChangePassword: module.can_change_password,
  };
}

export const useToolsStore = defineStore('tools', () => {
  const tools = createResource<Tool[]>([], async () =>
    (await fetchData<RawTool[]>(endpoints.tools)).map(toTool),
  );

  return {
    tools: tools.data,
    loading: tools.loading,
    loaded: tools.loaded,
    load: tools.load,
  };
});
