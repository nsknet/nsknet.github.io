/** Screen state that lives in the URL query, so a reload (F5) or a shared link keeps it.
 *
 * Writes use router.replace, so typing in a search box does not pile up history
 * entries. The fallback value is kept out of the URL to keep links short.
 */
import { computed, type WritableComputedRef } from 'vue';
import { useRoute, useRouter } from 'vue-router';

export function useQueryRef<T extends string>(
  key: string,
  fallback: T,
  allowed?: readonly T[],
): WritableComputedRef<T> {
  const route = useRoute();
  const router = useRouter();

  return computed<T>({
    get() {
      const raw = route.query[key];
      if (typeof raw !== 'string') return fallback;
      if (allowed && !allowed.includes(raw as T)) return fallback;
      return raw as T;
    },
    set(value) {
      const query = { ...route.query };
      if (value === fallback || value === '') delete query[key];
      else query[key] = value;
      void router.replace({ query });
    },
  });
}
