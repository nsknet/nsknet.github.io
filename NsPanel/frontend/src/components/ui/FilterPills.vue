<script setup lang="ts">
/** A single-choice filter shown as pills (a radio group under the hood). */
const model = defineModel<string>({ required: true });
defineProps<{ options: { value: string; label: string; count?: number }[]; label: string }>();
</script>

<template>
  <div role="radiogroup" :aria-label="label" class="flex flex-wrap gap-1.5">
    <button
      v-for="option in options"
      :key="option.value"
      type="button"
      role="radio"
      :aria-checked="model === option.value"
      :class="[
        'inline-flex items-center gap-1.5 h-8 px-3 rounded-full border text-sm-var transition-colors',
        model === option.value
          ? 'bg-c-tx text-c-txinv border-transparent'
          : 'bg-c-card border-c-border text-c-tx2 hover:text-c-tx hover:border-c-bstrong',
      ]"
      @click="model = option.value"
    >
      {{ option.label }}
      <span v-if="option.count !== undefined" class="tabular-nums opacity-70 text-xs-var">{{
        option.count
      }}</span>
    </button>
  </div>
</template>
