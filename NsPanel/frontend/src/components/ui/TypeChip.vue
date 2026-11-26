<script setup lang="ts">
/** What kind of app a row is: static, proxy, .NET, service or tunnel. */
import { computed } from 'vue';

const props = withDefaults(defineProps<{ type?: string }>(), { type: '' });

const BASE = 'inline-flex items-center gap-1.5 px-2 py-0.5 rounded-[5px] text-xs-var mono font-medium border';
const NEUTRAL = 'bg-c-subtle text-c-tx2 border-c-border';

const CHIPS: Record<string, { cls: string; label: string }> = {
  dotnet: { cls: 'bg-c-violetsoft text-c-violet border-transparent', label: '.NET' },
  proxy: { cls: 'bg-c-infosoft text-c-info border-transparent', label: 'proxy' },
  static: { cls: NEUTRAL, label: 'static' },
  service: { cls: 'bg-c-tealsoft text-c-teal border-transparent', label: 'service' },
  tunnel: { cls: 'bg-c-acsoft text-c-actx border-transparent', label: 'tunnel' },
};

const chip = computed(() => CHIPS[props.type] ?? { cls: NEUTRAL, label: props.type });
</script>

<template>
  <span :class="[BASE, chip.cls]">{{ chip.label }}</span>
</template>
