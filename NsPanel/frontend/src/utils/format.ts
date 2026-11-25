/** Display formatting shared by every screen. */

export function fmtDate(value: string | number | null | undefined): string {
  if (value === null || value === undefined || value === '') return '—';
  const date = typeof value === 'number' ? new Date(value * 1000) : new Date(value);
  return Number.isNaN(date.getTime()) ? String(value) : date.toLocaleString();
}

/** "just now", "5 min ago", "3 h ago", "2 d ago". Accepts ISO strings or epoch seconds. */
export function ago(value: string | number | null | undefined, now = Date.now()): string {
  if (value === null || value === undefined || value === '') return 'never';
  const ms = typeof value === 'number' ? value * 1000 : Date.parse(value);
  if (Number.isNaN(ms)) return String(value);
  const seconds = Math.max(0, (now - ms) / 1000);
  if (seconds < 45) return 'just now';
  if (seconds < 3600) return `${Math.max(1, Math.round(seconds / 60))} min ago`;
  if (seconds < 86400) return `${Math.round(seconds / 3600)} h ago`;
  return `${Math.round(seconds / 86400)} d ago`;
}

/** 0.4 → "0.4s", 75 → "1m 15s", 3700 → "1h 1m". */
export function duration(seconds: number | null | undefined): string {
  if (seconds === null || seconds === undefined || Number.isNaN(seconds)) return '—';
  if (seconds < 10) return `${seconds.toFixed(1)}s`;
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const m = Math.floor(seconds / 60);
  if (m < 60) return `${m}m ${Math.round(seconds % 60)}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

/** Gigabytes with sensible precision: 0.5 → "512 MB", 12.34 → "12.3 GB". */
export function gb(value: number | null | undefined): string {
  if (value === null || value === undefined) return '—';
  if (value < 1) return `${Math.round(value * 1024)} MB`;
  return `${value < 100 ? value.toFixed(1) : Math.round(value)} GB`;
}

export function pct(value: number | null | undefined): string {
  return value === null || value === undefined ? '—' : `${Math.round(value)}%`;
}

/** Tone for a usage percentage: ok < 70 ≤ warn < 90 ≤ danger. */
export function usageTone(value: number | null | undefined): 'ok' | 'warn' | 'danger' {
  if (!value || value < 70) return 'ok';
  return value < 90 ? 'warn' : 'danger';
}

/** `/api/v1/services/${name}/start` with every dynamic part URL-encoded. */
export function apiPath(strings: TemplateStringsArray, ...parts: (string | number)[]): string {
  return strings.reduce(
    (out, text, i) => out + text + (i < parts.length ? encodeURIComponent(String(parts[i])) : ''),
    '',
  );
}
