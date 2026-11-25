<script setup lang="ts">
/** Live process list: server-side search (mirrored in the URL), sortable
 *  columns, auto-refresh at a chosen interval, and TERM/KILL. */
import { storeToRefs } from 'pinia';
import { computed, onMounted, onUnmounted, ref, watch } from 'vue';

import type { Process } from '@/api/system';
import KillProcessDialog from '@/components/system/KillProcessDialog.vue';
import Alert from '@/components/ui/Alert.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import DataTable from '@/components/ui/DataTable.vue';
import LIcon from '@/components/ui/LIcon.vue';
import MetricCard from '@/components/ui/MetricCard.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import type { Column } from '@/components/ui/types';
import { usePolling } from '@/composables/usePolling';
import { useQueryRef } from '@/composables/useQueryRef';
import { useProcessesStore } from '@/stores/misc';
import { useSystemStore } from '@/stores/system';
import { gb } from '@/utils/format';

const store = useProcessesStore();
const { processes, loading, loaded, error } = storeToRefs(store);
const { host } = storeToRefs(useSystemStore());

// --- Search (URL ?q=, debounced) ----------------------------------------------
const query = useQueryRef<string>('q', '');
const term = ref(query.value);
let debounce: ReturnType<typeof setTimeout> | undefined;

watch(term, (value) => {
  clearTimeout(debounce);
  debounce = setTimeout(() => (query.value = value.trim()), 300);
});
/** A search is in flight: the rows on screen still belong to the previous one. */
const searching = ref(false);
let searchSeq = 0;

async function runSearch(value: string): Promise<void> {
  const mine = ++searchSeq;
  searching.value = true;
  lastLoad = Date.now();
  await store.search(value);
  if (mine === searchSeq) searching.value = false;
}

// The URL is the source of truth (typing, back/forward, a shared link).
watch(query, (value) => {
  if (value !== term.value.trim()) term.value = value;
  void runSearch(value);
});

function clearSearch(): void {
  clearTimeout(debounce);
  term.value = '';
  query.value = '';
}

// --- Auto-refresh ----------------------------------------------------------------
const INTERVALS = ['off', '2', '5', '10'] as const;
const every = useQueryRef<(typeof INTERVALS)[number]>('every', '5', INTERVALS);
const INTERVAL_LABEL: Record<(typeof INTERVALS)[number], string> = {
  off: 'Off',
  '2': 'Every 2 s',
  '5': 'Every 5 s',
  '10': 'Every 10 s',
};
let lastLoad = 0;

async function loadNow(silent = false): Promise<void> {
  lastLoad = Date.now();
  await store.load({ silent });
}

// Ticks every second; loads when the chosen interval has passed. usePolling
// skips hidden tabs and never overlaps a request still in flight.
usePolling(() => {
  if (every.value === 'off') return;
  if (Date.now() - lastLoad < Number(every.value) * 1000 - 250) return;
  return loadNow(true);
}, 1000);

const manualRefreshing = ref(false);
async function refresh(): Promise<void> {
  manualRefreshing.value = true;
  await loadNow();
  manualRefreshing.value = false;
}

// This screen loads itself (no route `loads`) so the first request already
// carries the search term from the URL.
onMounted(() => void runSearch(query.value));
onUnmounted(() => clearTimeout(debounce));

// --- Table -----------------------------------------------------------------------
const columns: Column<Process>[] = [
  { key: 'pid', label: 'PID', sortable: true, class: 'num mono w-20' },
  { key: 'name', label: 'Command', sortable: true, sortValue: (row) => row.name.toLowerCase() },
  { key: 'user', label: 'User', sortable: true, hideOnMobile: true },
  { key: 'threads', label: 'Threads', sortable: true, align: 'right', class: 'num', hideOnMobile: true },
  { key: 'ram_gb', label: 'RAM', sortable: true, align: 'right', class: 'num' },
  { key: 'cpu_percent', label: 'CPU', sortable: true, align: 'right', class: 'num' },
  { key: 'actions', label: 'Actions', srOnlyLabel: true, align: 'right' },
];

type Heat = 'hot' | 'warm' | '';
const HEAT_CLASS: Record<Heat, string> = {
  hot: 'bg-c-dngsoft text-c-danger font-semibold',
  warm: 'bg-c-warnsoft text-c-warn font-semibold',
  '': '',
};

/** psutil reports per-core CPU, so one busy thread is 100%. */
function cpuHeat(row: Process): Heat {
  return row.cpu_percent >= 80 ? 'hot' : row.cpu_percent >= 25 ? 'warm' : '';
}
function ramHeat(row: Process): Heat {
  const total = host.value.ram.total;
  if (!total) return '';
  const share = (row.ram_gb / total) * 100;
  return share >= 25 ? 'hot' : share >= 10 ? 'warm' : '';
}

const expanded = ref(new Set<number>());
function toggleExpanded(pid: number): void {
  const next = new Set(expanded.value);
  if (next.has(pid)) next.delete(pid);
  else next.add(pid);
  expanded.value = next;
}

const summary = computed(() => {
  const rows = processes.value;
  return {
    count: rows.length,
    threads: rows.reduce((sum, row) => sum + (row.threads || 0), 0),
    ram: rows.reduce((sum, row) => sum + (row.ram_gb || 0), 0),
    busy: rows.filter((row) => row.cpu_percent > 1).length,
  };
});

const killing = ref<Process | null>(null);
</script>

