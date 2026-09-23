<script setup lang="ts">
/** A tool's logo tile. PNG logos sit on a fixed white plate so dark-coloured
 *  marks stay visible in the dark theme; text logos use the tool's colour. */
withDefaults(defineProps<{ logo: string; name: string; color?: string; size?: 'sm' | 'md'; dim?: boolean }>(), {
  color: undefined,
  size: 'md',
  dim: false,
});
</script>

<template>
  <div
    :class="[
      'flex items-center justify-center shrink-0 overflow-hidden select-none ring-1 ring-inset ring-c-border',
      size === 'sm' ? 'w-8 h-8 rounded-md p-1' : 'w-10 h-10 rounded-[9px] p-1.5',
      logo.endsWith('.png') ? 'bg-white' : 'bg-c-subtle',
      dim ? 'opacity-60 grayscale-[0.4]' : '',
    ]"
  >
    <img v-if="logo.endsWith('.png')" :src="logo" :alt="name" class="w-full h-full object-contain" />
    <span
      v-else
      :class="['font-bold mono tracking-[-0.02em]', size === 'sm' ? 'text-[11px]' : 'text-[13px]']"
      :style="{ color }"
      >{{ logo }}</span
    >
  </div>
</template>
