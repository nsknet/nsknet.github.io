<script setup lang="ts">
/** The audit trail, filtered by namespace (`service.*`, `site.*`, …). */
import { storeToRefs } from 'pinia';
import { computed, ref } from 'vue';

import EmptyState from '@/components/ui/EmptyState.vue';
import LIcon from '@/components/ui/LIcon.vue';
import Spinner from '@/components/ui/Spinner.vue';
import Btn from '@/components/ui/Btn.vue';
import { useReload } from '@/composables/useScreenData';
import { useLogsStore } from '@/stores/misc';
import { useUiStore } from '@/stores/ui';

const ui = useUiStore();
const reload = useReload();
const { audit, loading } = storeToRefs(useLogsStore());

const NAMESPACES = ['all', 'service', 'site', 'nginx', 'firewall', 'system', 'tool'];

const NS_CLS: Record<string, string> = {
  service: 'bg-c-infosoft text-c-info',
  site: 'bg-[color-mix(in_oklab,#8b5cf6_12%,transparent)] text-[#8b5cf6]',
  nginx: 'bg-[color-mix(in_oklab,#16a34a_12%,transparent)] text-[#16a34a]',
  firewall: 'bg-c-dngsoft text-c-danger',
  system: 'bg-c-warnsoft text-c-warn',
  tool: 'bg-c-acsoft text-c-accent',
};

const namespace = ref('all');
const search = ref('');

const filtered = computed(() => {
  const query = search.value.toLowerCase();
  return audit.value.filter((row) => {
    if (namespace.value !== 'all' && !row.a.startsWith(`${namespace.value}.`)) return false;
    if (!query) return true;
    return `${row.a} ${JSON.stringify(row.d)}`.toLowerCase().includes(query);
  });
});

const countLabel = computed(() =>
  filtered.value.length === audit.value.length
    ? String(audit.value.length)
    : `${filtered.value.length} of ${audit.value.length}`,
);

function namespaceOf(action: string): string {
  return action.split('.')[0];
}

function detailParts(detail: Record<string, string | number>) {
  return Object.entries(detail).map(([key, value]) => ({
    key,
    value: typeof value === 'string' ? value : JSON.stringify(value),
  }));
}

async function refresh(): Promise<void> {
  await reload();
  ui.addToast({ t: 'Logs refreshed', k: 'info' });
}
</script>

<template>
  <section>
    <div class="flex items-end justify-between gap-6 mb-6">
      <div>
        <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">Audit logs</h1>
        <div class="text-sm-var text-c-tx2">
          {{ countLabel }} entries · tailing
          <span class="mono">/var/log/nspanel/audit.log</span>
        </div>
      </div>
      <div class="flex gap-2">
        <Btn @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
      </div>
    </div>

    <div class="flex items-center gap-2 mb-3 flex-wrap">
      <div class="relative flex-1 max-w-xs">
        <LIcon
          name="search"
          is="position:absolute;left:10px;top:50%;transform:translateY(-50%);pointer-events:none;color:var(--text-3);width:14px;height:14px"
        />
        <input v-model="search" class="input h-8 pl-[30px]" placeholder="Search action or detail…" />
      </div>
      <button
        v-for="key in NAMESPACES"
        :key="key"
        :class="[
          'h-7 px-2.5 rounded-full border text-xs-var mono cursor-pointer inline-flex items-center gap-1 transition-colors',
          namespace === key
            ? 'bg-c-tx text-c-txinv border-c-tx'
            : 'bg-c-bg text-c-tx2 border-c-border hover:text-c-tx hover:border-c-bstrong',
        ]"
        @click="namespace = key"
      >
        {{ key === 'all' ? 'all' : `${key}.*` }}
      </button>
    </div>

    <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
      <table class="tbl">
        <thead>
          <tr>
            <th style="width: 180px">Timestamp (UTC)</th>
            <th style="width: 160px">Action</th>
            <th>Detail</th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="loading && !audit.length">
            <td colspan="3">
              <div class="text-center py-8 px-6"><Spinner label="Loading logs…" /></div>
            </td>
          </tr>
          <tr v-else-if="!filtered.length">
            <td colspan="3"><EmptyState title="No matching entries" /></td>
          </tr>
          <tr v-for="row in filtered" :key="row.t + row.a">
            <td class="mono muted text-xs-var">{{ row.t }}</td>
            <td>
              <span
                class="inline-flex items-center gap-1.5 h-[22px] px-2 mono text-xs-var font-medium rounded-[5px] tracking-[-0.005em]"
                :class="NS_CLS[namespaceOf(row.a)]"
              >
                <span class="w-[5px] h-[5px] rounded-full bg-current"></span>{{ row.a }}
              </span>
            </td>
            <td class="mono text-xs-var text-c-tx2 break-words" style="white-space: normal">
              <template v-for="(part, index) in detailParts(row.d)" :key="part.key">
                <span v-if="index > 0" class="text-c-tx3 mx-0.5"> · </span>
                <span class="text-c-tx3">{{ part.key }}</span
                >=<span class="text-c-tx">{{ part.value }}</span>
              </template>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>
</template>
