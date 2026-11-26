import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, nextTick } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

import ConfirmDialog from '../ConfirmDialog.vue';

import BaseDialog from './BaseDialog.vue';
import DataTable from './DataTable.vue';

const router = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:p(.*)*', component: { render: () => null } }],
});

describe('ConfirmDialog', () => {
  beforeEach(() => setActivePinia(createPinia()));

  it('enables a danger action only after the name is typed', async () => {
    const onYes = vi.fn();
    const wrapper = mount(ConfirmDialog, {
      props: {
        confirm: {
          title: 'Format /dev/sdb?',
          body: 'All data is erased.',
          onYes,
          danger: true,
          confirmLabel: 'Format',
          typeToConfirm: '/dev/sdb',
        },
      },
      attachTo: document.body,
    });
    const button = () => wrapper.findAll('button').find((b) => b.text() === 'Format')!;
    expect(button().attributes('disabled')).toBeDefined();
    await wrapper.find('input').setValue('/dev/sda');
    expect(button().attributes('disabled')).toBeDefined();
    await wrapper.find('input').setValue('/dev/sdb');
    expect(button().attributes('disabled')).toBeUndefined();
    await button().trigger('click');
    expect(onYes).toHaveBeenCalledOnce();
    wrapper.unmount();
  });
});

describe('BaseDialog', () => {
  it('closes only the top dialog on Escape', async () => {
    const outerClose = vi.fn();
    const innerClose = vi.fn();
    const Host = defineComponent({
      setup: () => () =>
        h(BaseDialog, { title: 'Outer', onClose: outerClose }, () =>
          h(BaseDialog, { title: 'Inner', onClose: innerClose }, () => h('input')),
        ),
    });
    const wrapper = mount(Host, { attachTo: document.body });
    await nextTick();
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    expect(innerClose).toHaveBeenCalledOnce();
    expect(outerClose).not.toHaveBeenCalled();
    expect(wrapper.find('[role="dialog"]').attributes('aria-modal')).toBe('true');
    wrapper.unmount();
  });
});

describe('DataTable', () => {
  const rows = [
    { name: 'b', cpu: 2 },
    { name: 'a', cpu: 10 },
    { name: 'c', cpu: 1 },
  ];
  const columns = [
    { key: 'name', label: 'Name', sortable: true },
    { key: 'cpu', label: 'CPU', sortable: true },
  ];

  it('sorts numerically and reports aria-sort', async () => {
    const wrapper = mount(DataTable, {
      props: { columns, rows, rowKey: 'name', label: 'Processes', sortKey: 'cpu', sortDir: 'desc' as const },
      global: { plugins: [router] },
    });
    const names = () => wrapper.findAll('tbody tr td:first-child').map((td) => td.text());
    expect(names()).toEqual(['a', 'b', 'c']);
    expect(wrapper.findAll('th')[1].attributes('aria-sort')).toBe('descending');
    await wrapper.findAll('th button')[0].trigger('click');
    expect(names()).toEqual(['a', 'b', 'c']);
    expect(wrapper.findAll('th')[0].attributes('aria-sort')).toBe('ascending');
  });

  it('shows the error state, not "empty", when loading failed', () => {
    const wrapper = mount(DataTable, {
      props: { columns, rows: [], rowKey: 'name', label: 'x', error: 'Connection refused' },
      global: { plugins: [router] },
    });
    expect(wrapper.text()).toContain('Connection refused');
    expect(wrapper.text()).not.toContain('Nothing here yet');
  });
});
