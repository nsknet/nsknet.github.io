<script setup lang="ts">
/** Loading placeholder shaped like the content it stands in for. */
withDefaults(defineProps<{ variant?: 'rows' | 'cards'; count?: number; min?: string }>(), {
  variant: 'rows',
  count: 5,
  min: '280px',
});
</script>

<template>
  <div v-if="variant === 'rows'" class="py-1" aria-busy="true" aria-label="Loading">
    <div
      v-for="n in count"
      :key="n"
      class="flex items-center gap-4 px-3.5 h-[var(--row-h)] border-b border-c-border last:border-b-0"
    >
      <div class="skeleton h-3 w-[22%]"></div>
      <div class="skeleton h-3 w-[12%]"></div>
      <div class="skeleton h-3 flex-1 max-w-[30%]"></div>
      <div class="skeleton h-3 w-[10%] ml-auto"></div>
    </div>
  </div>
  <div
    v-else
    class="grid gap-3"
    :style="{ gridTemplateColumns: `repeat(auto-fill, minmax(${min}, 1fr))` }"
    aria-busy="true"
    aria-label="Loading"
  >
    <div
      v-for="n in count"
      :key="n"
      class="bg-c-card border border-c-border rounded-theme shadow-card p-[18px] flex flex-col gap-3"
    >
      <div class="flex items-center gap-3">
        <div class="skeleton w-10 h-10 rounded-[9px]"></div>
        <div class="flex-1 flex flex-col gap-2">
          <div class="skeleton h-3 w-1/2"></div>
          <div class="skeleton h-2.5 w-4/5"></div>
        </div>
      </div>
      <div class="skeleton h-2.5 w-full"></div>
      <div class="skeleton h-2.5 w-2/3"></div>
    </div>
  </div>
</template>
