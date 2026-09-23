/** The only place that talks to the panel API.
 *
 * Two envelopes exist (see NsPanel/docs/ARCHITECTURE.md): a read returns
 * `{status, data}`, an action returns `{status, job_id, title}`. `fetchData`
 * unwraps the first; `postAction` returns the second so the caller can stream it.
 */
import type { DataResponse, JobResponse, MessageResponse } from './types';

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

async function detailOf(response: Response): Promise<string> {
  try {
    const body = await response.json();
    if (typeof body?.detail === 'string') return body.detail;
    // FastAPI validation errors arrive as a list of {loc, msg}.
    if (Array.isArray(body?.detail)) {
      return body.detail
        .map((e: { loc?: unknown[]; msg?: string }) => {
          const field = Array.isArray(e.loc) ? String(e.loc[e.loc.length - 1]) : '';
          return field ? `${field}: ${e.msg}` : e.msg;
        })
        .join('; ');
    }
  } catch {
    /* not JSON — fall through to the status text */
  }
  return response.statusText || 'Request failed';
}

/** GET a read endpoint and return its `data` payload. */
export async function fetchData<T>(path: string, params?: Record<string, string>): Promise<T> {
  const query = params && Object.keys(params).length ? `?${new URLSearchParams(params)}` : '';
  const response = await fetch(`${path}${query}`);
  if (!response.ok) throw new ApiError(await detailOf(response), response.status);
  const body: DataResponse<T> = await response.json();
  return body.data;
}

function formBody(fields: Record<string, unknown>): URLSearchParams {
  const form = new URLSearchParams();
  for (const [key, value] of Object.entries(fields)) {
    if (value !== null && value !== undefined) form.append(key, String(value));
  }
  return form;
}

/** POST an action endpoint. Throws ApiError with the server's detail message. */
export async function postAction<T = JobResponse | MessageResponse>(
  path: string,
  fields: Record<string, unknown> = {},
): Promise<T> {
  const response = await fetch(path, { method: 'POST', body: formBody(fields) });
  if (!response.ok) throw new ApiError(await detailOf(response), response.status);
  return (await response.json()) as T;
}

export function isJobResponse(value: unknown): value is JobResponse {
  return typeof value === 'object' && value !== null && 'job_id' in value;
}

export const endpoints = {
  system: '/api/v1/system',
  disks: '/api/v1/system/disks',
  sites: '/api/v1/sites',
  tools: '/api/v1/tools',
  services: '/api/v1/services',
  dns: '/api/v1/dns',
  firewall: '/api/v1/firewall',
  logs: '/api/v1/logs',
  processes: '/api/v1/processes',
} as const;
