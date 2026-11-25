/** A text endpoint (logs, config, status) fetched on demand — when its tab is
 *  opened or Refresh is pressed — with loading and error kept per instance. */
import { ref } from 'vue';

import { ApiError, fetchData } from '@/api/client';

export function useRemoteText(path: () => string) {
  const text = ref('');
  const loading = ref(false);
  const loaded = ref(false);
  const error = ref<string | null>(null);
  let generation = 0;

  async function load(): Promise<void> {
    const mine = ++generation;
    loading.value = true;
    try {
      const result = await fetchData<string>(path());
      if (mine !== generation) return;
      text.value = result ?? '';
      loaded.value = true;
      error.value = null;
    } catch (err) {
      if (mine !== generation) return;
      if (err instanceof ApiError && err.status === 401) return;
      error.value = err instanceof Error ? err.message : String(err);
    } finally {
      if (mine === generation) loading.value = false;
    }
  }

  /** Load once; later calls do nothing until `load()` is called explicitly. */
  function ensure(): void {
    if (!loaded.value && !loading.value) void load();
  }

  return { text, loading, loaded, error, load, ensure };
}
