/** Background jobs the panel still holds in memory (GET /api/v1/jobs).
 *
 * Feeds the "N running" chip in the header and the Jobs screen, so a job whose
 * output dialog was closed — or lost to a reload — can be reopened.
 *
 * While any job runs the store polls itself every 3 s, so the chip, the Jobs
 * screen and `onJobFinished` listeners stay current without a screen asking.
 */
import { defineStore } from 'pinia';
import { computed, ref, watch } from 'vue';

import { ApiError, endpoints, fetchData } from '@/api/client';
import type { JobSummary } from '@/api/types';

const POLL_MS = 3000;

export function isRunning(job: JobSummary): boolean {
  return job.status === 'running' || job.status === 'pending';
}

export const useJobsStore = defineStore('jobs', () => {
  const jobs = ref<JobSummary[]>([]);
  const loading = ref(false);
  const loaded = ref(false);
  /** Message of the last failed load; cleared by the next success. */
  const error = ref<string | null>(null);

  // Not built on createResource: this store is polled in the background, and a
  // panel restart must not turn into a toast every few seconds.
  /** Called with each job that finished since the previous poll. */
  const finishedListeners: ((job: JobSummary) => void)[] = [];
  function onJobFinished(listener: (job: JobSummary) => void): void {
    finishedListeners.push(listener);
  }

  /** Never toasts; the options argument exists so it fits `usePolling` callers. */
  async function load(_options: { silent?: boolean } = {}): Promise<void> {
    loading.value = true;
    try {
      const previous = new Map(jobs.value.map((job) => [job.id, job.status]));
      const next = await fetchData<JobSummary[]>(endpoints.jobs);
      jobs.value = next;
      loaded.value = true;
      error.value = null;
      // A job that was running and is now finished: whatever screen is open
      // may show stale data (its output dialog may have been closed).
      for (const job of next) {
        const before = previous.get(job.id);
        const wasRunning = before === 'running' || before === 'pending';
        if (wasRunning && (job.status === 'done' || job.status === 'failed')) {
          finishedListeners.forEach((listener) => listener(job));
        }
      }
    } catch (err) {
      if (!(err instanceof ApiError && err.status === 401)) {
        error.value = err instanceof Error ? err.message : String(err);
      }
      // Drop the running entries so an unreachable panel also stops the polling.
      jobs.value = jobs.value.filter((job) => !isRunning(job));
    } finally {
      loading.value = false;
    }
  }

  const running = computed(() => jobs.value.filter(isRunning));

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

  return { jobs, loading, loaded, error, load, running, onJobFinished };
});
