import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it } from 'vitest';

import { ApiError } from '@/api/client';

import { createResource } from './resource';
import { useUiStore } from './ui';

describe('createResource', () => {
  beforeEach(() => setActivePinia(createPinia()));

  it('keeps the last good data and records the error', async () => {
    let fail = false;
    const res = createResource<number[]>([], async () => {
      if (fail) throw new Error('boom');
      return [1, 2];
    });
    await res.load();
    expect(res.data.value).toEqual([1, 2]);
    expect(res.error.value).toBeNull();

    fail = true;
    await res.load();
    expect(res.data.value).toEqual([1, 2]);
    expect(res.error.value).toBe('boom');
    expect(useUiStore().toasts).toHaveLength(1);
  });

  it('raises no toast for silent loads', async () => {
    const res = createResource(0, async () => {
      throw new Error('offline');
    });
    await res.load({ silent: true });
    expect(res.error.value).toBe('offline');
    expect(useUiStore().toasts).toHaveLength(0);
  });

  it('stays quiet on 401 (the shell shows the login screen)', async () => {
    const res = createResource(0, async () => {
      throw new ApiError('Not signed in', 401);
    });
    await res.load();
    expect(useUiStore().toasts).toHaveLength(0);
  });

  it('applies only the newest of overlapping loads', async () => {
    const resolvers: ((value: string) => void)[] = [];
    const res = createResource('', () => new Promise<string>((resolve) => resolvers.push(resolve)));
    const first = res.load();
    const second = res.load();
    resolvers[1]('new');
    resolvers[0]('old');
    await Promise.all([first, second]);
    expect(res.data.value).toBe('new');
    expect(res.loading.value).toBe(false);
  });
});

describe('ui toasts', () => {
  beforeEach(() => setActivePinia(createPinia()));

  it('folds repeats into a counter', () => {
    const ui = useUiStore();
    ui.addToast({ t: 'Could not load data', d: 'offline', k: 'danger' });
    ui.addToast({ t: 'Could not load data', d: 'offline', k: 'danger' });
    expect(ui.toasts).toHaveLength(1);
    expect(ui.toasts[0].count).toBe(2);
  });

  it('keeps errors until dismissed', () => {
    const ui = useUiStore();
    ui.addToast({ t: 'x', k: 'danger' });
    ui.dismissToast(ui.toasts[0].id);
    expect(ui.toasts).toHaveLength(0);
  });
});
