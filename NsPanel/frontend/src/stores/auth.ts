/** Who is signed in, and what code the panel runs.
 *
 * `status` drives the shell: `checking` shows a spinner, `anonymous` the login
 * screen, `signed-in` the app. Any 401 from the API (session expired, password
 * changed elsewhere) flips it back to `anonymous`.
 */
import { defineStore } from 'pinia';
import { computed, ref } from 'vue';

import { ApiError, endpoints, fetchData, onUnauthorized, postAction } from '@/api/client';
import type { Me, MessageResponse } from '@/api/types';

export type AuthStatus = 'checking' | 'anonymous' | 'signed-in' | 'unreachable';

export const useAuthStore = defineStore('auth', () => {
  const status = ref<AuthStatus>('checking');
  const me = ref<Me | null>(null);
  /** Set when the session ended on its own (not by pressing Log out). */
  const expired = ref(false);
  /** `frontend_commit` of the bundle this page booted (static/dist/version.json).
   * Read at runtime, not baked into the JS, so the bundle builds byte-identical
   * from the same sources whatever commit it lands in. */
  const loadedBundle = ref('');
  void fetch('version.json', { cache: 'no-store' })
    .then((response) => (response.ok ? response.json() : null))
    .then((data: { frontend_commit?: string } | null) => {
      loadedBundle.value = data?.frontend_commit ?? '';
    })
    .catch(() => {
      /* dev server or tests: no version.json, no reload hint */
    });

  onUnauthorized(() => {
    if (status.value === 'signed-in') expired.value = true;
    status.value = 'anonymous';
    me.value = null;
  });

  async function check(): Promise<void> {
    try {
      me.value = await fetchData<Me>(endpoints.me);
      status.value = 'signed-in';
    } catch (error) {
      status.value = error instanceof ApiError && error.status === 401 ? 'anonymous' : 'unreachable';
    }
  }

  /** Throws ApiError with the server's message on failure. */
  async function login(username: string, password: string): Promise<void> {
    const result = await postAction<{ data: Me }>(endpoints.login, { username, password });
    me.value = result.data;
    expired.value = false;
    status.value = 'signed-in';
  }

  async function logout(): Promise<void> {
    try {
      await postAction<MessageResponse>(endpoints.logout);
    } finally {
      expired.value = false;
      me.value = null;
      status.value = 'anonymous';
    }
  }

  async function changePassword(current: string, next: string): Promise<string> {
    const result = await postAction<MessageResponse>(endpoints.password, {
      current_password: current,
      new_password: next,
    });
    return result.message;
  }

  /** `0.2.0+a1b2c3d` for the rail footer. */
  const versionLabel = computed(() => {
    const info = me.value?.version;
    if (!info) return `v${__APP_VERSION__}`;
    return info.commit ? `v${info.version}+${info.commit.slice(0, 7)}` : `v${info.version}`;
  });

  /** static/dist is older than frontend/, or this page runs an older bundle than
   * the server now serves (it was updated while the tab stayed open). */
  const bundleStale = computed(() => {
    if (me.value?.bundle_stale) return true;
    const served = me.value?.version.dist_frontend_commit;
    return !!(served && loadedBundle.value && served !== loadedBundle.value);
  });

  return { status, me, expired, check, login, logout, changePassword, versionLabel, bundleStale };
});
