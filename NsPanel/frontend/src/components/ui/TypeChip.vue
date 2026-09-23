<script setup lang="ts">
/** The site backend type: static, proxy or .NET. */
import { computed } from 'vue';

const props = withDefaults(defineProps<{ type?: string }>(), { type: '' });

const BASE =
  'inline-flex items-center gap-1.5 px-2 py-0.5 rounded-[5px] text-xs-var mono font-medium border';
const NEUTRAL = 'bg-c-subtle text-c-tx2 border-c-border';

const CHIPS: Record<string, { cls: string; label: string }> = {
  dotnet: {
    cls: 'text-[#8b5cf6] bg-[color-mix(in_oklab,#8b5cf6_10%,transparent)] border-transparent',
    label: '.NET',
  },
  proxy: {
    cls: 'text-[#2563eb] bg-[color-mix(in_oklab,#2563eb_10%,transparent)] border-transparent',
    label: 'proxy',
  },
  static: { cls: NEUTRAL, label: 'static' },
};

const chip = computed(() => CHIPS[props.type] ?? { cls: NEUTRAL, label: props.type });
</script>

<template>
  <span :class="[BASE, chip.cls]">{{ chip.label }}</span>
</template>
