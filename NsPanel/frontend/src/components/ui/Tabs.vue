<script setup lang="ts">
/** Accessible tabs (WAI-ARIA tablist): arrow keys move between tabs. The
 *  active panel is the default slot, receiving the current tab key. */
import { useId } from 'vue';

import LIcon from './LIcon.vue';
import type { TabItem } from './types';

const active = defineModel<string>({ required: true });
const props = defineProps<{ items: TabItem[]; label: string }>();

const base = useId();

function onKeydown(event: KeyboardEvent, index: number): void {
  const delta = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
  if (!delta && event.key !== 'Home' && event.key !== 'End') return;
  event.preventDefault();
  const count = props.items.length;
  const next = event.key === 'Home' ? 0 : event.key === 'End' ? count - 1 : (index + delta + count) % count;
  active.value = props.items[next].key;
  document.getElementById(`${base}-tab-${props.items[next].key}`)?.focus();
}
</script>

<template>
  <div>
    <div
      role="tablist"
      :aria-label="label"
      class="flex gap-1 border-b border-c-border overflow-x-auto -mx-px px-px"
    >
      <button
        v-for="(item, index) in items"
        :id="`${base}-tab-${item.key}`"
        :key="item.key"
        type="button"
        role="tab"
        :aria-selected="active === item.key"
        :aria-controls="`${base}-panel`"
        :tabindex="active === item.key ? 0 : -1"
        :class="[
          'relative shrink-0 inline-flex items-center gap-1.5 h-10 px-3 text-sm-var font-medium whitespace-nowrap',
          'border-b-2 -mb-px transition-colors',
          active === item.key ? 'border-c-accent text-c-tx' : 'border-transparent text-c-tx2 hover:text-c-tx',
        ]"
        @click="active = item.key"
        @keydown="onKeydown($event, index)"
      >
        <LIcon is="width:15px;height:15px" v-if="item.icon" :name="item.icon" />
        {{ item.label }}
        <span
          v-if="item.badge !== undefined && item.badge !== ''"
          class="ml-0.5 px-1.5 rounded-full bg-c-subtle text-c-tx2 text-xs-var tabular-nums"
          >{{ item.badge }}</span
        >
      </button>
    </div>
    <div
      :id="`${base}-panel`"
      role="tabpanel"
      :aria-labelledby="`${base}-tab-${active}`"
      class="pt-4 outline-none"
      tabindex="0"
    >
      <slot :tab="active" />
    </div>
  </div>
</template>
