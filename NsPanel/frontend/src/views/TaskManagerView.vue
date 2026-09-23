<script setup lang="ts">
/** Live process list: server-side search, client-side sort, kill. */
import { storeToRefs } from 'pinia';
import { computed, onMounted, onUnmounted, ref, watch, type CSSProperties } from 'vue';

import { ApiError, postAction } from '@/api/client';
import type { ProcessRow } from '@/api/types';
import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import LIcon from '@/components/ui/LIcon.vue';
import Spinner from '@/components/ui/Spinner.vue';
import { useProcessesStore } from '@/stores/misc';
import { useUiStore } from '@/stores/ui';

const ui = useUiStore();
const processesStore = useProcessesStore();
const { processes, loading } = storeToRefs(processesStore);
const { theme } = storeToRefs(ui);

type SortColumn = keyof Pick<
  ProcessRow,
  'pid' | 'arguments' | 'threads' | 'user' | 'ram_gb' | 'cpu_percent'
>;

const filterText = ref('');
const sortCol = ref<SortColumn>('cpu_percent');
const sortOrder = ref<'asc' | 'desc' | 'none'>('desc');
const refreshInterval = ref('5000');
const expandedPids = ref(new Set<number>());

let timer: ReturnType<typeof setInterval> | undefined;
let debounce: ReturnType<typeof setTimeout> | undefined;

const summary = computed(() => {
  const rows = processes.value;
  return {
    totalProcs: rows.length,
    totalThreads: rows.reduce((sum, row) => sum + (row.threads || 0), 0),
    totalRam: rows.reduce((sum, row) => sum + (row.ram_gb || 0), 0).toFixed(2),
    activeCpuProcs: rows.filter((row) => row.cpu_percent > 1).length,
  };
});

function topTen(key: 'cpu_percent' | 'ram_gb' | 'threads'): ProcessRow[] {
  return [...processes.value].sort((a, b) => b[key] - a[key]).slice(0, 10);
}

const topCpu = computed(() => topTen('cpu_percent'));
const topRam = computed(() => topTen('ram_gb'));
const topThreads = computed(() => topTen('threads'));

/** Heaviest ten in each column get a heat tint — orange at rank 10, red at rank 1. */
function heatmapStyle(value: number, kind: 'cpu' | 'ram' | 'threads', pid: number): CSSProperties {
  if (!value) return {};

  const list = kind === 'cpu' ? topCpu.value : kind === 'ram' ? topRam.value : topThreads.value;
  const rank = list.findIndex((row) => row.pid === pid);
  if (rank === -1) return {};

  const hue = Math.round(35 * (rank / 9));
  const base: CSSProperties = {
    padding: '2px 8px',
    borderRadius: '6px',
    fontWeight: '600',
    display: 'inline-block',
  };

  if (theme.value === 'dark') {
    return {
      ...base,
      color: `hsla(${hue}, 100%, 80%, 1)`,
      backgroundColor: `hsla(${hue}, 95%, 42%, 0.22)`,
      border: `1px solid hsla(${hue}, 95%, 50%, 0.45)`,
      boxShadow: `0 0 12px hsla(${hue}, 95%, 50%, 0.12)`,
    };
  }
  return {
    ...base,
    color: `hsla(${hue}, 95%, 35%, 1)`,
    backgroundColor: `hsla(${hue}, 95%, 50%, 0.08)`,
    border: `1px solid hsla(${hue}, 95%, 45%, 0.26)`,
  };
}

function toggleExpand(pid: number): void {
  const next = new Set(expandedPids.value);
  if (next.has(pid)) next.delete(pid);
  else next.add(pid);
  expandedPids.value = next;
}

async function refresh(): Promise<void> {
  await processesStore.load(filterText.value);
  ui.addToast({ t: 'Processes refreshed', k: 'info' });
}

function killProcess(row: ProcessRow): void {
  ui.confirmThen(
    'Terminate process?',
    `Terminate PID ${row.pid} (${row.name})? This cannot be undone.`,
    async () => {
      try {
        await postAction('/api/v1/processes/kill', { pid: row.pid });
        ui.addToast({
          t: 'Process terminated',
          d: `PID ${row.pid} killed successfully.`,
          k: 'ok',
        });
        await processesStore.load(filterText.value);
      } catch (error) {
        ui.addToast({
          t: error instanceof ApiError ? 'Failed to kill process' : 'Network error',
          d: error instanceof Error ? error.message : String(error),
          k: 'danger',
        });
      }
    },
  );
}

