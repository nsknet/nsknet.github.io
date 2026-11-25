<script setup lang="ts">
/** Background jobs the panel holds: reopen any job's output, stop a running one.
 *
 * The jobs store polls every 3 s while anything runs, so this list (and the
 * live durations) stay current without a poll of its own. */
import { storeToRefs } from 'pinia';
import { computed, onUnmounted, ref, watch } from 'vue';

import type { JobSummary } from '@/api/types';
import JobStatusBadge from '@/components/activity/JobStatusBadge.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import DataTable from '@/components/ui/DataTable.vue';
import FilterPills from '@/components/ui/FilterPills.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import type { Column } from '@/components/ui/types';
import { useJobRunner } from '@/composables/useJobs';
import { useQueryRef } from '@/composables/useQueryRef';
import { useRefresh } from '@/composables/useRefresh';
import { isRunning, useJobsStore } from '@/stores/jobs';
import { useUiStore } from '@/stores/ui';
import { apiPath, duration } from '@/utils/format';

const ui = useUiStore();
const { run } = useJobRunner();
const { refresh, refreshing } = useRefresh();
const jobsStore = useJobsStore();
const { jobs, loading, loaded, error, running } = storeToRefs(jobsStore);

const FILTERS = ['all', 'running', 'failed'] as const;
type Filter = (typeof FILTERS)[number];
const filter = useQueryRef<Filter>('status', 'all', FILTERS);

const failedCount = computed(() => jobs.value.filter((job) => job.status === 'failed').length);
const filterOptions = computed(() => [
  { value: 'all', label: 'All', count: jobs.value.length },
  { value: 'running', label: 'Running', count: running.value.length },
  { value: 'failed', label: 'Failed', count: failedCount.value },
]);

const rows = computed(() =>
  jobs.value.filter((job) => {
    if (filter.value === 'running') return isRunning(job);
    if (filter.value === 'failed') return job.status === 'failed';
    return true;
  }),
);

// A clock for the elapsed time of running jobs; ticks only while one runs.
const now = ref(Date.now());
let clock: ReturnType<typeof setInterval> | undefined;
watch(
  () => running.value.length,
  (count) => {
    if (count && !clock) {
      clock = setInterval(() => (now.value = Date.now()), 1000);
    } else if (!count && clock) {
      clearInterval(clock);
      clock = undefined;
    }
  },
  { immediate: true },
);
onUnmounted(() => clearInterval(clock));

const startedAt = (job: JobSummary) => job.started_at ?? job.created_at;

function elapsed(job: JobSummary): string {
  if (!job.started_at) return '—';
  const end = job.finished_at ?? (isRunning(job) ? now.value / 1000 : null);
  return end === null ? '—' : duration(Math.max(0, end - job.started_at));
}

function startedLabel(job: JobSummary): string {
  return new Date(startedAt(job) * 1000).toLocaleString();
}

const columns: Column<JobSummary>[] = [
  { key: 'status', label: 'Status', class: 'w-[120px]' },
  { key: 'label', label: 'Job', sortable: true },
  { key: 'started', label: 'Started', sortable: true, sortValue: startedAt, hideOnMobile: true },
  {
    key: 'duration',
    label: 'Duration',
    align: 'right',
    sortable: true,
    sortValue: (job) => (job.started_at ? (job.finished_at ?? Date.now() / 1000) - job.started_at : 0),
  },
  { key: 'exit', label: 'Exit', align: 'right', hideOnMobile: true },
  { key: 'actions', label: 'Actions', srOnlyLabel: true, align: 'right' },
];

function open(job: JobSummary): void {
  ui.openOverlay({ jobId: job.id, title: job.label, onDone: () => void jobsStore.load() });
}

function cancel(job: JobSummary): void {
  ui.confirmThen(
    `Stop “${job.label}”?`,
    'The job is sent a stop signal. Whatever it already changed stays changed — an install may be left half done.',
    () => void run(apiPath`/api/v1/jobs/${job.id}/cancel`, {}, { title: `Stopping ${job.label}` }),
    { danger: true, confirmLabel: 'Stop job' },
  );
}

const emptyTitle = computed(() =>
  filter.value === 'running' ? 'Nothing running' : filter.value === 'failed' ? 'No failed jobs' : 'No jobs yet',
);
</script>

<template>
  <section>
    <PageHeader
      title="Jobs"
      :subtitle="`${running.length} running · ${jobs.length} kept by the panel. Installs, restarts and other actions run here.`"
    >
      <Btn :loading="refreshing" @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
    </PageHeader>

    <div class="mb-4">
      <FilterPills v-model="filter" :options="filterOptions" label="Show jobs" />
    </div>

    <Card class="overflow-clip">
      <DataTable
        :columns="columns"
        :rows="rows"
        row-key="id"
        label="Jobs"
        :loading="loading && !loaded"
        :error="loaded ? null : error"
        :empty-title="emptyTitle"
        empty-hint="Installs, restarts and other actions show up here while they run."
        empty-icon="terminal"
        sort-key="started"
        sort-dir="desc"
        @retry="jobsStore.load()"
      >
        <template #cell-status="{ row }"><JobStatusBadge :job="row" /></template>
        <template #cell-label="{ row }">
          <div class="font-medium text-c-tx whitespace-normal">{{ row.label }}</div>
          <div class="mono text-xs-var text-c-tx3">{{ row.id }}</div>
        </template>
        <template #cell-started="{ row }">
          <span class="text-xs-var text-c-tx2 tabular-nums">{{ startedLabel(row) }}</span>
        </template>
        <template #cell-duration="{ row }">
          <span class="mono text-xs-var tabular-nums">{{ elapsed(row) }}</span>
        </template>
        <template #cell-exit="{ row }">
          <span :class="['mono text-xs-var tabular-nums', row.exit_code ? 'text-c-danger' : '']">{{
            row.exit_code ?? '—'
          }}</span>
        </template>
        <template #cell-actions="{ row }">
          <div class="inline-flex items-center gap-1.5">
            <Btn sm variant="ghost" :aria-label="`Show output of ${row.label}`" @click="open(row)">
              <LIcon name="terminal" /> <span class="hidden sm:inline">Output</span>
            </Btn>
            <Btn
              v-if="isRunning(row) && !row.cancelled"
              sm
              variant="danger"
              :aria-label="`Stop ${row.label}`"
              @click="cancel(row)"
            >
              <LIcon name="square" /> <span class="hidden sm:inline">Stop</span>
            </Btn>
          </div>
        </template>
      </DataTable>
    </Card>
    <p class="mt-3 mb-0 text-xs-var text-c-tx3">
      The list refreshes every few seconds while a job runs.
    </p>
  </section>
</template>
