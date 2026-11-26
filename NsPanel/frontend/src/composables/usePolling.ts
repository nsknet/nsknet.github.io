/** Run `task` every `ms` while the tab is visible and the component is mounted.
 *
 * Pauses when the tab is hidden (no requests from a background tab) and runs
 * once as soon as it becomes visible again. A run never overlaps the previous
 * one. Returns `{ pause, resume, running }`.
 */
import { onMounted, onUnmounted, ref } from 'vue';

export function usePolling(task: () => Promise<unknown> | unknown, ms: number, { immediate = false } = {}) {
  const running = ref(false);
  let timer: ReturnType<typeof setTimeout> | undefined;
  let paused = false;
  let busy = false;

  async function tick(): Promise<void> {
    if (paused || document.hidden || busy) return schedule();
    busy = true;
    running.value = true;
    try {
      await task();
    } catch {
      /* the task reports its own errors */
    } finally {
      busy = false;
      running.value = false;
      schedule();
    }
  }

  function schedule(): void {
    clearTimeout(timer);
    if (!paused) timer = setTimeout(() => void tick(), ms);
  }

  function onVisibility(): void {
    if (!document.hidden && !paused) void tick();
  }

  function pause(): void {
    paused = true;
    clearTimeout(timer);
  }

  function resume(): void {
    paused = false;
    schedule();
  }

  onMounted(() => {
    document.addEventListener('visibilitychange', onVisibility);
    if (immediate) void tick();
    else schedule();
  });
  onUnmounted(() => {
    paused = true;
    clearTimeout(timer);
    document.removeEventListener('visibilitychange', onVisibility);
  });

  return { pause, resume, running };
}
