<script setup lang="ts">
/** Live output for a job, streamed from /stream/{job_id}.
 *
 * - A dropped connection is not a failed job: it reconnects (the stream
 *   replays from the first line) and says "reconnecting" meanwhile.
 * - Follow mode keeps the newest line in view; scrolling up turns it off.
 * - The DOM keeps at most MAX_LINES lines (the server caps its buffer too).
 */
import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue';

import { postAction } from '@/api/client';
import { ansiToHtml } from '@/composables/useAnsi';
import { useUiStore, type Overlay } from '@/stores/ui';
import { copyText } from '@/utils/clipboard';
import { apiPath, duration } from '@/utils/format';

import BaseDialog from './ui/BaseDialog.vue';
import Btn from './ui/Btn.vue';
import LIcon from './ui/LIcon.vue';

const props = defineProps<{ overlay: Overlay }>();
const emit = defineEmits<{ close: [] }>();

const ui = useUiStore();

const MAX_LINES = 5000;
const RECONNECT_MS = 2000;

const termEl = ref<HTMLElement | null>(null);
const lines = ref<{ id: number; html: string; text: string }[]>([]);
const dropped = ref(0);
const phase = ref<'running' | 'done' | 'failed' | 'reconnecting' | 'lost'>('running');
const seconds = ref(0);
const exitCode = ref(0);
const wordWrap = ref(true);
const follow = ref(true);
const cancelling = ref(false);
const jobId = props.overlay.jobId;

let lineId = 0;
let startedAt = performance.now();
let elapsedTimer: ReturnType<typeof setInterval> | undefined;
let reconnectTimer: ReturnType<typeof setTimeout> | undefined;
let source: EventSource | undefined;
let attempts = 0;

const finished = computed(() => phase.value === 'done' || phase.value === 'failed');

function stopTimers(): void {
  clearInterval(elapsedTimer);
  clearTimeout(reconnectTimer);
  source?.close();
}

function close(): void {
  stopTimers();
  if (!finished.value && jobId) {
    ui.addToast({
      t: 'Still running in the background',
      d: 'Reopen its output from Activity → Jobs.',
      k: 'info',
    });
  }
  emit('close');
}

function scrollToEnd(): void {
  if (!follow.value) return;
  void nextTick(() => {
    if (termEl.value) termEl.value.scrollTop = termEl.value.scrollHeight;
  });
}

function onScroll(): void {
  const el = termEl.value;
  if (!el) return;
  // Following while the bottom is in view; reading back pauses it.
  follow.value = el.scrollHeight - el.scrollTop - el.clientHeight < 24;
}

/** `text` is the raw line (for Copy); `html` is its escaped, coloured rendering. */
function push(text: string, html = ansiToHtml(text)): void {
  lines.value.push({ id: lineId++, html, text });
  if (lines.value.length > MAX_LINES) {
    const extra = lines.value.length - MAX_LINES;
    lines.value.splice(0, extra);
    dropped.value += extra;
  }
  scrollToEnd();
}

