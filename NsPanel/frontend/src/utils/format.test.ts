import { describe, expect, it } from 'vitest';

import { ago, apiPath, duration, gb, usageTone } from './format';

describe('format', () => {
  it('describes how long ago', () => {
    const now = Date.parse('2026-11-26T12:00:00Z');
    expect(ago('2026-11-26T11:59:50Z', now)).toBe('just now');
    expect(ago('2026-11-26T11:50:00Z', now)).toBe('10 min ago');
    expect(ago('2026-11-26T09:00:00Z', now)).toBe('3 h ago');
    expect(ago(null, now)).toBe('never');
    expect(ago(Date.parse('2026-11-24T12:00:00Z') / 1000, now)).toBe('2 d ago');
  });

  it('formats durations', () => {
    expect(duration(0.4)).toBe('0.4s');
    expect(duration(75)).toBe('1m 15s');
    expect(duration(3700)).toBe('1h 1m');
    expect(duration(null)).toBe('—');
  });

  it('formats sizes and tones', () => {
    expect(gb(0.5)).toBe('512 MB');
    expect(gb(12.34)).toBe('12.3 GB');
    expect(usageTone(50)).toBe('ok');
    expect(usageTone(80)).toBe('warn');
    expect(usageTone(95)).toBe('danger');
  });

  it('encodes every dynamic path part', () => {
    const name = 'a b/../c';
    expect(apiPath`/api/v1/services/${name}/start`).toBe('/api/v1/services/a%20b%2F..%2Fc/start');
  });
});
