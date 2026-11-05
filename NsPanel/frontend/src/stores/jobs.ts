/** Background jobs the panel still holds in memory (GET /api/v1/jobs).
 *
 * Feeds the "N running" chip in the header and the Jobs screen, so a job whose
 * output dialog was closed — or lost to a reload — can be reopened.
 */
import { defineStore } from 'pinia';
import { computed, ref, watch } from 'vue';

import { endpoints, fetchData } from '@/api/client';
import type { JobSummary } from '@/api/types';

const POLL_MS = 3000;

export const useJobsStore = defineStore('jobs', () => {
  const jobs = ref<JobSummary[]>([]);
  const loading = ref(false);
  const loaded = ref(false);

  // Not built on createResource: this store is polled in the background, and a
  // panel restart must not turn into a toast every few seconds.
  async function load(): Promise<void> {
    loading.value = true;
    try {
      jobs.value = await fetchData<JobSummary[]>(endpoints.jobs);
      loaded.value = true;
    } catch {
      // Drop the running entries so an unreachable panel also stops the polling.
      jobs.value = jobs.value.filter((job) => job.status === 'done' || job.status === 'failed');
    } finally {
      loading.value = false;
    }
  }

  const running = computed(() =>
    jobs.value.filter((job) => job.status === 'running' || job.status === 'pending'),
  );

  // Poll only while something runs, so the chip clears itself when it finishes.
  let timer: ReturnType<typeof setInterval> | undefined;
  watch(
    () => running.value.length,
    (count) => {
      if (count && !timer) {
        timer = setInterval(() => {
          if (!document.hidden && !loading.value) void load();
        }, POLL_MS);
      } else if (!count && timer) {
        clearInterval(timer);
        timer = undefined;
      }
    },
  );

  return { jobs, loading, loaded, load, running };
});
