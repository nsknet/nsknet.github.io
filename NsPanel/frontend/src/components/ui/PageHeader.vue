<script setup lang="ts">
/** Screen title row: heading + one-line subtitle on the left, actions on the right. */
withDefaults(defineProps<{ title: string; subtitle?: string; mono?: boolean }>(), {
  subtitle: '',
  mono: false,
});
</script>

<template>
  <div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-3 mb-6">
    <div class="min-w-0">
      <h1 class="text-[22px] font-semibold tracking-[-0.02em] leading-tight mb-1 flex items-center gap-2.5">
        <slot name="title">{{ title }}</slot>
      </h1>
      <div v-if="subtitle || $slots.subtitle" :class="['text-sm-var text-c-tx2', { mono }]">
        <slot name="subtitle">{{ subtitle }}</slot>
      </div>
    </div>
    <div v-if="$slots.default" class="flex flex-wrap gap-2">
      <slot />
    </div>
  </div>
</template>
