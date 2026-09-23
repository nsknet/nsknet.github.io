<script setup lang="ts">
/** Small uppercase label above a card or grid, with an optional count and action. */
withDefaults(defineProps<{ title: string; count?: string | number | null; first?: boolean }>(), {
  count: null,
  first: false,
});
</script>

<template>
  <div :class="['flex items-center gap-2 mb-2.5', first ? 'mt-0' : 'mt-7']">
    <h2 class="m-0 text-xs-var text-c-tx2 uppercase tracking-[0.08em] font-semibold">
      <slot name="title">{{ title }}</slot>
    </h2>
    <span
      v-if="count !== null"
      class="inline-flex items-center h-[18px] px-1.5 rounded-full bg-c-subtle border border-c-border text-[11px] text-c-tx2 mono tabular-nums"
      >{{ count }}</span
    >
    <div v-if="$slots.default" class="ml-auto flex items-center gap-2">
      <slot />
    </div>
  </div>
</template>