function copyLogs(): void {
  const text = lines.value.map((line) => line.text.replace(/\x1b\[[0-9;]*m/g, '')).join('\n');
  void copyText(text, 'Output');
}

function cancelJob(): void {
  if (!jobId || cancelling.value) return;
  ui.confirmThen(
    'Stop this job?',
    'The command gets SIGTERM, then SIGKILL after 10 seconds. A half-finished install can leave packages partly configured.',
    () => {
      cancelling.value = true;
      postAction(apiPath`/api/v1/jobs/${jobId}/cancel`).catch((error: Error) => {
        cancelling.value = false;
        ui.addToast({ t: 'Could not stop the job', d: error.message, k: 'danger' });
      });
    },
    { danger: true, confirmLabel: 'Stop job' },
  );
}

function connect(): void {
  if (!jobId) return;
  source?.close();
  // Each connection replays the job from its first line.
  lines.value = [];
  dropped.value = 0;
  source = new EventSource(apiPath`/stream/${jobId}`);

  source.addEventListener('meta', (event) => {
    attempts = 0;
    if (phase.value === 'reconnecting') phase.value = 'running';
    try {
      const meta = JSON.parse((event as MessageEvent<string>).data) as { elapsed?: number };
      if (typeof meta.elapsed === 'number') startedAt = performance.now() - meta.elapsed * 1000;
    } catch {
      /* older panel without meta — keep counting from open */
    }
  });

  source.addEventListener('line', (event) => push((event as MessageEvent<string>).data));

  source.addEventListener('error', (event) => {
    source?.close();
    // A server-sent `error` event carries data: the job is unknown (evicted,
    // or the panel restarted). A bare Event is a dropped connection.
    if (typeof (event as MessageEvent<unknown>).data === 'string') {
      const note = '[This job is no longer known to the panel — it restarted or the job was evicted]';
      push(note, `<span class="dim">${note}</span>`);
      phase.value = 'lost';
      clearInterval(elapsedTimer);
      return;
    }
    if (finished.value) return;
    phase.value = 'reconnecting';
    attempts += 1;
    reconnectTimer = setTimeout(connect, Math.min(RECONNECT_MS * attempts, 15_000));
  });

  source.addEventListener('done', (event) => {
    const code = Number.parseInt((event as MessageEvent<string>).data, 10);
    exitCode.value = Number.isNaN(code) ? 0 : code;
    phase.value = exitCode.value === 0 ? 'done' : 'failed';
    seconds.value = (performance.now() - startedAt) / 1000;
    stopTimers();
    const finalCode = exitCode.value;
    if (props.overlay.onDone) void nextTick(() => props.overlay.onDone?.(finalCode === 0, finalCode));
  });
}

onMounted(() => {
  elapsedTimer = setInterval(() => {
    seconds.value = (performance.now() - startedAt) / 1000;
  }, 200);
  connect();
});

onUnmounted(stopTimers);
</script>

<template>
  <BaseDialog :title="overlay.title" size="xl" icon="terminal" @close="close">
    <div class="flex flex-wrap items-center gap-2 mb-2 text-xs-var">
      <span v-if="jobId" class="mono text-c-tx3">job {{ jobId.slice(0, 12) }}</span>
      <div class="ml-auto flex items-center gap-1.5">
        <label
          class="inline-flex items-center gap-1.5 h-8 px-2 rounded-theme border border-c-border text-c-tx2 cursor-pointer select-none"
        >
          <input v-model="follow" type="checkbox" class="w-3.5 h-3.5 accent-c-accent" @change="scrollToEnd" />
          Follow
        </label>
        <label
          class="inline-flex items-center gap-1.5 h-8 px-2 rounded-theme border border-c-border text-c-tx2 cursor-pointer select-none"
        >
          <input v-model="wordWrap" type="checkbox" class="w-3.5 h-3.5 accent-c-accent" />
          Wrap
        </label>
        <Btn sm @click="copyLogs"><LIcon name="copy" /> Copy</Btn>
      </div>
    </div>

    <div
      ref="termEl"
      :class="[
        'term rounded-theme min-h-[280px] max-h-[56vh]',
        wordWrap ? 'whitespace-pre-wrap break-all' : 'whitespace-pre overflow-x-auto',
      ]"
      role="log"
      aria-live="polite"
      :aria-label="`Output of ${overlay.title}`"
      tabindex="0"
      @scroll="onScroll"
    >
      <span v-if="dropped" class="ln dim">… {{ dropped }} earlier line(s) not shown …</span>
      <!-- eslint-disable-next-line vue/no-v-html -- ansiToHtml escapes the line first -->
      <span v-for="line in lines" :key="line.id" class="ln" v-html="line.html"></span>
    </div>

    <template #footer>
      <div class="flex items-center gap-2 mr-auto text-sm-var" role="status">
        <template v-if="phase === 'running'">
          <span
            class="w-3.5 h-3.5 rounded-full border-2 border-c-bstrong border-t-c-accent animate-spin"
          ></span>
          <span class="text-c-tx2">{{ cancelling ? 'Stopping…' : 'Running…' }}</span>
        </template>
        <template v-else-if="phase === 'reconnecting'">
          <LIcon is="width:15px;height:15px;color:var(--warn)" name="cloud-off" />
          <span class="text-c-warn">Connection lost — reconnecting…</span>
        </template>
        <template v-else-if="phase === 'lost'">
          <LIcon is="width:15px;height:15px;color:var(--text-3)" name="circle-x" />
          <span class="text-c-tx2">Result unknown</span>
        </template>
        <template v-else-if="phase === 'done'">
          <LIcon is="width:15px;height:15px;color:var(--ok)" name="circle-check-big" />
          <span class="text-c-ok font-medium">Succeeded</span>
        </template>
        <template v-else>
          <LIcon is="width:15px;height:15px;color:var(--danger)" name="circle-x" />
          <span class="text-c-danger font-medium">Failed · exit {{ exitCode }}</span>
        </template>
        <span class="mono text-c-tx3 tabular-nums">{{ duration(seconds) }}</span>
      </div>
      <Btn
        v-if="!finished && phase !== 'lost' && jobId"
        variant="danger"
        :loading="cancelling"
        @click="cancelJob"
      >
        <LIcon name="square" /> Stop
      </Btn>
      <Btn :variant="finished ? 'primary' : 'default'" @click="close">
        {{ finished ? 'Close' : 'Hide' }}
      </Btn>
    </template>
  </BaseDialog>
</template>