<template>
  <section>
    <PageHeader
      title="Processes"
      :subtitle="
        query
          ? `Processes matching “${query}”.`
          : 'The busiest processes by CPU, memory and threads (up to 100 of each).'
      "
    >
      <div class="flex items-center gap-2">
        <label for="proc-every" class="text-sm-var text-c-tx2 whitespace-nowrap">Auto-refresh</label>
        <select id="proc-every" v-model="every" class="input h-9 w-auto">
          <option v-for="option in INTERVALS" :key="option" :value="option">{{ INTERVAL_LABEL[option] }}</option>
        </select>
      </div>
      <Btn :loading="manualRefreshing" @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
    </PageHeader>

    <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-4">
      <MetricCard label="Listed" icon="list" :value="summary.count" sub="processes" :loading="!loaded" />
      <MetricCard label="Threads" icon="git-merge" :value="summary.threads" sub="in listed processes" :loading="!loaded" />
      <MetricCard
        label="Resident memory"
        icon="memory-stick"
        :value="gb(summary.ram)"
        :sub="host.ram.total ? `of ${gb(host.ram.total)} RAM` : 'in listed processes'"
        :loading="!loaded"
      />
      <MetricCard label="Busy" icon="activity" :value="summary.busy" sub="using more than 1% CPU" :loading="!loaded" />
    </div>

    <form class="mb-4 flex flex-wrap items-center gap-x-3 gap-y-1" role="search" @submit.prevent>
      <label for="proc-search" class="sr-only">Search processes</label>
      <div class="relative w-full max-w-md">
        <span class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none text-c-tx3">
          <LIcon name="search" is="width:14px;height:14px" />
        </span>
        <input
          id="proc-search"
          v-model="term"
          type="search"
          class="input"
          style="padding-left: 2.25rem"
          autocomplete="off"
          spellcheck="false"
          placeholder="Search PID, name, user or arguments"
        />
      </div>
      <span class="text-xs-var text-c-tx2 min-h-[1.25rem]" role="status" aria-live="polite">{{
        searching && loaded ? 'Searching…' : ''
      }}</span>
    </form>

    <Alert v-if="error && loaded" tone="warn" class="mb-4" title="Live updates are failing">
      {{ error }} The list shows the last good data.
    </Alert>

    <Card class="overflow-clip">
      <DataTable
        :columns="columns"
        :rows="processes"
        row-key="pid"
        label="Processes"
        :loading="loading && !loaded"
        :error="error"
        sort-key="cpu_percent"
        sort-dir="desc"
        empty-icon="search-x"
        :empty-title="query ? 'No process matches that search' : 'No processes reported'"
        @retry="refresh"
      >
        <template #empty>
          <Btn v-if="query" sm class="mt-3" @click="clearSearch"><LIcon name="x" /> Clear search</Btn>
        </template>
        <template #cell-name="{ row }">
          <div class="min-w-[200px] max-w-[440px] whitespace-normal">
            <div class="flex items-center gap-1.5">
              <span v-if="row.protected" class="inline-flex text-c-warn shrink-0" title="Protected process">
                <LIcon name="lock" is="width:12px;height:12px" />
              </span>
              <span class="font-medium truncate">{{ row.name }}</span>
              <span class="md:hidden text-xs-var text-c-tx2">· {{ row.user }}</span>
            </div>
            <div
              v-if="row.arguments && row.arguments !== row.name"
              :class="[
                'mono text-xs-var text-c-tx2 mt-0.5',
                expanded.has(row.pid) ? 'break-all' : 'truncate',
              ]"
              :title="expanded.has(row.pid) ? undefined : row.arguments"
            >
              {{ row.arguments }}
            </div>
            <button
              v-if="row.arguments.length > 80"
              type="button"
              class="text-xs-var text-c-actx bg-transparent underline-offset-2 hover:underline mt-0.5"
              :aria-expanded="expanded.has(row.pid)"
              @click="toggleExpanded(row.pid)"
            >
              {{ expanded.has(row.pid) ? 'Show less' : 'Show full command' }}
            </button>
            <div v-if="row.protected" :id="`proc-lock-${row.pid}`" class="text-xs-var text-c-tx2 mt-0.5">
              Protected: the system or this panel needs it.
            </div>
          </div>
        </template>
        <template #cell-user="{ row }">
          <span class="mono text-xs-var text-c-tx2">{{ row.user }}</span>
        </template>
        <template #cell-threads="{ row }">
          <span class="tabular-nums">{{ row.threads }}</span>
        </template>
        <template #cell-ram_gb="{ row }">
          <span :class="['tabular-nums rounded-md px-1.5 py-0.5 whitespace-nowrap', HEAT_CLASS[ramHeat(row)]]">
            {{ gb(row.ram_gb) }}
          </span>
        </template>
        <template #cell-cpu_percent="{ row }">
          <span :class="['tabular-nums rounded-md px-1.5 py-0.5 whitespace-nowrap', HEAT_CLASS[cpuHeat(row)]]">
            {{ row.cpu_percent.toFixed(1) }}%
          </span>
        </template>
        <template #cell-actions="{ row }">
          <Btn
            variant="danger"
            sm
            :disabled="row.protected"
            :aria-label="`Stop ${row.name} (PID ${row.pid})`"
            :aria-describedby="row.protected ? `proc-lock-${row.pid}` : undefined"
            @click="killing = row"
          >
            <LIcon :name="row.protected ? 'lock' : 'octagon-x'" /> Kill
          </Btn>
        </template>
      </DataTable>
    </Card>

    <KillProcessDialog v-if="killing" :process="killing" @close="killing = null" @done="loadNow(true)" />
  </section>
</template>
