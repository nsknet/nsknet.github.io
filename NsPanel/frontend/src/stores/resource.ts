/** One loadable API resource: the data, whether it is in flight, and load().
 *
 * Every data store is built from this, so "loading" and "genuinely empty" stay
 * distinguishable on every screen without each store re-implementing the flags.
 */
import { ref, type Ref } from 'vue';

import { useUiStore } from './ui';

export interface Resource<T> {
  data: Ref<T>;
  loading: Ref<boolean>;
  loaded: Ref<boolean>;
  load: (...args: never[]) => Promise<void>;
}

export function createResource<T>(initial: T, loader: () => Promise<T>) {
  const data = ref(initial) as Ref<T>;
  const loading = ref(false);
  const loaded = ref(false);

  async function load(): Promise<void> {
    loading.value = true;
    try {
      data.value = await loader();
      loaded.value = true;
    } catch (error) {
      useUiStore().addToast({
        t: 'Could not load data',
        d: error instanceof Error ? error.message : String(error),
        k: 'danger',
      });
    } finally {
      loading.value = false;
    }
  }

  return { data, loading, loaded, load };
}
