<script setup lang="ts">
/** Read-only text viewer: nginx configs, systemctl status, journal logs. */
import { computed, ref, useId } from 'vue';

import { ansiToHtml } from '@/composables/useAnsi';
import { useUiStore } from '@/stores/ui';
import { copyText } from '@/utils/clipboard';

import BaseDialog from './ui/BaseDialog.vue';
import Btn from './ui/Btn.vue';
import LIcon from './ui/LIcon.vue';

const props = withDefaults(
  defineProps<{
    title: string;
    subtitle?: string;
    content: string;
    icon?: string;
    /** Offer a download under this file name. */
    downloadName?: string;
    /** Render ANSI colour codes (journal output) instead of plain text. */
    ansi?: boolean;
    wrap?: boolean;
  }>(),
  { subtitle: '', icon: 'terminal', downloadName: '', ansi: false, wrap: true },
);

const emit = defineEmits<{ close: [] }>();

const ui = useUiStore();
const wrapId = useId();
const wordWrap = ref(props.wrap);
const html = computed(() => (props.ansi ? ansiToHtml(props.content) : ''));
const textClass = computed(() => [
  'term overflow-auto mono text-xs-var p-4 leading-relaxed select-text rounded-theme h-[min(480px,60vh)] outline-none',
  wordWrap.value ? 'whitespace-pre-wrap break-all' : 'whitespace-pre',
]);

function download(): void {
  const url = URL.createObjectURL(new Blob([props.content], { type: 'text/plain;charset=utf-8' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = props.downloadName;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
  ui.addToast({ t: 'Downloaded', d: props.downloadName, k: 'ok' });
}
</script>

<template>
  <BaseDialog :title="title" :description="subtitle" :icon="icon" size="xl" @close="emit('close')">
    <div class="flex flex-wrap items-center gap-2 mb-3">
      <Btn sm :disabled="!content" @click="copyText(content, 'Output')"><LIcon name="copy" /> Copy</Btn>
      <Btn v-if="downloadName" sm :disabled="!content" @click="download">
        <LIcon name="download" /> Download
      </Btn>
      <label
        :for="wrapId"
        class="ml-auto inline-flex items-center gap-2 h-8 px-2.5 rounded-lg border border-c-border bg-c-bg text-xs-var text-c-tx2 cursor-pointer select-none hover:text-c-tx"
      >
        <input :id="wrapId" v-model="wordWrap" type="checkbox" class="w-4 h-4 accent-c-accent" />
        Word wrap
      </label>
    </div>
    <!-- Focusable so the keyboard can scroll it. -->
    <!-- eslint-disable vue/no-v-html -- ansiToHtml escapes the content first -->
    <div v-if="ansi" :class="textClass" tabindex="0" role="region" :aria-label="title" v-html="html"></div>
    <!-- eslint-enable vue/no-v-html -->
    <div v-else :class="textClass" tabindex="0" role="region" :aria-label="title">{{ content }}</div>
    <template #footer>
      <Btn data-autofocus @click="emit('close')">Close</Btn>
    </template>
  </BaseDialog>
</template>
