<script setup lang="ts">
/** The audit trail: every change made through the panel, newest first.
 *
 * Paging and search run on the server (100 entries per page, "Load more").
 * The namespace pills are sent as the search term `<ns>.` when the search box
 * is empty — the server matches it as a substring — and are always applied
 * exactly on the client too (action starts with `<ns>.`), which drops the odd
 * detail that merely mentions `tool.`. With a search term as well, the server
 * searches for the term and the namespace narrows the loaded entries.
 */
import { storeToRefs } from 'pinia';
import { computed, onUnmounted, ref, watch } from 'vue';

import type { AuditRow } from '@/api/settings';
import AuditDetail from '@/components/activity/AuditDetail.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import DataTable from '@/components/ui/DataTable.vue';
import FilterPills from '@/components/ui/FilterPills.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import type { Column } from '@/components/ui/types';
import { useQueryRef } from '@/composables/useQueryRef';
import { useAuditStore } from '@/stores/audit';
import { fmtDate } from '@/utils/format';

const auditStore = useAuditStore();
const { entries, loading, loadingMore, loaded, error, hasMore } = storeToRefs(auditStore);

const NAMESPACES = [
  'all',
  'auth',
  'panel',
  'service',
  'site',
  'nginx',
  'tunnel',
  'tool',
  'firewall',
  'dns',
  'system',
  'job',
  'process',
] as const;
type Namespace = (typeof NAMESPACES)[number];

const namespace = useQueryRef<Namespace>('ns', 'all', NAMESPACES);
const search = useQueryRef<string>('q', '');

const nsOptions = NAMESPACES.map((ns) => ({ value: ns, label: ns === 'all' ? 'All' : ns }));

// The box updates the URL (and so the request) 300 ms after the last keystroke.
const searchInput = ref(search.value);
let debounce: ReturnType<typeof setTimeout> | undefined;
watch(searchInput, (value) => {
  clearTimeout(debounce);
  debounce = setTimeout(() => (search.value = value.trim()), 300);
});
watch(search, (value) => {
  if (value !== searchInput.value.trim()) searchInput.value = value;
});
onUnmounted(() => clearTimeout(debounce));

const serverQuery = computed(() => search.value || (namespace.value === 'all' ? '' : `${namespace.value}.`));

watch(serverQuery, (q) => void auditStore.load(q), { immediate: true });

const rows = computed(() =>
  namespace.value === 'all' ? entries.value : entries.value.filter((row) => row.namespace === namespace.value),
);

const refreshing = ref(false);
async function refresh(): Promise<void> {
  refreshing.value = true;
  try {
    await auditStore.load(serverQuery.value);
  } finally {
    refreshing.value = false;
  }
}

const NS_CLASS: Record<string, string> = {
  auth: 'bg-c-warnsoft text-c-warn',
  firewall: 'bg-c-dngsoft text-c-danger',
  system: 'bg-c-warnsoft text-c-warn',
  panel: 'bg-c-acsoft text-c-actx',
  tool: 'bg-c-acsoft text-c-actx',
  service: 'bg-c-infosoft text-c-info',
  site: 'bg-c-oksoft text-c-ok',
  nginx: 'bg-c-oksoft text-c-ok',
};

const columns: Column<AuditRow>[] = [
  { key: 'ts', label: 'Time', class: 'w-[180px]' },
  { key: 'action', label: 'Action' },
  { key: 'detail', label: 'Detail', class: '!whitespace-normal min-w-[220px]' },
  { key: 'user', label: 'User', hideOnMobile: true },
  { key: 'ip', label: 'IP address', hideOnMobile: true },
];

const filtering = computed(() => !!search.value || namespace.value !== 'all');

const summary = computed(() => {
  if (!loaded.value) return 'Every change made through the panel, newest first.';
  const count = rows.value.length;
  const noun = `entr${count === 1 ? 'y' : 'ies'}`;
  return `${count}${hasMore.value ? '+' : ''} ${noun}${filtering.value ? ' match' : ''} · newest first · stored on the server and rotated by size.`;
});

function clearFilters(): void {
  searchInput.value = '';
  search.value = '';
  namespace.value = 'all';
}
</script>

<template>
  <section>
    <PageHeader title="Audit log" :subtitle="summary">
      <Btn :loading="refreshing" @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
    </PageHeader>

    <div class="flex flex-col gap-3 mb-4">
      <label class="relative w-full sm:max-w-sm">
        <span class="sr-only">Search the audit log</span>
        <LIcon
          name="search"
          is="position:absolute;left:10px;top:50%;transform:translateY(-50%);pointer-events:none;color:var(--text-3);width:14px;height:14px"
        />
        <input
          v-model="searchInput"
          class="input pl-[30px]"
          type="search"
          autocomplete="off"
          spellcheck="false"
          placeholder="Search action, detail, user or IP…"
        />
      </label>
      <FilterPills v-model="namespace" :options="nsOptions" label="Action namespace" />
    </div>

    <Card class="overflow-clip">
      <DataTable
        :columns="columns"
        :rows="rows"
        row-key="id"
        label="Audit log"
        :loading="loading"
        :error="error"
        :empty-title="filtering ? 'No matching entries' : 'The audit log is empty'"
        :empty-hint="filtering ? '' : 'Actions taken in the panel are recorded here.'"
        empty-icon="scroll-text"
        @retry="refresh"
      >
        <template #cell-ts="{ row }">
          <time :datetime="row.ts" :title="`${row.ts} (UTC)`" class="text-xs-var text-c-tx2 tabular-nums">{{
            fmtDate(row.ts)
          }}</time>
        </template>
        <template #cell-action="{ row }">
          <span
            :class="[
              'inline-flex items-center h-[22px] px-2 rounded-theme-sm mono text-xs-var font-medium',
              NS_CLASS[row.namespace] ?? 'bg-c-subtle text-c-tx2',
            ]"
            >{{ row.action }}</span
          >
        </template>
        <template #cell-detail="{ row }"><AuditDetail :parts="row.detail" /></template>
        <template #cell-user="{ row }">
          <span class="text-xs-var">{{ row.user || '—' }}</span>
        </template>
        <template #cell-ip="{ row }">
          <span class="mono text-xs-var tabular-nums">{{ row.ip || '—' }}</span>
        </template>
        <template #empty>
          <Btn v-if="filtering" sm class="mt-3" @click="clearFilters">Clear filters</Btn>
        </template>
      </DataTable>
    </Card>

    <div v-if="loaded && (hasMore || entries.length)" class="flex flex-wrap items-center gap-3 mt-3">
      <span class="text-xs-var text-c-tx2 tabular-nums" role="status">
        {{ entries.length }} entries loaded<template v-if="namespace !== 'all' && search">
          · {{ rows.length }} in {{ namespace }}</template
        >
      </span>
      <Btn v-if="hasMore" sm :loading="loadingMore" class="ml-auto" @click="auditStore.loadMore()">
        <LIcon name="chevron-down" /> Load more
      </Btn>
    </div>
  </section>
</template>
