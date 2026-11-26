/** Run an action and watch it: POST, then open the live-output overlay.
 *
 * Every screen action goes through here, so the toast-on-failure and the
 * reload-when-done behaviour are defined once.
 */
import { ApiError, isJobResponse, postAction } from '@/api/client';
import type { JobResponse, MessageResponse } from '@/api/types';
import { useJobsStore } from '@/stores/jobs';
import { useUiStore } from '@/stores/ui';

import { useReload } from './useScreenData';

export function useJobRunner() {
  const ui = useUiStore();
  const jobs = useJobsStore();
  const reload = useReload();

  /**
   * POST `path`, then either stream the job in the overlay or toast the message.
   * Returns the parsed response, or null when the request failed.
   */
  async function run(
    path: string,
    fields: Record<string, unknown> = {},
    options: {
      title?: string;
      /** Runs when the job ends, whatever its exit code. */
      onDone?: (ok: boolean) => void;
      /** Runs only when the job ends with exit code 0 (or a sync action succeeds). */
      onSuccess?: () => void;
      /** The request itself failed (validation, 409…). When given, no toast is
       *  shown: the caller displays the error, e.g. inline in a dialog. */
      onError?: (error: Error) => void;
    } = {},
  ): Promise<JobResponse | MessageResponse | null> {
    try {
      const result = await postAction(path, fields);

      if (isJobResponse(result)) {
        ui.openOverlay({
          jobId: result.job_id,
          title: options.title || result.title,
          onDone: (ok) => {
            void reload();
            void jobs.load();
            options.onDone?.(ok);
            if (ok) options.onSuccess?.();
            else ui.addToast({ t: 'Job failed', d: options.title || result.title, k: 'danger' });
          },
        });
        // Puts the job in the header's "N running" chip.
        void jobs.load();
      } else {
        ui.addToast({
          t: 'Success',
          d: (result as MessageResponse).message || 'Action completed successfully.',
          k: 'ok',
        });
        void reload();
        options.onDone?.(true);
        options.onSuccess?.();
      }
      return result as JobResponse | MessageResponse;
    } catch (error) {
      if (options.onError) {
        options.onError(error instanceof Error ? error : new Error(String(error)));
        return null;
      }
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
