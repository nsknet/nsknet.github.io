/** Following the panel through its own restart.
 *
 * When the service restarts itself (update, rollback, restart, reconfigure),
 * the page has to wait for it to go away and come back, then load the new
 * bundle. When a reconfigure moves it to another port or scheme, the page
 * polls the new address and goes there once it answers.
 *
 * Polling another origin: the request is made with `mode: 'no-cors'`, so any
 * answer counts (the response is opaque). It can still fail for reasons that
 * have nothing to do with the panel — an untrusted self-signed certificate, or
 * an https page asking for an http URL (mixed content) — so after a while the
 * screen offers a plain "Open the new address" link instead of waiting forever.
 */
import { nextTick, onUnmounted, ref } from 'vue';

import { ApiError, endpoints, fetchData } from '@/api/client';
import type { PanelTarget } from '@/api/settings';
import type { PanelServiceStatus } from '@/api/types';
import { useUiStore } from '@/stores/ui';

const POLL_MS = 1500;
/** Give up waiting for a same-address restart after this long. */
const RESTART_TIMEOUT_MS = 60_000;
/** The job failed before restarting if the panel never went down by then. */
const NEVER_WENT_DOWN_MS = 15_000;
/** Show the manual link after this long without an answer from the new address. */
const MOVE_LINK_AFTER_MS = 20_000;
/** Stop polling the new address after this long (the link stays). */
const MOVE_TIMEOUT_MS = 120_000;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export function usePanelRestart(onGaveUp: () => void) {
  const ui = useUiStore();
  /** A restart is in progress: the screen shows a banner and disables actions. */
  const restarting = ref(false);
  /** The new address, once the panel moves to another port or scheme. */
  const movingTo = ref<string | null>(null);
  /** The new address did not answer in time: show the link to open it by hand. */
  const showMoveLink = ref(false);
  let cancelled = false;
  onUnmounted(() => {
    cancelled = true;
  });

  async function reloadPage(url?: string): Promise<void> {
    // The finished job lived in the process that just exited — do not reopen it.
    ui.overlay = null;
    await nextTick();
    if (url) window.location.href = url;
    else window.location.reload();
  }

  /** The restart is scheduled a few seconds after the job ends: wait for the
   *  panel to go away and answer again (or to report a new running commit). */
  async function waitForRestart(runningHash: string | null | undefined): Promise<void> {
    restarting.value = true;
    const started = Date.now();
    let sawDown = false;
    while (!cancelled && Date.now() - started < RESTART_TIMEOUT_MS) {
      await sleep(POLL_MS);
      try {
        const next = await fetchData<PanelServiceStatus>(endpoints.panel);
        if (sawDown || (next.running_commit && next.running_commit.hash !== runningHash)) {
          await reloadPage();
          return;
        }
      } catch (error) {
        // 401 after a password change still means it is back up.
        if (error instanceof ApiError && error.status === 401) {
          await reloadPage();
          return;
        }
        sawDown = true;
      }
      // Never went down: the job failed before restarting (e.g. a rolled-back update).
      if (!sawDown && Date.now() - started > NEVER_WENT_DOWN_MS) break;
    }
    restarting.value = false;
    if (!cancelled) onGaveUp();
  }

  /** Does anything answer at `origin`? Opaque (no-cors) answers count. */
  async function answers(origin: string): Promise<boolean> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 4000);
    try {
      await fetch(`${origin}/healthz`, { mode: 'no-cors', cache: 'no-store', signal: controller.signal });
      return true;
    } catch {
      return false;
    } finally {
      clearTimeout(timer);
    }
  }

  /** The service now listens elsewhere: poll the new address, then go there. */
  async function moveTo({ port, scheme }: PanelTarget): Promise<void> {
    restarting.value = true;
    const origin = `${scheme}//${window.location.hostname}:${port}`;
    const target = `${origin}/#/settings/panel`;
    movingTo.value = target;
    showMoveLink.value = false;
    ui.overlay = null;
    const started = Date.now();
    // Let the old process go down first, so it is not mistaken for the new one
    // when only the scheme changed.
    await sleep(3000);
    while (!cancelled && Date.now() - started < MOVE_TIMEOUT_MS) {
      if (await answers(origin)) {
        await reloadPage(target);
        return;
      }
      if (Date.now() - started > MOVE_LINK_AFTER_MS) showMoveLink.value = true;
      await sleep(POLL_MS);
    }
    showMoveLink.value = true;
  }

  /** After a reconfigure: follow the panel to its new address, or wait for it in place. */
  function afterReconfigure(
    target: PanelTarget,
    runningHash: string | null | undefined,
    currentPort: number,
  ): void {
    const samePlace = target.port === currentPort && target.scheme === window.location.protocol;
    if (samePlace) void waitForRestart(runningHash);
    else void moveTo(target);
  }

  return { restarting, movingTo, showMoveLink, waitForRestart, moveTo, afterReconfigure };
}
