<script setup lang="ts">
/** Read-only terminal viewer: nginx configs, systemctl status, journal logs. */
import { computed, ref } from 'vue';

import { ansiToHtml } from '@/composables/useAnsi';
import { useUiStore } from '@/stores/ui';

import Btn from './ui/Btn.vue';
import LIcon from './ui/LIcon.vue';

const props = withDefaults(
  defineProps<{
    title: string;
    subtitle?: string;
    content: string;
    icon?: string;
    /** Offer a .log download. */
    downloadName?: string;
    /** Render ANSI colour codes (journal output) instead of plain text. */
    ansi?: boolean;
    wrap?: boolean;
  }>(),
  { subtitle: '', icon: 'terminal', downloadName: '', ansi: false, wrap: true },
);

const emit = defineEmits<{ close: [] }>();

const ui = useUiStore();
const wordWrap = ref(props.wrap);
const html = computed(() => (props.ansi ? ansiToHtml(props.content) : ''));
const wrapClass = computed(() => (wordWrap.value ? 'whitespace-pre-wrap' : 'whitespace-pre'));

async function copy(): Promise<void> {
  try {
    await navigator.clipboard.writeText(props.content);
    ui.addToast({ t: 'Copied to clipboard', k: 'info' });
  } catch (error) {
    ui.addToast({
      t: 'Failed to copy',
      d: error instanceof Error ? error.message : String(error),
      k: 'danger',
    });
  }
}

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
  <div
    class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px]"
    @click.self="emit('close')"
  >
    <div
      class="flex flex-col w-full max-w-4xl max-h-[80vh] bg-c-card border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop"
      role="dialog"
      aria-modal="true"
    >
      <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
        <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center">
          <LIcon :name="icon" is="width:14px;height:14px" />
        </div>
        <div class="min-w-0">
          <div class="font-semibold text-sm-var">{{ title }}</div>
          <div v-if="subtitle" class="text-xs-var text-c-tx2 mono truncate">{{ subtitle }}</div>
        </div>
        <div class="ml-auto flex items-center gap-2 mr-2">
          <Btn variant="ghost" sm class="text-xs-var h-7 px-2" @click="copy">
            <LIcon name="copy" is="width:13px;height:13px;margin-right:4px" /> Copy
          </Btn>
          <Btn
            v-if="downloadName"
            variant="ghost"
            sm
            class="text-xs-var h-7 px-2"
            @click="download"
          >
            <LIcon name="download" is="width:13px;height:13px;margin-right:4px" /> Download
          </Btn>
          <label
            class="flex items-center gap-1.5 text-xs-var cursor-pointer select-none px-2 h-7 bg-c-subtle hover:bg-c-hover rounded-theme border border-c-border text-c-tx2 hover:text-c-tx"
          >
            <input v-model="wordWrap" type="checkbox" class="w-3 h-3 accent-c-accent rounded" />
            <span>Word wrap</span>
          </label>
        </div>
        <Btn variant="ghost" sm square aria-label="Close" @click="emit('close')">
          <LIcon name="x" />
        </Btn>
      </div>

      <div
        v-if="ansi"
        :class="['term overflow-auto mono text-xs-var p-4 leading-relaxed select-text', wrapClass]"
        style="height: 480px; word-break: break-all"
        v-html="html"
      ></div>
      <div
        v-else
        :class="['term overflow-auto mono text-xs-var p-4 leading-relaxed select-text', wrapClass]"
        style="height: 480px; word-break: break-all"
      >{{ content }}</div>
    </div>
  </div>
</template>
