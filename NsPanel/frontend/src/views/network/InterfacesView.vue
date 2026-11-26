<script setup lang="ts">
/** Network interfaces: link state, IPv4 addressing, and DHCP/static changes. */
import { storeToRefs } from 'pinia';
import { computed } from 'vue';

import type { NetInterface } from '@/api/system';
import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import CardHeader from '@/components/ui/CardHeader.vue';
import DataTable from '@/components/ui/DataTable.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import type { Column } from '@/components/ui/types';
import { useJobRunner } from '@/composables/useJobs';
import { useRefresh } from '@/composables/useRefresh';
import { useSystemStore } from '@/stores/system';
import { useUiStore } from '@/stores/ui';

const ui = useUiStore();
const { run } = useJobRunner();
const { refresh, refreshing } = useRefresh();
const system = useSystemStore();
const { interfaces, loadingHost, hostError } = storeToRefs(system);

const columns: Column<NetInterface>[] = [
  { key: 'iface', label: 'Interface', sortable: true },
  { key: 'cidr', label: 'Address', sortable: true },
  { key: 'method', label: 'Method', sortable: true },
  { key: 'gateway', label: 'Gateway', class: 'mono text-c-tx2' },
  { key: 'dns', label: 'DNS', hideOnMobile: true },
  {
    key: 'speed_mbps',
    label: 'Speed',
    align: 'right',
    hideOnMobile: true,
    sortable: true,
    sortValue: (r) => r.speed_mbps ?? 0,
  },
  { key: 'mtu', label: 'MTU', align: 'right', hideOnMobile: true, class: 'num' },
  { key: 'actions', label: 'Actions', srOnlyLabel: true, align: 'right' },
];

const upCount = computed(() => new Set(interfaces.value.filter((i) => i.up).map((i) => i.iface)).size);
const ifaceCount = computed(() => new Set(interfaces.value.map((i) => i.iface)).size);

const METHOD_LABEL: Record<string, string> = { dhcp: 'DHCP', static: 'Static', manual: 'Static' };

function speed(mbps: number | null): string {
  if (!mbps) return '—';
  return mbps >= 1000 ? `${mbps / 1000} Gb/s` : `${mbps} Mb/s`;
}

function configure(row: NetInterface): void {
  ui.openNetworkDialog(row.iface, row, (values) =>
    // Returning the promise keeps the dialog open if the request fails.
    run('/api/v1/system/set-network', values, {
      title:
        values.method === 'dhcp' ? `Set ${values.iface} → DHCP` : `Set ${values.iface} → ${values.address}`,
    }),
  );
}
</script>

<template>
  <section>
    <PageHeader
      title="Interfaces"
      :subtitle="
        interfaces.length
          ? `${ifaceCount} interface${ifaceCount === 1 ? '' : 's'} with IPv4 · ${upCount} up`
          : 'IPv4 addresses on this host and how they are assigned.'
      "
    >
      <Btn :loading="refreshing" @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
    </PageHeader>

    <Card class="overflow-clip">
      <CardHeader title="IPv4 interfaces" icon="network" subtitle="Loopback is not listed" />
      <DataTable
        :columns="columns"
        :rows="interfaces"
        :row-key="(row) => `${row.iface}-${row.ip}`"
        label="Network interfaces"
        :loading="loadingHost"
        :error="hostError"
        sort-key="iface"
        empty-icon="network"
        empty-title="No IPv4 interfaces"
        empty-hint="psutil reported no IPv4 address other than loopback."
        :row-muted="(row) => !row.up"
        @retry="system.load()"
      >
        <template #cell-iface="{ row }">
          <span class="inline-flex items-center gap-2">
            <span class="mono font-semibold">{{ row.iface }}</span>
            <Badge :tone="row.up ? 'ok' : 'danger'" dot>{{ row.up ? 'up' : 'down' }}</Badge>
          </span>
        </template>
        <template #cell-cidr="{ row }">
          <span class="mono">{{ row.cidr || row.ip }}</span>
        </template>
        <template #cell-method="{ row }">
          <Badge :tone="row.method === 'dhcp' ? 'info' : row.method === 'static' ? 'accent' : 'muted'">
            {{ METHOD_LABEL[row.method] ?? 'Not managed' }}
          </Badge>
        </template>
        <template #cell-gateway="{ row }">
          <span class="mono text-c-tx2">{{ row.gateway || '—' }}</span>
        </template>
        <template #cell-dns="{ row }">
          <span class="mono text-xs-var text-c-tx2">{{ row.dns.length ? row.dns.join(', ') : '—' }}</span>
        </template>
        <template #cell-speed_mbps="{ row }">
          <span class="tabular-nums text-c-tx2">{{ speed(row.speed_mbps) }}</span>
        </template>
        <template #cell-mtu="{ row }">
          <span class="tabular-nums text-c-tx2">{{ row.mtu ?? '—' }}</span>
        </template>
        <template #cell-actions="{ row }">
          <Btn sm :aria-label="`Configure ${row.iface}`" @click="configure(row)">
            <LIcon name="settings" /> Configure
          </Btn>
        </template>
      </DataTable>
    </Card>

    <p class="mt-3 mb-0 text-xs-var text-c-tx2">
      “Not managed” means no netplan file sets this interface (for example a VPN or Docker bridge). Configure
      writes <span class="mono">/etc/netplan/90-nspanel-&lt;iface&gt;.yaml</span> and keeps a backup.
    </p>
  </section>
</template>
