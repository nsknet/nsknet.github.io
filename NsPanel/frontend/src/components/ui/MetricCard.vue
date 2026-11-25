<script setup lang="ts">
/** A usage tile: label, big value, unit, sub-line and a usage bar whose colour
 *  follows the percentage (ok < 70 ≤ warn < 90 ≤ danger). */
import { computed } from 'vue';

import { usageTone } from '@/utils/format';

import Card from './Card.vue';
import LIcon from './LIcon.vue';

const props = withDefaults(
  defineProps<{
    label: string;
    value: string | number;
    unit?: string;
    sub?: string;
    icon?: string;
    /** 0–100: draws the bar. Omit for tiles without one (uptime). */
    percent?: number | null;
    loading?: boolean;
  }>(),
  { unit: '', sub: '', icon: '', percent: null, loading: false },
);

const tone = computed(() => usageTone(props.percent));
const barWidth = computed(() => `${Math.min(100, Math.max(0, props.percent ?? 0))}%`);
</script>

<template>
  <Card class="p-4 flex flex-col gap-1 min-w-0">
    <div class="flex items-center justify-between gap-2">
      <span class="text-xs-var font-medium uppercase tracking-[0.06em] text-c-tx2">{{ label }}</span>
      <LIcon v-if="icon" :name="icon" is="width:15px;height:15px;color:var(--text-3)" />
    </div>
    <div v-if="loading" class="skeleton h-7 w-24 mt-1"></div>
    <div v-else class="flex items-baseline gap-1 min-w-0">
      <span class="text-[26px] leading-tight font-semibold tracking-[-0.02em] tabular-nums truncate">{{ value }}</span>
      <span v-if="unit" class="text-sm-var text-c-tx2">{{ unit }}</span>
    </div>
    <div v-if="sub" class="text-xs-var text-c-tx2 truncate">{{ sub }}</div>
    <div
      v-if="percent !== null"
      class="bar"
      :class="`bar-${tone}`"
      role="meter"
      :aria-label="`${label} usage`"
      :aria-valuenow="Math.round(percent)"
      aria-valuemin="0"
      aria-valuemax="100"
    >
      <span :style="{ width: barWidth }"></span>
    </div>
    <slot />
  </Card>
</template>
