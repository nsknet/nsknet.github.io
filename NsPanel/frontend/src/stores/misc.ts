/** The small single-purpose stores: DNS, firewall, audit log and processes. */
import { defineStore } from 'pinia';
import { ref } from 'vue';

import { endpoints, fetchData } from '@/api/client';
import type { FirewallState, Process } from '@/api/system';
import type { DnsState } from '@/api/types';

import { createResource, type LoadOptions } from './resource';

const EMPTY_DNS: DnsState = {
  installed: false,
  running: false,
  version: null,
  hosts_file: '',
  records: [],
};

export const useDnsStore = defineStore('dns', () => {
  const dns = createResource<DnsState>(EMPTY_DNS, () => fetchData<DnsState>(endpoints.dns));
  return { dns: dns.data, loading: dns.loading, loaded: dns.loaded, error: dns.error, load: dns.load };
});

const EMPTY_FIREWALL: FirewallState = {
  installed: false,
  enabled: false,
  rules: [],
  defaults: {},
  ssh_ports: [],
  panel_port: 0,
  client_ip: '',
};

export const useFirewallStore = defineStore('firewall', () => {
  const firewall = createResource<FirewallState>(EMPTY_FIREWALL, async () => {
    const state = await fetchData<Partial<FirewallState>>(endpoints.firewall);
    return {
      ...EMPTY_FIREWALL,
      ...state,
      rules: state.rules ?? [],
      defaults: state.defaults ?? {},
      ssh_ports: state.ssh_ports?.length ? state.ssh_ports : [22],
    };
  });
  return {
    firewall: firewall.data,
    loading: firewall.loading,
    loaded: firewall.loaded,
    error: firewall.error,
    load: firewall.load,
  };
});

export const useProcessesStore = defineStore('processes', () => {
  /** The search term; filtering happens server-side. */
  const query = ref('');
  // createResource applies only the newest response, so a slow answer to an
  // older search never overwrites the list for the current one.
  const processes = createResource<Process[]>([], () =>
    fetchData<Process[]>(endpoints.processes, query.value ? { q: query.value } : undefined),
  );

  /** Reload with the current search term (polls pass `{ silent: true }`). */
  function load(options: LoadOptions = {}): Promise<void> {
    return processes.load(options);
  }

  /** Change the search term and load its results. */
  function search(term: string, options: LoadOptions = {}): Promise<void> {
    query.value = term.trim();
    return processes.load(options);
  }

  return {
    processes: processes.data,
    loading: processes.loading,
    loaded: processes.loaded,
    error: processes.error,
    query,
    load,
    search,
  };
});
