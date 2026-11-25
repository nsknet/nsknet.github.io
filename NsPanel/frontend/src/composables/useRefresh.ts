/** The Refresh button every screen has: reloads the route's data, spins while
 *  it runs, and says nothing on success (the data changing is the feedback). */
import { ref } from 'vue';

import { useReload } from './useScreenData';

export function useRefresh() {
  const reload = useReload();
  const refreshing = ref(false);

  async function refresh(): Promise<void> {
    if (refreshing.value) return;
    refreshing.value = true;
    try {
      await reload();
    } finally {
      refreshing.value = false;
    }
  }

  return { refresh, refreshing };
}