/** Click cycles desc → asc → unsorted. */
function changeSort(column: SortColumn): void {
  if (sortCol.value !== column) {
    sortCol.value = column;
    sortOrder.value = 'desc';
    return;
  }
  sortOrder.value =
    sortOrder.value === 'desc' ? 'asc' : sortOrder.value === 'asc' ? 'none' : 'desc';
}

const COLUMNS: { key: SortColumn; label: string; align: 'left' | 'right'; width?: string }[] = [
  { key: 'pid', label: 'PID', align: 'left' },
  { key: 'arguments', label: 'Command / arguments', align: 'left', width: '45%' },
  { key: 'threads', label: 'Threads', align: 'right' },
  { key: 'user', label: 'User', align: 'left' },
  { key: 'ram_gb', label: 'RAM (GB)', align: 'right' },
  { key: 'cpu_percent', label: 'CPU (%)', align: 'right' },
];

const sorted = computed(() => {
  const rows = [...processes.value];
  if (sortOrder.value === 'none') return rows;

  const column = sortCol.value;
  return rows.sort((a, b) => {
    const left = typeof a[column] === 'string' ? String(a[column]).toLowerCase() : a[column];
    const right = typeof b[column] === 'string' ? String(b[column]).toLowerCase() : b[column];
    if (left < right) return sortOrder.value === 'asc' ? -1 : 1;
    if (left > right) return sortOrder.value === 'asc' ? 1 : -1;
    return 0;
  });
});

function setupInterval(): void {
  clearInterval(timer);
  timer = undefined;
  if (refreshInterval.value === 'none') return;
  timer = setInterval(() => {
    void processesStore.load(filterText.value);
  }, Number.parseInt(refreshInterval.value, 10));
}

watch(refreshInterval, setupInterval);

// Searching happens server-side; debounce so typing does not hammer the API.
watch(filterText, (value) => {
  clearTimeout(debounce);
  debounce = setTimeout(() => void processesStore.load(value), 300);
});

onMounted(setupInterval);
onUnmounted(() => {
  clearInterval(timer);
  clearTimeout(debounce);
});
</script>

