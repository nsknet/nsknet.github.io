<script setup lang="ts" generic="Row extends Record<string, any>">
/** The table every list screen uses.
 *
 * - Scrolls horizontally inside its card instead of clipping on small screens.
 * - Sortable headers are real buttons with aria-sort.
 * - `rowTo` makes each row a keyboard-reachable link (the first cell holds the
 *   RouterLink; the whole row is clickable for the mouse).
 * - Loading, error and empty states are built in, so a failed load is never
 *   shown as "nothing here".
 * - Cells render `row[col.key]`, or a `#cell-<key>` slot `{ row, value }`.
 */
import { computed, ref } from 'vue';
import { RouterLink, useRouter, type RouteLocationRaw } from 'vue-router';

import EmptyState from './EmptyState.vue';
import ErrorState from './ErrorState.vue';
import LIcon from './LIcon.vue';
import type { Column } from './types';

const props = withDefaults(
  defineProps<{
    columns: Column<Row>[];
    rows: Row[];
    rowKey: keyof Row | ((row: Row) => string | number);
    /** Accessible name of the table. */
    label: string;
    loading?: boolean;
    error?: string | null;
    emptyTitle?: string;
    emptyHint?: string;
    emptyIcon?: string;
    rowTo?: (row: Row) => RouteLocationRaw;
    /** Initial sort. */
    sortKey?: string;
    sortDir?: 'asc' | 'desc';
    /** Rows with this returning true get a muted style. */
    rowMuted?: (row: Row) => boolean;
    /** Extra classes per row (e.g. highlight a heavy process). */
    rowClass?: (row: Row) => string;
  }>(),
  {
    loading: false,
    error: null,
    emptyTitle: 'Nothing here yet',
    emptyHint: '',
    emptyIcon: 'inbox',
    rowTo: undefined,
    sortKey: '',
    sortDir: 'asc',
    rowMuted: undefined,
    rowClass: undefined,
  },
);
const emit = defineEmits<{ retry: [] }>();

const router = useRouter();
const sortBy = ref(props.sortKey);
const direction = ref<'asc' | 'desc'>(props.sortDir);

function keyOf(row: Row): string | number {
  return typeof props.rowKey === 'function' ? props.rowKey(row) : (row[props.rowKey] as string | number);
}

function toggleSort(column: Column<Row>): void {
  if (!column.sortable) return;
  if (sortBy.value === column.key) {
    direction.value = direction.value === 'asc' ? 'desc' : 'asc';
  } else {
    sortBy.value = column.key;
    direction.value = column.sortFirst ?? 'asc';
  }
}

const sorted = computed(() => {
  const column = props.columns.find((c) => c.key === sortBy.value);
  if (!column?.sortable) return props.rows;
  const value = (row: Row) => (column.sortValue ? column.sortValue(row) : (row[column.key] as unknown));
  const factor = direction.value === 'asc' ? 1 : -1;
  return [...props.rows].sort((a, b) => {
    const x = value(a);
    const y = value(b);
    if (typeof x === 'number' && typeof y === 'number') return (x - y) * factor;
    return String(x ?? '').localeCompare(String(y ?? ''), undefined, { numeric: true }) * factor;
  });
});

function ariaSort(column: Column<Row>): 'ascending' | 'descending' | 'none' | undefined {
  if (!column.sortable) return undefined;
  if (sortBy.value !== column.key) return 'none';
  return direction.value === 'asc' ? 'ascending' : 'descending';
}

const ALIGN = { left: 'text-left', right: 'text-right', center: 'text-center' };

function cellClass(column: Column<Row>): string[] {
  return [
    ALIGN[column.align ?? 'left'],
    column.class ?? '',
    column.hideOnMobile ? 'hidden md:table-cell' : '',
  ];
}

function onRowClick(row: Row, event: MouseEvent): void {
  if (!props.rowTo) return;
  // Let real links, buttons and text selection inside the row behave normally.
  const target = event.target as HTMLElement;
  if (target.closest('a,button,input,select,label') || window.getSelection()?.toString()) return;
  void router.push(props.rowTo(row));
}

const showSkeleton = computed(() => props.loading && !props.rows.length);
</script>

<template>
  <div class="overflow-x-auto">
    <table class="tbl" :aria-label="label" :aria-busy="loading || undefined">
      <thead>
        <tr>
          <th
            v-for="column in columns"
            :key="column.key"
            scope="col"
            :aria-sort="ariaSort(column)"
            :class="cellClass(column)"
          >
            <button
              v-if="column.sortable"
              type="button"
              class="inline-flex items-center gap-1 uppercase tracking-[0.06em] font-medium hover:text-c-tx"
              @click="toggleSort(column)"
            >
              {{ column.label }}
              <LIcon
                :is="`width:12px;height:12px;opacity:${sortBy === column.key ? 1 : 0.35}`"
                :name="
                  sortBy === column.key
                    ? direction === 'asc'
                      ? 'chevron-up'
                      : 'chevron-down'
                    : 'chevron-down'
                "
              />
            </button>
            <span v-else :class="column.srOnlyLabel ? 'sr-only' : ''">{{ column.label }}</span>
          </th>
        </tr>
      </thead>
      <tbody>
        <template v-if="showSkeleton">
          <tr v-for="n in 4" :key="`sk-${n}`">
            <td v-for="column in columns" :key="column.key" :class="cellClass(column)">
              <span class="skeleton block h-3.5 w-3/4"></span>
            </td>
          </tr>
        </template>
        <tr v-else-if="error && !rows.length">
          <td :colspan="columns.length" class="!h-auto !whitespace-normal">
            <ErrorState :message="error" @retry="emit('retry')" />
          </td>
        </tr>
        <tr v-else-if="!rows.length">
          <td :colspan="columns.length" class="!h-auto !whitespace-normal">
            <EmptyState :icon="emptyIcon" :title="emptyTitle" :hint="emptyHint">
              <slot name="empty" />
            </EmptyState>
          </td>
        </tr>
        <template v-else>
          <tr
            v-for="row in sorted"
            :key="keyOf(row)"
            :class="[rowTo ? 'row-click' : '', rowMuted?.(row) ? 'text-c-tx3' : '', rowClass?.(row) ?? '']"
            @click="onRowClick(row, $event)"
          >
            <td v-for="(column, index) in columns" :key="column.key" :class="cellClass(column)">
              <RouterLink
                v-if="rowTo && index === 0"
                :to="rowTo(row)"
                class="text-inherit no-underline hover:underline underline-offset-2 focus-visible:underline"
              >
                <slot :name="`cell-${column.key}`" :row="row" :value="row[column.key]">{{
                  row[column.key]
                }}</slot>
              </RouterLink>
              <slot v-else :name="`cell-${column.key}`" :row="row" :value="row[column.key]">{{
                row[column.key] ?? '—'
              }}</slot>
            </td>
          </tr>
        </template>
      </tbody>
    </table>
  </div>
</template>
