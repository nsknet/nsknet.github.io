/** Is the panel reachable? Polls the unauthenticated /healthz while the tab is
 *  visible, so the header can show a real connection state instead of a dot
 *  that is always green. Also notices when the backend restarted onto another
 *  commit (the page then runs an old bundle). */
import { ref } from 'vue';

import { usePolling } from './usePolling';

const POLL_MS = 20_000;

export function useHealth() {
  const online = ref(true);
  const commit = ref<string | null>(null);
  /** The backend now runs a different commit than when this page loaded. */
  const restartedOnNewCode = ref(false);

  async function check(): Promise<void> {
    try {
      const response = await fetch('/healthz', { cache: 'no-store' });
      if (!response.ok) throw new Error(String(response.status));
      const body = (await response.json()) as { commit?: string };
      online.value = true;
      const current = body.commit ?? '';
      if (commit.value === null) commit.value = current;
      else if (current && current !== commit.value) restartedOnNewCode.value = true;
    } catch {
      online.value = false;
    }
  }

  usePolling(check, POLL_MS, { immediate: true });

  return { online, restartedOnNewCode, check };
}
