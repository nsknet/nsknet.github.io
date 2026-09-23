/** The small single-purpose stores: DNS, firewall, audit log and processes. */
import { defineStore } from 'pinia';

import { endpoints, fetchData } from '@/api/client';
import type {
  AuditEntry,
  DnsState,
  FirewallRule,
  ProcessRow,
  RawFirewallRule,
  UfwInfo,
} from '@/api/types';

import { createResource } from './resource';

const EMPTY_DNS: DnsState = {
  installed: false,
  running: false,
  version: null,
  hosts_file: '',
  records: [],
};

export const useDnsStore = defineStore('dns', () => {
  const dns = createResource<DnsState>(EMPTY_DNS, () => fetchData<DnsState>(endpoints.dns));
  return { dns: dns.data, loading: dns.loading, loaded: dns.loaded, load: dns.load };
});

function toRule(rule: RawFirewallRule): FirewallRule {
  return {
    idx: rule.num,
    port: rule.to,
    action: rule.action,
    from: rule.from_,
    v6: rule.is_v6,
    label: rule.label,
  };
}

export const useFirewallStore = defineStore('firewall', () => {
  const firewall = createResource<{ active: boolean; rules: FirewallRule[] }>(
    { active: false, rules: [] },
    async () => {
      const ufw = await fetchData<UfwInfo>(endpoints.firewall);
      return { active: !!ufw.enabled, rules: (ufw.rules ?? []).map(toRule) };
    },
  );
  return {
    firewall: firewall.data,
    loading: firewall.loading,
    loaded: firewall.loaded,
    load: firewall.load,
  };
});

/** `2026-09-22T10:11:12Z | service.start | name=demo job=abc` → a rendered row. */
function parseAuditLine(line: string): AuditEntry {
  const [timestamp = '', action = '', detail = ''] = line.split(' | ');
  const details: Record<string, string | number> = {};

  if (detail) {
    const pairs = detail.matchAll(/([a-zA-Z0-9_-]+)=([^=\s]+|"[^"]*")/g);
    let matched = false;
    for (const [, key, rawValue] of pairs) {
      matched = true;
      const unquoted = rawValue.replace(/^"(.*)"$/, '$1');
      details[key] =
        unquoted.trim() !== '' && !Number.isNaN(Number(unquoted)) ? Number(unquoted) : unquoted;
    }
    if (!matched) details.info = detail;
  }

  return { t: timestamp.replace('T', ' ').replace('Z', ''), a: action, d: details };
}

export const useLogsStore = defineStore('logs', () => {
  const logs = createResource<AuditEntry[]>([], async () =>
    (await fetchData<string[]>(endpoints.logs)).map(parseAuditLine),
  );
  return { audit: logs.data, loading: logs.loading, loaded: logs.loaded, load: logs.load };
});

export const useProcessesStore = defineStore('processes', () => {
  // The search box filters server-side; load() stores the term for the loader.
  let query = '';
  const processes = createResource<ProcessRow[]>([], () =>
    fetchData<ProcessRow[]>(endpoints.processes, query ? { q: query } : undefined),
  );

  async function load(search = ''): Promise<void> {
    query = search.trim();
    await processes.load();
  }

  return {
    processes: processes.data,
    loading: processes.loading,
    loaded: processes.loaded,
    load,
  };
});
