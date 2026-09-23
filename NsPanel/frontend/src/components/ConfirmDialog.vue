<script setup lang="ts">
import { onMounted, onUnmounted } from 'vue';

import type { Confirm } from '@/stores/ui';

import Btn from './ui/Btn.vue';
import LIcon from './ui/LIcon.vue';

const props = defineProps<{ confirm: Confirm }>();
const emit = defineEmits<{ close: [] }>();

function dismiss(): void {
  emit('close');
}

function onYes(): void {
  dismiss();
  props.confirm.onYes?.();
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key === 'Escape') dismiss();
}

onMounted(() => document.addEventListener('keydown', onKeydown));
onUnmounted(() => document.removeEventListener('keydown', onKeydown));
</script>

<template>
  <div
    class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade"
    @click.self="dismiss"
  >
    <div class="max-w-[420px] bg-c-card border border-c-border rounded-theme-lg shadow-lg p-5">
      <div
        class="w-10 h-10 rounded-[10px] bg-c-dngsoft text-c-danger grid place-items-center mb-3.5"
      >
        <LIcon name="triangle-alert" is="width:20px;height:20px" />
      </div>
      <h3 class="m-0 mb-1.5 text-base font-semibold tracking-[-0.01em]">{{ confirm.title }}</h3>
      <p class="m-0 mb-4 text-c-tx2 text-sm-var">{{ confirm.body }}</p>
      <div class="flex justify-end gap-1.5">
        <Btn @click="dismiss">Cancel</Btn>
        <Btn variant="primary" @click="onYes">Continue</Btn>
      </div>
    </div>
  </div>
</template>
