<script setup lang="ts">
/** A single choice shown as cards — real radio inputs underneath, so arrow keys,
 *  Tab and screen readers behave as for any radio group. */
import { useId } from 'vue';

import LIcon from '@/components/ui/LIcon.vue';

const model = defineModel<string>({ required: true });
withDefaults(
  defineProps<{
    legend: string;
    options: { value: string; label: string; hint?: string; icon?: string }[];
    /** Visually hide the legend (it stays for screen readers). */
    hideLegend?: boolean;
    /** Tailwind grid classes for the layout. */
    grid?: string;
  }>(),
  { hideLegend: false, grid: 'grid-cols-1 sm:grid-cols-2' },
);

const name = useId();
</script>

<template>
  <fieldset class="m-0 p-0 border-0 min-w-0">
    <legend :class="['p-0 mb-1.5 text-sm-var font-medium text-c-tx', hideLegend ? 'sr-only' : '']">{{ legend }}</legend>
    <div :class="['grid gap-2', grid]">
      <label
        v-for="option in options"
        :key="option.value"
        :class="[
          'relative flex flex-col gap-1 py-3 px-3.5 rounded-theme-sm border cursor-pointer select-none transition-colors',
          'has-[input:focus-visible]:shadow-[0_0_0_3px_var(--focus)]',
          model === option.value
            ? 'border-c-accent bg-c-acsoft'
            : 'border-c-border bg-c-bg hover:border-c-bstrong',
        ]"
      >
        <input v-model="model" type="radio" :name="name" :value="option.value" class="sr-only" />
        <span class="flex items-center gap-2 text-sm-var font-medium text-c-tx">
          <LIcon
            v-if="option.icon"
            :name="option.icon"
            :is="`width:15px;height:15px;flex-shrink:0;color:var(${model === option.value ? '--accent' : '--text-2'})`"
          />
          {{ option.label }}
          <LIcon
            v-if="model === option.value"
            name="circle-check"
            is="width:15px;height:15px;margin-left:auto;color:var(--accent)"
          />
        </span>
        <span v-if="option.hint" class="text-xs-var text-c-tx2">{{ option.hint }}</span>
      </label>
    </div>
  </fieldset>
</template>
