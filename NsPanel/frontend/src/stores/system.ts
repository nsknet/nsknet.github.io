/** Host metrics, network interfaces, disks and the timezone list.
 *  `host` also feeds the hostname chip in the header. */
import { defineStore } from 'pinia';
import { computed } from 'vue';

import { endpoints, fetchData } from '@/api/client';
import type { DiskNode, NetInterface, RawNetInterface, SystemInfoFull } from '@/api/system';
import type { Host } from '@/api/types';

import { createResource } from './resource';

const EMPTY_INFO: SystemInfoFull = {
  hostname: '',
  kernel: '',
  os_name: '',
  timezone: '',
  uptime: '',
  cpu_percent: 0,
  cpu_count: 0,
  cpu_count_physical: 0,
  load_1: 0,
  load_5: 0,
  load_15: 0,
  ram_used_gb: 0,
  ram_total_gb: 0,
  ram_percent: 0,
  disk_used_gb: 0,
  disk_total_gb: 0,
  disk_percent: 0,
  swap_used_gb: 0,
  swap_total_gb: 0,
  swap_percent: 0,
  architecture: '',
  ips: [],
};

function toInterface(ip: RawNetInterface): NetInterface {
  return {
    iface: ip.iface,
    ip: ip.ip,
    prefix: ip.prefix ?? null,
    cidr: ip.cidr || ip.ip,
    method: ip.method || 'unknown',
    gateway: ip.gateway || '',
    dns: ip.dns || [],
    up: ip.up ?? false,
    speed_mbps: ip.speed_mbps ?? null,
    mtu: ip.mtu ?? null,
  };
}

function toHost(info: SystemInfoFull, network: NetInterface[]): Host {
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
    network,
  };
}

export const useSystemStore = defineStore('system', () => {
  const info = createResource<SystemInfoFull>(EMPTY_INFO, () =>
    fetchData<SystemInfoFull>(endpoints.system),
  );
  const disks = createResource<DiskNode[]>([], () => fetchData<DiskNode[]>(endpoints.disks));
  const timezones = createResource<string[]>([], () => fetchData<string[]>(endpoints.timezones));

  /** Every IPv4 address on the host, with link state, speed and MTU. */
  const interfaces = computed(() => (info.data.value.ips ?? []).map(toInterface));
  const host = computed(() => toHost(info.data.value, interfaces.value));
  const architecture = computed(() => info.data.value.architecture ?? '');

  return {
    host,
    interfaces,
    architecture,
    loadingHost: info.loading,
    hostLoaded: info.loaded,
    hostError: info.error,
    load: info.load,
    disks: disks.data,
    loadingDisks: disks.loading,
    disksLoaded: disks.loaded,
    disksError: disks.error,
    loadDisks: disks.load,
    timezones: timezones.data,
    loadingTimezones: timezones.loading,
    timezonesLoaded: timezones.loaded,
    timezonesError: timezones.error,
    loadTimezones: timezones.load,
  };
});
