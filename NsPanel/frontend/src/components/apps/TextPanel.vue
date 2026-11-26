<script setup lang="ts">
/** Read-only monospace text (logs, configs, unit files) with Refresh, Copy,
 *  Download and a word-wrap switch. Renders its own loading and error states. */
import { ref } from 'vue';

import Btn from '@/components/ui/Btn.vue';
import ErrorState from '@/components/ui/ErrorState.vue';
import LIcon from '@/components/ui/LIcon.vue';
import { useUiStore } from '@/stores/ui';
import { copyText } from '@/utils/clipboard';

const props = withDefaults(
  defineProps<{
    /** Accessible name of the text region, e.g. "nginx error log". */
    label: string;
    text: string;
    loading?: boolean;
    error?: string | null;
    /** Offer a download under this file name. */
    downloadName?: string;
    /** Show the Refresh button. */
    refreshable?: boolean;
    wrap?: boolean;
  }>(),
  { loading: false, error: null, downloadName: '', refreshable: true, wrap: true },
);
const emit = defineEmits<{ refresh: [] }>();

const ui = useUiStore();
const wordWrap = ref(props.wrap);

function download(): void {
  const url = URL.createObjectURL(new Blob([props.text], { type: 'text/plain;charset=utf-8' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = props.downloadName;
  link.click();
  URL.revokeObjectURL(url);
  ui.addToast({ t: 'Downloaded', d: props.downloadName, k: 'ok' });
}
</script>

<template>
  <div class="flex flex-col gap-2 min-w-0">
    <div class="flex flex-wrap items-center gap-1.5">
      <slot name="toolbar" />
      <div class="ml-auto flex flex-wrap items-center gap-1.5">
        <label
          class="inline-flex items-center gap-1.5 h-8 px-2 text-xs-var text-c-tx2 cursor-pointer select-none"
        >
          <input v-model="wordWrap" type="checkbox" class="w-4 h-4 accent-c-accent" />
          Wrap
        </label>
        <Btn v-if="refreshable" sm :loading="loading" @click="emit('refresh')">
          <LIcon name="refresh-cw" /> Refresh
        </Btn>
        <Btn sm :disabled="!text" @click="copyText(text, label)"><LIcon name="copy" /> Copy</Btn>
        <Btn v-if="downloadName" sm :disabled="!text" @click="download"
          ><LIcon name="download" /> Download</Btn
        >
      </div>
    </div>

    <div v-if="error && !text" class="border border-c-border rounded-theme">
      <ErrorState :message="error" :retrying="loading" @retry="emit('refresh')" />
    </div>
    <div
      v-else-if="loading && !text"
      class="border border-c-border rounded-theme p-4 flex flex-col gap-2"
      aria-busy="true"
      aria-label="Loading"
    >
      <span v-for="n in 6" :key="n" class="skeleton block h-3" :style="{ width: `${90 - n * 9}%` }"></span>
    </div>
    <pre
      v-else
      tabindex="0"
      role="region"
      :aria-label="label"
      :aria-busy="loading || undefined"
      class="term m-0 rounded-theme min-h-[200px] max-h-[60vh] overflow-auto"
      :style="{ whiteSpace: wordWrap ? 'pre-wrap' : 'pre', wordBreak: wordWrap ? 'break-all' : 'normal' }"
      >{{ text || '(empty)' }}</pre>
  </div>
</template>
