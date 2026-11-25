<script setup lang="ts">
/** A job's state: queued, running, done, failed — or cancelled (a stop was requested). */
import { computed } from 'vue';

import type { JobSummary } from '@/api/types';
import Badge from '@/components/ui/Badge.vue';
import type { Tone } from '@/components/ui/types';

const props = defineProps<{ job: JobSummary }>();

const state = computed<{ label: string; tone: Tone }>(() => {
  const { status, cancelled } = props.job;
  if (cancelled && status !== 'done') {
    return { label: status === 'running' ? 'stopping' : 'cancelled', tone: 'warn' };
  }
  const map: Record<JobSummary['status'], { label: string; tone: Tone }> = {
    pending: { label: 'queued', tone: 'muted' },
    running: { label: 'running', tone: 'info' },
    done: { label: 'done', tone: 'ok' },
    failed: { label: 'failed', tone: 'danger' },
  };
  return map[status] ?? { label: status, tone: 'muted' };
});
</script>

<template>
  <Badge :tone="state.tone" dot>{{ state.label }}</Badge>
</template>
