<script setup lang="ts">
/** An audit entry's detail as `key=value` chips; free text stays plain. */
import type { AuditDetailPart } from '@/api/settings';

defineProps<{ parts: AuditDetailPart[] }>();
</script>

<template>
  <span v-if="!parts.length" class="text-c-tx3">—</span>
  <ul v-else class="m-0 p-0 list-none flex flex-wrap gap-1">
    <li
      v-for="(part, index) in parts"
      :key="`${index}-${part.key}`"
      :class="[
        'min-w-0 max-w-full break-all mono text-xs-var',
        part.key
          ? 'px-1.5 py-0.5 rounded-theme-sm bg-c-subtle border border-c-border text-c-tx'
          : 'text-c-tx2 py-0.5',
      ]"
    >
      <span v-if="part.key" class="text-c-tx3">{{ part.key }}=</span>{{ part.value }}
    </li>
  </ul>
</template>
