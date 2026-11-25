/** Panel-managed systemd units, including Cloudflare tunnels. */
import { defineStore } from 'pinia';

import type { ServiceApp } from '@/api/apps';
import { endpoints, fetchData } from '@/api/client';
import type { RawService } from '@/api/types';

import { createResource } from './resource';

function toService(raw: RawService): ServiceApp {
  return {
    name: raw.name,
    desc: raw.description || '',
    status: raw.state,
    autostart: raw.enabled,
    mem: raw.memory_mb ?? null,
    cpu: raw.cpu_percent ?? null,
    pid: raw.pid ?? null,
    modified: raw.last_edit,
    cmd: raw.exec_start ?? '',
    path: raw.path,
    content: raw.content,
    workingDir: raw.working_dir,
    user: raw.user,
    restart: raw.restart,
    restartSec: raw.restart_sec,
    syslogId: raw.syslog_id,
    envVars: raw.env_vars ?? [],
    // Present only for cloudflared.<hostname> units the panel created
    // (parsed from the X-NsPanel-Tunnel-* keys in the unit file).
    tunnel: raw.tunnel ?? null,
    isTunnel: !!raw.tunnel || raw.name.startsWith('cloudflared.'),
  };
}

export const useServicesStore = defineStore('services', () => {
  const services = createResource<ServiceApp[]>([], async () =>
    (await fetchData<RawService[]>(endpoints.services)).map(toService),
  );

  function byName(name: string): ServiceApp | undefined {
    return services.data.value.find((service) => service.name === name);
  }

  return {
    services: services.data,
    loading: services.loading,
    loaded: services.loaded,
    error: services.error,
    load: services.load,
    byName,
  };
});
