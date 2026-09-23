/** Host metrics — also feeds the hostname chip in the header. */
import { defineStore } from 'pinia';

import { endpoints, fetchData } from '@/api/client';
import type { DiskPartition, Host, SystemInfo } from '@/api/types';

import { createResource } from './resource';

const EMPTY_HOST: Host = {
  hostname: '',
  kernel: '',
  distro: '',
  timezone: '',
  uptime: '',
  cpu: { usage: 0, cores: 0, threads: 0, load: [0, 0, 0] },
  ram: { used: 0, total: 0, pct: 0 },
  disk: { used: 0, total: 0, pct: 0 },
  swap: { used: 0, total: 0, pct: 0 },
  network: [],
};

function toHost(info: SystemInfo): Host {
  return {
    hostname: info.hostname,
    kernel: info.kernel,
    distro: info.os_name,
    timezone: info.timezone,
    uptime: info.uptime,
    cpu: {
      usage: info.cpu_percent,
      cores: info.cpu_count_physical,
      threads: info.cpu_count,
      load: [info.load_1, info.load_5, info.load_15],
    },
    ram: { used: info.ram_used_gb, total: info.ram_total_gb, pct: info.ram_percent },
    disk: { used: info.disk_used_gb, total: info.disk_total_gb, pct: info.disk_percent },
    swap: { used: info.swap_used_gb, total: info.swap_total_gb, pct: info.swap_percent },
    network: (info.ips ?? []).map((ip) => ({
      iface: ip.iface,
      ip: ip.ip,
      prefix: ip.prefix ?? null,
      cidr: ip.cidr || ip.ip,
      method: ip.method || 'unknown',
      gateway: ip.gateway || '',
      dns: ip.dns || [],
    })),
  };
}

export const useSystemStore = defineStore('system', () => {
  const host = createResource<Host>(EMPTY_HOST, async () =>
    toHost(await fetchData<SystemInfo>(endpoints.system)),
  );
  const disks = createResource<DiskPartition[]>([], () =>
    fetchData<DiskPartition[]>(endpoints.disks),
  );

  return {
    host: host.data,
    loadingHost: host.loading,
    hostLoaded: host.loaded,
    load: host.load,
    disks: disks.data,
    loadingDisks: disks.loading,
    loadDisks: disks.load,
  };
});
