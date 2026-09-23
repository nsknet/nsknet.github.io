<script setup lang="ts">
/** Live output for a running job, streamed from /stream/{job_id}. */
import { nextTick, onMounted, onUnmounted, ref } from 'vue';

import { ansiToHtml } from '@/composables/useAnsi';
import { useUiStore, type Overlay } from '@/stores/ui';

import Btn from './ui/Btn.vue';
import LIcon from './ui/LIcon.vue';

const props = defineProps<{ overlay: Overlay }>();
const emit = defineEmits<{ close: [] }>();

const ui = useUiStore();

const termEl = ref<HTMLElement | null>(null);
const lines = ref<{ html: string }[]>([]);
const statusPhase = ref<'running' | 'done' | 'failed'>('running');
const elapsed = ref('0.0s');
const exitCode = ref(0);
const wordWrap = ref(true);
const jobId = props.overlay.jobId ?? `job ${Math.random().toString(36).slice(2, 10)}`;

let elapsedTimer: ReturnType<typeof setInterval> | undefined;
let source: EventSource | undefined;

function dismiss(): void {
  clearInterval(elapsedTimer);
  source?.close();
  emit('close');
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key === 'Escape') dismiss();
}

function scrollToEnd(): void {
  void nextTick(() => {
    if (termEl.value) termEl.value.scrollTop = termEl.value.scrollHeight;
  });
}

function copyLogs(): void {
  const text = lines.value.map((line) => line.html.replace(/<[^>]*>/g, '')).join('\n');
  navigator.clipboard
    .writeText(text)
    .then(() => ui.addToast({ t: 'Logs copied to clipboard', k: 'ok' }))
    .catch((error: Error) =>
      ui.addToast({ t: 'Failed to copy logs', d: error.message, k: 'danger' }),
    );
}

onMounted(() => {
  document.addEventListener('keydown', onKeydown);

  const start = performance.now();
  elapsedTimer = setInterval(() => {
    elapsed.value = `${((performance.now() - start) / 1000).toFixed(1)}s`;
  }, 100);

  if (!props.overlay.jobId) return;

  source = new EventSource(`/stream/${props.overlay.jobId}`);

  source.addEventListener('line', (event) => {
    lines.value.push({ html: ansiToHtml((event as MessageEvent<string>).data) });
    scrollToEnd();
  });

  source.addEventListener('error', () => {
    lines.value.push({ html: '\n[SSE connection error / interrupted]' });
    scrollToEnd();
    statusPhase.value = 'failed';
    exitCode.value = 1;
    clearInterval(elapsedTimer);
    source?.close();
  });

  source.addEventListener('done', (event) => {
    const code = Number.parseInt((event as MessageEvent<string>).data, 10);
    exitCode.value = Number.isNaN(code) ? 0 : code;
    statusPhase.value = exitCode.value === 0 ? 'done' : 'failed';
    clearInterval(elapsedTimer);
    source?.close();
    if (props.overlay.onDone) void nextTick(() => props.overlay.onDone?.());
  });
});

onUnmounted(() => {
  document.removeEventListener('keydown', onKeydown);
  clearInterval(elapsedTimer);
  source?.close();
});
</script>

<template>
  <div
    class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade"
    @click.self="dismiss"
  >
    <div
      class="flex flex-col w-full max-w-4xl max-h-[80vh] bg-c-card border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop"
      role="dialog"
      aria-modal="true"
    >
      <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
        <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center">
          <LIcon name="terminal" is="width:14px;height:14px" />
        </div>
        <div>
          <div class="font-semibold text-sm-var">{{ overlay.title }}</div>
          <div class="text-xs-var text-c-tx2 mono">{{ jobId }}</div>
        </div>
        <div class="ml-auto flex items-center gap-2 mr-2">
          <Btn variant="ghost" sm class="text-xs-var h-7 px-2" @click="copyLogs">
            <LIcon name="copy" is="width:13px;height:13px;margin-right:4px" /> Copy
          </Btn>
          <label
            class="flex items-center gap-1.5 text-xs-var cursor-pointer select-none px-2 h-7 bg-c-subtle hover:bg-c-hover rounded-theme border border-c-border text-c-tx2 hover:text-c-tx"
          >
            <input v-model="wordWrap" type="checkbox" class="w-3 h-3 accent-c-accent rounded" />
            <span>Word wrap</span>
          </label>
        </div>
        <Btn variant="ghost" sm square aria-label="Close" @click="dismiss">
          <LIcon name="x" />
        </Btn>
      </div>

      <div
        ref="termEl"
        :class="['term', wordWrap ? 'whitespace-pre-wrap' : 'whitespace-pre overflow-x-auto']"
        style="word-break: break-all"
      >
        <span v-for="(line, index) in lines" :key="index" class="ln" v-html="line.html"></span>
      </div>

      <div
        class="flex items-center gap-2.5 py-2.5 px-4 border-t border-c-border bg-c-elev text-xs-var text-c-tx2"
      >
        <template v-if="statusPhase === 'running'">
          <span
            class="w-3 h-3 rounded-full border-[1.5px] border-c-bstrong border-t-c-accent animate-spin"
          ></span>
          <span>running…</span>
        </template>
        <template v-else-if="statusPhase === 'done'">
          <LIcon name="circle-check-big" is="width:14px;height:14px;color:var(--ok)" />
          <span class="text-c-ok font-medium">Success</span>
          <span class="text-c-tx2">· exit 0</span>
        </template>
        <template v-else>
          <LIcon name="circle-x" is="width:14px;height:14px;color:var(--danger)" />
          <span class="text-c-danger font-medium">Failed</span>
          <span class="text-c-tx2">· exit {{ exitCode }}</span>
        </template>
        <span class="ml-auto mono">{{ elapsed }}</span>
      </div>
    </div>
  </div>
</template>
