/** Loads whatever the current route declared in `meta.loads`.
 *
 * Screens never fetch on mount: the route says what it needs, this reloads it
 * on navigation and after any job finishes.
 */
import { useRoute } from 'vue-router';

import type { StoreKey } from '@/router';
import { useDnsStore, useFirewallStore, useLogsStore, useProcessesStore } from '@/stores/misc';
import { useServicesStore } from '@/stores/services';
import { useSitesStore } from '@/stores/sites';
import { useSystemStore } from '@/stores/system';
import { useToolsStore } from '@/stores/tools';

export function loadersFor(keys: StoreKey[] | undefined): (() => Promise<void>)[] {
  if (!keys?.length) return [];

  const system = useSystemStore();
  const loaders: Record<StoreKey, () => Promise<void>> = {
    system: () => system.load(),
    disks: () => system.loadDisks(),
    sites: () => useSitesStore().load(),
    tools: () => useToolsStore().load(),
    services: () => useServicesStore().load(),
    dns: () => useDnsStore().load(),
    firewall: () => useFirewallStore().load(),
    logs: () => useLogsStore().load(),
    processes: () => useProcessesStore().load(),
  };

  return keys.map((key) => loaders[key]);
}

/** Load every store the given route needs, in parallel. */
export async function loadRouteData(keys: StoreKey[] | undefined): Promise<void> {
  await Promise.all(loadersFor(keys).map((load) => load()));
}

/** Reload the current screen — used after a job finishes or an edit is saved. */
export function useReload(): () => Promise<void> {
  const route = useRoute();
  return () => loadRouteData(route.meta.loads);
}
