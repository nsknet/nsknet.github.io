<script setup lang="ts">
import { storeToRefs } from 'pinia';

import { useUiStore, type ToastKind } from '@/stores/ui';

import LIcon from './ui/LIcon.vue';

const { toasts } = storeToRefs(useUiStore());

const ICON: Record<ToastKind, string> = {
  info: 'info',
  warn: 'triangle-alert',
  danger: 'octagon-x',
  ok: 'circle-check-big',
};

const COLOR: Record<ToastKind, string> = {
  info: 'var(--info)',
  warn: 'var(--warn)',
  danger: 'var(--danger)',
  ok: 'var(--ok)',
};
</script>

<template>
  <div class="fixed bottom-4 right-4 z-[300] flex flex-col gap-2 pointer-events-none">
    <div
      v-for="toast in toasts"
      :key="toast.id"
      class="pointer-events-auto flex items-start gap-2.5 min-w-[260px] max-w-[360px] py-2.5 px-3 bg-c-bg border border-c-border rounded-theme shadow-md text-sm-var animate-slidein"
    >
      <LIcon
        :name="ICON[toast.k] ?? 'info'"
        :is="`width:16px;height:16px;flex-shrink:0;margin-top:2px;color:${COLOR[toast.k] ?? COLOR.info}`"
      />
      <div class="flex-1">
        <div class="font-medium">{{ toast.t }}</div>
        <div v-if="toast.d" class="text-c-tx2 text-xs-var mt-px">{{ toast.d }}</div>
      </div>
    </div>
  </div>
</template>
