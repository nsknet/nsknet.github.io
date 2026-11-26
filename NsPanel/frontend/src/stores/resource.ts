/** One loadable API resource: the data, whether it is in flight, the last
 *  error, and load().
 *
 * Every data store is built from this, so "loading", "failed" and "genuinely
 * empty" stay distinguishable on every screen without each store
 * re-implementing the flags.
 *
 * - `error` holds the last failure's message (cleared by the next success);
 *   the data from the last good load is kept, so a blip does not blank a screen.
 * - `load({ silent: true })` is for background polls: no toast on failure.
 * - Overlapping loads: only the newest one's result is applied.
 */
import { ref, type Ref } from 'vue';

import { ApiError } from '@/api/client';

import { useUiStore } from './ui';

export interface LoadOptions {
  /** Background refresh: failures update `error` but raise no toast. */
  silent?: boolean;
}

export function createResource<T>(initial: T, loader: () => Promise<T>) {
  const data = ref(initial) as Ref<T>;
  const loading = ref(false);
  const loaded = ref(false);
  const error = ref<string | null>(null);
  let generation = 0;

  async function load(options: LoadOptions = {}): Promise<void> {
    const mine = ++generation;
    loading.value = true;
    try {
      const result = await loader();
      if (mine !== generation) return;
      data.value = result;
      loaded.value = true;
      error.value = null;
    } catch (err) {
      if (mine !== generation) return;
      // A 401 means "signed out": the shell swaps to the login screen instead.
      if (err instanceof ApiError && err.status === 401) return;
      const message = err instanceof Error ? err.message : String(err);
      error.value = message;
      if (!options.silent) {
        useUiStore().addToast({ t: 'Could not load data', d: message, k: 'danger' });
      }
    } finally {
      if (mine === generation) loading.value = false;
    }
  }

  return { data, loading, loaded, error, load };
}
