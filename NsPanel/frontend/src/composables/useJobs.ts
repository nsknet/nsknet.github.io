/** Run an action and watch it: POST, then open the live-output overlay.
 *
 * Every screen action goes through here, so the toast-on-failure and the
 * reload-when-done behaviour are defined once.
 */
import { ApiError, isJobResponse, postAction } from '@/api/client';
import type { JobResponse, MessageResponse } from '@/api/types';
import { useUiStore } from '@/stores/ui';

import { useReload } from './useScreenData';

export function useJobRunner() {
  const ui = useUiStore();
  const reload = useReload();

  /**
   * POST `path`, then either stream the job in the overlay or toast the message.
   * Returns the parsed response, or null when the request failed.
   */
  async function run(
    path: string,
    fields: Record<string, unknown> = {},
    options: { title?: string; onDone?: () => void } = {},
  ): Promise<JobResponse | MessageResponse | null> {
    try {
      const result = await postAction(path, fields);

      if (isJobResponse(result)) {
        ui.openOverlay({
          jobId: result.job_id,
          title: options.title || result.title,
          onDone: () => {
            void reload();
            options.onDone?.();
          },
        });
      } else {
        ui.addToast({
          t: 'Success',
          d: (result as MessageResponse).message || 'Action completed successfully.',
          k: 'ok',
        });
        void reload();
        options.onDone?.();
      }
      return result as JobResponse | MessageResponse;
    } catch (error) {
      ui.addToast({
        t: error instanceof ApiError ? 'Action failed' : 'Network error',
        d: error instanceof Error ? error.message : String(error),
        k: 'danger',
      });
      return null;
    }
  }

  return { run, reload };
}
