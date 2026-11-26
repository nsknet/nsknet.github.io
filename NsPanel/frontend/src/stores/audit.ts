/** The audit log, paged and searched on the server (GET /api/v1/logs?limit&offset&q).
 *
 * Replaces the old `useLogsStore` (which loaded a fixed tail): `load(q)` starts
 * over with a new search, `loadMore()` appends the next page. Entries come
 * newest first, so appending keeps the order.
 */
import { defineStore } from 'pinia';
import { ref } from 'vue';

import { ApiError, endpoints, fetchData } from '@/api/client';
import type { AuditDetailPart, AuditRow } from '@/api/settings';
import type { RawAuditEntry } from '@/api/types';

import { useUiStore } from './ui';

export const AUDIT_PAGE = 100;

/** `name=demo label='Install X' port=80` → chips. Quoted values keep their spaces. */
export function parseDetail(detail: string): AuditDetailPart[] {
  const text = detail.trim();
  if (!text) return [];
  const parts: AuditDetailPart[] = [];
  const pattern = /([A-Za-z0-9_.-]+)=('[^']*'|"[^"]*"|\S+)/g;
  let rest = text;
  for (const match of text.matchAll(pattern)) {
    parts.push({ key: match[1], value: match[2].replace(/^(['"])(.*)\1$/, '$2') });
    rest = rest.replace(match[0], '');
  }
  const leftover = rest.trim();
  if (leftover) parts.push({ key: '', value: leftover });
  return parts;
}

function toRow(raw: RawAuditEntry, id: number): AuditRow {
  const action = raw.action ?? '';
  return {
    id,
    ts: raw.ts ?? '',
    action,
    namespace: action.split('.')[0] ?? '',
    detail: parseDetail(raw.detail ?? ''),
    rawDetail: raw.detail ?? '',
    user: raw.user ?? '',
    ip: raw.ip ?? '',
  };
}

export const useAuditStore = defineStore('audit', () => {
  const entries = ref<AuditRow[]>([]);
  const loading = ref(false);
  const loadingMore = ref(false);
  const loaded = ref(false);
  const error = ref<string | null>(null);
  /** The last page was full, so the server may have more. */
  const hasMore = ref(false);
  /** The search the loaded entries belong to. */
  const query = ref('');
  let generation = 0;

  async function fetchPage(q: string, offset: number): Promise<AuditRow[]> {
    const params: Record<string, string> = { limit: String(AUDIT_PAGE), offset: String(offset) };
    if (q) params.q = q;
    const raw = await fetchData<RawAuditEntry[]>(endpoints.logs, params);
    return raw.map((entry, index) => toRow(entry, offset + index));
  }

  function fail(err: unknown, silent: boolean): void {
    if (err instanceof ApiError && err.status === 401) return;
    const message = err instanceof Error ? err.message : String(err);
    error.value = message;
    if (!silent) useUiStore().addToast({ t: 'Could not load the audit log', d: message, k: 'danger' });
  }

  /** First page for `q` (replaces what is loaded). */
  async function load(q = query.value, { silent = false } = {}): Promise<void> {
    const mine = ++generation;
    query.value = q;
    loading.value = true;
    try {
      const rows = await fetchPage(q, 0);
      if (mine !== generation) return;
      entries.value = rows;
      hasMore.value = rows.length === AUDIT_PAGE;
      loaded.value = true;
      error.value = null;
    } catch (err) {
      if (mine === generation) fail(err, silent);
    } finally {
      if (mine === generation) loading.value = false;
    }
  }

  /** The next page of the current search, appended. */
  async function loadMore(): Promise<void> {
    if (loadingMore.value || !hasMore.value) return;
    const mine = generation;
    loadingMore.value = true;
    try {
      const rows = await fetchPage(query.value, entries.value.length);
      if (mine !== generation) return;
      entries.value = [...entries.value, ...rows];
      hasMore.value = rows.length === AUDIT_PAGE;
    } catch (err) {
      if (mine === generation) fail(err, false);
    } finally {
      loadingMore.value = false;
    }
  }

  return { entries, loading, loadingMore, loaded, error, hasMore, query, load, loadMore };
});
