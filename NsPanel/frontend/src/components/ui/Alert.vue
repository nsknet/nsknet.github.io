<script setup lang="ts">
/** An inline callout: info, success, warning or danger, with an optional action slot. */
import { computed } from 'vue';

import LIcon from './LIcon.vue';

const props = withDefaults(
  defineProps<{ tone?: 'info' | 'ok' | 'warn' | 'danger'; title?: string; icon?: string }>(),
  { tone: 'info', title: '', icon: '' },
);

const STYLE = {
  info: { cls: 'bg-c-infosoft text-c-info', icon: 'info' },
  ok: { cls: 'bg-c-oksoft text-c-ok', icon: 'circle-check' },
  warn: { cls: 'bg-c-warnsoft text-c-warn', icon: 'triangle-alert' },
  danger: { cls: 'bg-c-dngsoft text-c-danger', icon: 'octagon-x' },
};
const style = computed(() => STYLE[props.tone]);
</script>

<template>
  <div
    :role="tone === 'danger' || tone === 'warn' ? 'alert' : 'status'"
    :class="['flex items-start gap-2.5 py-2.5 px-3 rounded-theme text-sm-var', style.cls]"
  >
    <LIcon is="width:16px;height:16px;flex-shrink:0;margin-top:2px" :name="icon || style.icon" />
    <div class="flex-1 min-w-0">
      <div v-if="title" class="font-semibold">{{ title }}</div>
      <div :class="[title ? 'mt-0.5' : '', 'text-c-tx break-words']"><slot /></div>
    </div>
    <div v-if="$slots.action" class="shrink-0 self-center"><slot name="action" /></div>
  </div>
</template>
