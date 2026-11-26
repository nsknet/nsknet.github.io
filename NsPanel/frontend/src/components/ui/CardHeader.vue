<script setup lang="ts">
/** The title row of a card: icon + title (+ subtitle) on the left, actions right. */
import LIcon from './LIcon.vue';

withDefaults(defineProps<{ title: string; icon?: string; subtitle?: string; level?: 2 | 3 }>(), {
  icon: '',
  subtitle: '',
  level: 2,
});
</script>

<template>
  <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-2 py-3 px-4 border-b border-c-border">
    <div class="min-w-0 flex items-center gap-2">
      <LIcon is="width:15px;height:15px;color:var(--text-2);flex-shrink:0" v-if="icon" :name="icon" />
      <component :is="`h${level}`" class="m-0 text-sm-var font-semibold tracking-[-0.01em] truncate">
        {{ title }}
      </component>
      <span v-if="subtitle || $slots.subtitle" class="text-xs-var text-c-tx3 truncate">
        <slot name="subtitle">{{ subtitle }}</slot>
      </span>
    </div>
    <div v-if="$slots.default" class="flex flex-wrap items-center gap-1.5">
      <slot />
    </div>
  </div>
</template>
