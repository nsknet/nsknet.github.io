<script setup lang="ts">
/** Signal one process: TERM (ask it to exit) or KILL (stop it at once). */
import { ref } from 'vue';

import type { KillSignal, Process } from '@/api/system';
import BaseDialog from '@/components/ui/BaseDialog.vue';
import Btn from '@/components/ui/Btn.vue';
import LIcon from '@/components/ui/LIcon.vue';
import { useJobRunner } from '@/composables/useJobs';

const props = defineProps<{ process: Process }>();
const emit = defineEmits<{ close: []; done: [] }>();

const { run } = useJobRunner();
const signal = ref<KillSignal>('TERM');
const pending = ref(false);

const SIGNALS: { value: KillSignal; title: string; hint: string }[] = [
  {
    value: 'TERM',
    title: 'Terminate (SIGTERM)',
    hint: 'Asks the process to exit. It can save its work and clean up. A systemd service may restart.',
  },
  {
    value: 'KILL',
    title: 'Kill (SIGKILL)',
    hint: 'Stops it immediately. Unsaved data is lost. Use when TERM does not work.',
  },
];

async function submit(): Promise<void> {
  pending.value = true;
  const result = await run('/api/v1/processes/kill', { pid: props.process.pid, sig: signal.value });
  pending.value = false;
  if (result) {
    emit('done');
    emit('close');
  }
}
</script>

<template>
  <BaseDialog
    :title="`Stop ${process.name} (PID ${process.pid})?`"
    :description="`Runs as ${process.user} · ${process.cpu_percent.toFixed(1)}% CPU · ${process.ram_gb.toFixed(2)} GB RAM`"
    icon="octagon-x"
    tone="danger"
    size="sm"
    :closable="!pending"
    @close="emit('close')"
  >
    <form id="kill-process" class="flex flex-col gap-3" novalidate @submit.prevent="submit">
      <p
        class="m-0 mono text-xs-var text-c-tx2 break-all max-h-24 overflow-y-auto bg-c-elev border border-c-border rounded-theme p-2"
      >
        {{ process.arguments }}
      </p>
      <fieldset class="m-0 p-0 border-0 min-w-0">
        <legend class="text-sm-var font-medium text-c-tx mb-1.5 p-0">Signal</legend>
        <div class="flex flex-col gap-2">
          <label
            v-for="option in SIGNALS"
            :key="option.value"
            :class="[
              'flex items-start gap-2.5 px-3 py-2.5 rounded-theme border cursor-pointer',
              signal === option.value
                ? 'border-c-danger bg-c-dngsoft'
                : 'border-c-border bg-c-elev hover:bg-c-hover',
            ]"
          >
            <input
              v-model="signal"
              type="radio"
              name="kill-signal"
              :value="option.value"
              class="mt-0.5 w-4 h-4 accent-c-danger shrink-0"
              :data-autofocus="option.value === 'TERM' ? '' : undefined"
            />
            <span class="flex flex-col gap-0.5 min-w-0">
              <span class="text-sm-var font-medium text-c-tx">{{ option.title }}</span>
              <span class="text-xs-var text-c-tx2">{{ option.hint }}</span>
            </span>
          </label>
        </div>
      </fieldset>
    </form>
    <template #footer>
      <Btn :disabled="pending" @click="emit('close')">Cancel</Btn>
      <Btn type="submit" form="kill-process" variant="danger-solid" :loading="pending">
        <LIcon name="octagon-x" /> {{ signal === 'TERM' ? 'Terminate' : 'Kill' }}
      </Btn>
    </template>
  </BaseDialog>
</template>
