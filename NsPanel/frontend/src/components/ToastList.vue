<script setup lang="ts">
/** Toasts: announced to screen readers, dismissible, errors stay until closed. */
import { storeToRefs } from 'pinia';

import { useUiStore, type ToastKind } from '@/stores/ui';

import LIcon from './ui/LIcon.vue';

const ui = useUiStore();
const { toasts } = storeToRefs(ui);

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
  <div
    class="fixed bottom-4 right-4 left-4 sm:left-auto z-[300] flex flex-col items-stretch sm:items-end gap-2 pointer-events-none"
    aria-live="polite"
    aria-relevant="additions"
  >
    <div
      v-for="toast in toasts"
      :key="toast.id"
      :role="toast.k === 'danger' ? 'alert' : 'status'"
      class="pointer-events-auto flex items-start gap-2.5 sm:w-[360px] py-2.5 pl-3 pr-1.5 bg-c-card border border-c-border rounded-theme shadow-md text-sm-var animate-slidein"
    >
      <LIcon
        :name="ICON[toast.k] ?? 'info'"
        :is="`width:16px;height:16px;flex-shrink:0;margin-top:2px;color:${COLOR[toast.k] ?? COLOR.info}`"
      />
      <div class="flex-1 min-w-0">
        <div class="font-medium">
          {{ toast.t }}
          <span v-if="toast.count > 1" class="ml-1 text-c-tx3 tabular-nums">×{{ toast.count }}</span>
        </div>
        <div v-if="toast.d" class="text-c-tx2 text-xs-var mt-px break-words">{{ toast.d }}</div>
      </div>
      <button
        type="button"
        class="shrink-0 w-7 h-7 grid place-items-center rounded-md text-c-tx3 hover:text-c-tx hover:bg-c-hover"
        aria-label="Dismiss notification"
        @click="ui.dismissToast(toast.id)"
      >
        <LIcon name="x" is="width:14px;height:14px" />
      </button>
    </div>
  </div>
</template>
