<script setup lang="ts">
/** The "nothing here" block used inside tables and card grids. */
import LIcon from './LIcon.vue';

withDefaults(defineProps<{ icon?: string; title: string; hint?: string }>(), {
  icon: 'search-x',
  hint: '',
});
</script>

<template>
  <div class="text-center py-8 px-6 text-c-tx2">
    <div class="w-11 h-11 rounded-xl bg-c-subtle grid place-items-center mx-auto mb-3">
      <LIcon :name="icon" is="width:20px;height:20px;color:var(--text-3)" />
    </div>
    <div class="text-c-tx font-medium text-sm-var">{{ title }}</div>
    <div v-if="hint" class="text-xs-var mt-1"><slot>{{ hint }}</slot></div>
    <div v-else-if="$slots.default" class="text-xs-var mt-1"><slot /></div>
  </div>
</template>
