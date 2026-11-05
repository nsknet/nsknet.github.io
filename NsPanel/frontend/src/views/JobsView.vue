<script setup lang="ts">
/** Background jobs still held by the panel: reopen any job's live or finished output. */
import { storeToRefs } from 'pinia';

import type { JobSummary } from '@/api/types';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import EmptyState from '@/components/ui/EmptyState.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import Skeleton from '@/components/ui/Skeleton.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import { useJobsStore } from '@/stores/jobs';
import { useUiStore } from '@/stores/ui';

const ui = useUiStore();
const jobsStore = useJobsStore();
const { jobs, loading, running } = storeToRefs(jobsStore);

function startedLabel(job: JobSummary): string {
  const at = job.started_at ?? job.created_at;
  return new Date(at * 1000).toLocaleString();
}

/** Server-side duration for finished jobs; running ones have no end yet. */
function durationLabel(job: JobSummary): string {
  if (!job.started_at || !job.finished_at) return '—';
  const seconds = job.finished_at - job.started_at;
  if (seconds < 60) return `${seconds.toFixed(1)}s`;
  const minutes = Math.floor(seconds / 60);
  return `${minutes}m ${Math.round(seconds % 60)}s`;
}

function open(job: JobSummary): void {
  ui.openOverlay({
    jobId: job.id,
    title: job.label,
    onDone: () => void jobsStore.load(),
  });
}

async function refresh(): Promise<void> {
  await jobsStore.load();
  ui.addToast({ t: 'Jobs refreshed', k: 'info' });
}
</script>

<template>
  <section>
    <PageHeader title="Jobs">
      <template #subtitle>
        {{ running.length }} running · {{ jobs.length }} kept in memory · cleared when the panel
        restarts
      </template>
      <Btn @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
    </PageHeader>

    <Card class="overflow-clip">
      <table class="tbl">
        <thead>
          <tr>
            <th style="width: 120px">Status</th>
            <th>Job</th>
            <th style="width: 200px">Started</th>
            <th style="width: 110px" class="text-right">Duration</th>
            <th style="width: 80px" class="text-right">Exit</th>
            <th style="width: 120px"></th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="loading && !jobs.length">
            <td colspan="6" style="padding: 0; height: auto"><Skeleton :count="4" /></td>
          </tr>
          <tr v-else-if="!jobs.length">
            <td colspan="6">
              <EmptyState
                icon="terminal"
                title="No jobs yet"
                hint="Installs, restarts and other actions show up here while they run."
              />
            </td>
          </tr>
          <tr v-for="job in jobs" :key="job.id">
            <td><StatusBadge :status="job.status" /></td>
            <td>
              <div class="font-medium">{{ job.label }}</div>
              <div class="mono text-xs-var text-c-tx3">{{ job.id }}</div>
            </td>
            <td class="text-xs-var text-c-tx2 tabular-nums">{{ startedLabel(job) }}</td>
            <td class="text-right mono text-xs-var tabular-nums">{{ durationLabel(job) }}</td>
            <td class="text-right mono text-xs-var">{{ job.exit_code ?? '—' }}</td>
            <td class="text-right">
              <Btn variant="ghost" sm @click="open(job)">
                <LIcon name="terminal" /> Output
              </Btn>
            </td>
          </tr>
        </tbody>
      </table>
    </Card>
  </section>
</template>