<template>
  <section class="animate-fade">
    <div class="flex flex-col md:flex-row md:items-end justify-between gap-4 mb-6">
      <div>
        <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">Task manager</h1>
        <div class="text-sm-var text-c-tx2">Real-time system process monitor.</div>
      </div>
      <div class="flex items-center gap-2.5">
        <div class="flex items-center gap-1.5 bg-c-bg border border-c-border rounded-lg px-2.5 py-1">
          <span class="text-xs-var font-medium text-c-tx2">Refresh:</span>
          <select
            v-model="refreshInterval"
            class="bg-transparent border-0 outline-none text-xs-var font-semibold cursor-pointer text-c-tx"
          >
            <option value="none">Paused</option>
            <option value="5000">5s</option>
            <option value="10000">10s</option>
            <option value="15000">15s</option>
            <option value="30000">30s</option>
            <option value="60000">60s</option>
          </select>
        </div>
        <Btn @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
      </div>
    </div>

    <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-5">
      <div
        v-for="card in [
          { label: 'Total processes', value: summary.totalProcs, icon: 'list', unit: '' },
          { label: 'Total threads', value: summary.totalThreads, icon: 'git-merge', unit: '' },
          { label: 'Total RSS memory', value: summary.totalRam, icon: 'memory-stick', unit: 'GB' },
          { label: 'Active (CPU > 1%)', value: summary.activeCpuProcs, icon: 'activity', unit: '' },
        ]"
        :key="card.label"
        class="bg-c-bg border border-c-border rounded-theme p-[15px] flex items-center justify-between"
      >
        <div>
          <div class="text-xs-var text-c-tx3 uppercase tracking-[0.05em] font-medium mb-1">
            {{ card.label }}
          </div>
          <div class="text-xl font-semibold tabular-nums">
            {{ card.value
            }}<span v-if="card.unit" class="text-xs font-normal text-c-tx3"> {{ card.unit }}</span>
          </div>
        </div>
        <div class="w-8 h-8 rounded-lg bg-c-subtle flex items-center justify-center text-c-tx2">
          <LIcon :name="card.icon" is="width:16px;height:16px" />
        </div>
      </div>
    </div>

    <div class="mb-4">
      <div class="relative w-full max-w-md">
        <span
          class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none text-c-tx3"
        >
          <LIcon name="search" is="width:14px;height:14px" />
        </span>
        <input
          v-model="filterText"
          type="text"
          placeholder="Search by PID, name, user, or arguments…"
          class="input pl-9"
        />
      </div>
    </div>

    <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
      <div class="overflow-x-auto">
        <table class="tbl select-none">
          <thead>
            <tr>
              <th
                v-for="column in COLUMNS"
                :key="column.key"
                class="cursor-pointer hover:text-c-tx"
                :class="column.align === 'right' ? 'text-right' : ''"
                :style="column.width ? { width: column.width } : undefined"
                @click="changeSort(column.key)"
              >
                <div
                  class="flex items-center gap-1"
                  :class="column.align === 'right' ? 'justify-end' : ''"
                >
                  {{ column.label }}
                  <LIcon
                    v-if="sortCol === column.key && sortOrder !== 'none'"
                    :name="sortOrder === 'asc' ? 'chevron-up' : 'chevron-down'"
                    is="width:12px;height:12px"
                  />
                </div>
              </th>
              <th class="text-right">Action</th>
            </tr>
          </thead>
          <tbody>
            <tr v-if="loading && !sorted.length">
              <td colspan="7" class="text-center py-10">
                <Spinner label="Loading processes…" />
              </td>
            </tr>
            <tr v-else-if="!sorted.length">
              <td colspan="7" class="text-center py-10 text-c-tx3">
                <div class="flex flex-col items-center justify-center gap-2">
                  <LIcon name="inbox" is="width:24px;height:24px" />
                  <span>No processes match that search.</span>
                </div>
              </td>
            </tr>
            <tr
              v-for="row in sorted"
              :key="row.pid"
              class="hover:bg-c-hover/40 transition-colors"
            >
              <td class="mono font-semibold">{{ row.pid }}</td>
              <td class="whitespace-normal py-2 text-c-tx" style="max-width: 0">
                <div class="break-all text-xs-var leading-relaxed flex flex-col gap-0.5">
                  <span class="font-medium text-c-tx truncate" :title="row.name">
                    {{ row.name }}
                  </span>
                  <div class="text-c-tx2 mono mt-0.5 max-w-[480px]">
                    <span v-if="row.arguments.length <= 75" class="break-all">
                      {{ row.arguments }}
                    </span>
                    <div v-else class="flex flex-col gap-1">
                      <span
                        v-if="!expandedPids.has(row.pid)"
                        class="block truncate max-w-[450px] cursor-help"
                        :title="row.arguments"
                      >
                        {{ row.arguments }}
                      </span>
                      <span v-else class="block whitespace-normal break-all">
                        {{ row.arguments }}
                      </span>
                      <div>
                        <button
                          class="text-c-accent font-semibold cursor-pointer hover:underline text-[10px] uppercase tracking-wider focus:outline-none"
                          @click.stop="toggleExpand(row.pid)"
                        >
                          {{ expandedPids.has(row.pid) ? 'Show less' : 'Show more' }}
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              </td>
              <td class="text-right num font-semibold">
                <span :style="heatmapStyle(row.threads, 'threads', row.pid)">
                  {{ row.threads }}
                </span>
              </td>
              <td><Badge tone="neutral">{{ row.user }}</Badge></td>
              <td class="text-right num font-semibold">
                <span :style="heatmapStyle(row.ram_gb, 'ram', row.pid)">
                  {{ row.ram_gb.toFixed(3) }}
                </span>
              </td>
              <td class="text-right num font-semibold">
                <span :style="heatmapStyle(row.cpu_percent, 'cpu', row.pid)">
                  {{ row.cpu_percent.toFixed(1) }}%
                </span>
              </td>
              <td class="text-right">
                <Btn variant="danger" sm @click.stop="killProcess(row)">
                  <LIcon name="trash-2" /> Kill
                </Btn>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </section>
</template>
