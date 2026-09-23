<script setup lang="ts">
/** Soft status pill. */
import { computed } from 'vue';

import type { Tone } from './types';

const props = withDefaults(defineProps<{ tone?: Tone; dot?: boolean }>(), {
  tone: 'neutral',
  dot: false,
});

const BASE =
  'inline-flex items-center gap-1.5 px-2 h-[22px] rounded-full text-xs-var font-medium tabular-nums border whitespace-nowrap shrink-0';

const TONE: Record<Tone, string> = {
  ok: 'bg-c-oksoft text-c-ok border-transparent',
  warn: 'bg-c-warnsoft text-c-warn border-transparent',
  danger: 'bg-c-dngsoft text-c-danger border-transparent',
  info: 'bg-c-infosoft text-c-info border-transparent',
  accent: 'bg-c-acsoft text-c-actx border-transparent',
  muted: 'bg-c-muted text-c-tx2 border-transparent',
  neutral: 'bg-c-subtle text-c-tx2 border-c-border',
};

const cls = computed(() => [BASE, TONE[props.tone] ?? TONE.neutral]);
const dotCls = computed(() => [
  'w-1.5 h-1.5 rounded-full',
  props.tone === 'neutral' || props.tone === 'muted' ? 'bg-c-tx3' : 'bg-current',
  props.tone === 'ok' ? 'shadow-[0_0_0_3px_var(--ok-soft)]' : '',
]);
</script>

<template>
  <span :class="cls"><span v-if="dot" :class="dotCls"></span><slot /></span>
</template>
