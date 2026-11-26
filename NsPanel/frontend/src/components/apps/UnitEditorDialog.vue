<script setup lang="ts">
/** Edit a service's unit file: edit → review the line diff → save & restart.
 *
 * The server runs `systemd-analyze verify` before saving. When it objects
 * (HTTP 400, nothing saved) its output is shown here and "Save anyway" sends
 * force=true behind a danger confirmation.
 *
 * Note: this POSTs itself instead of going through useJobRunner().run, because
 * the runner turns every failure into a toast and the verify output has to be
 * shown inline. On success it opens the same job overlay the runner would.
 */
import { computed, ref } from 'vue';

import { ApiError, isJobResponse, postAction } from '@/api/client';
import Alert from '@/components/ui/Alert.vue';
import BaseDialog from '@/components/ui/BaseDialog.vue';
import Btn from '@/components/ui/Btn.vue';
import LIcon from '@/components/ui/LIcon.vue';
import { useReload } from '@/composables/useScreenData';
import { useJobsStore } from '@/stores/jobs';
import { useUiStore } from '@/stores/ui';
import { apiPath } from '@/utils/format';

import { diffStats, lineDiff, withContext } from './lineDiff';

const props = defineProps<{ name: string; content: string; path: string }>();
const emit = defineEmits<{ close: [] }>();

const ui = useUiStore();
const jobs = useJobsStore();
const reload = useReload();

const dialog = ref<InstanceType<typeof BaseDialog> | null>(null);
const step = ref<'edit' | 'review'>('edit');
const draft = ref(props.content);
const saving = ref(false);
const verifyOutput = ref('');

const dirty = computed(() => draft.value !== props.content);
const hasRedactedToken = computed(() => props.content.includes('***'));

const diff = computed(() => (step.value === 'review' ? lineDiff(props.content, draft.value) : []));
const stats = computed(() => diffStats(diff.value));
const folded = computed(() => withContext(diff.value, 3));

function review(): void {
  verifyOutput.value = '';
  step.value = 'review';
}

const VERIFY_PREFIX = 'systemd rejected the unit (nothing was saved):';

async function save(force = false): Promise<void> {
  saving.value = true;
  try {
    const result = await postAction(apiPath`/api/v1/services/${props.name}/edit`, {
      content: draft.value,
      force: force || undefined,
    });
    emit('close');
    if (isJobResponse(result)) {
      const title = `Saving & restarting ${props.name}`;
      ui.openOverlay({
        jobId: result.job_id,
        title,
        onDone: (ok) => {
          void reload();
          void jobs.load();
          if (!ok) ui.addToast({ t: 'Job failed', d: title, k: 'danger' });
        },
      });
      void jobs.load();
    } else {
      void reload();
    }
  } catch (error) {
    if (error instanceof ApiError && error.status === 400 && error.message.startsWith(VERIFY_PREFIX)) {
      verifyOutput.value = error.message.slice(VERIFY_PREFIX.length).trim() || error.message;
    } else {
      ui.addToast({
        t: error instanceof ApiError ? 'Could not save the unit' : 'Network error',
        d: error instanceof Error ? error.message : String(error),
        k: 'danger',
      });
    }
  } finally {
    saving.value = false;
  }
}

function saveAnyway(): void {
  ui.confirmThen(
    'Save without verification?',
    'systemd-analyze reported the problems shown. The unit is saved as written and the service restarted; it may fail to start.',
    () => void save(true),
    { danger: true, confirmLabel: 'Save anyway' },
  );
}
</script>

<template>
  <BaseDialog
    ref="dialog"
    :title="step === 'edit' ? `Edit ${name}.service` : 'Review changes'"
    :description="path"
    size="xl"
    icon="square-pen"
    :dirty="dirty"
    :closable="!saving"
    @close="emit('close')"
  >
    <div v-if="step === 'edit'" class="flex flex-col gap-3">
      <Alert v-if="hasRedactedToken" tone="info">
        Tunnel tokens are shown as <span class="mono">***</span>. Leave them as they are: the server puts the
        real token back when you save.
      </Alert>
      <label for="unit-editor" class="sr-only">Unit file content</label>
      <textarea
        id="unit-editor"
        v-model="draft"
        class="input mono leading-relaxed"
        :style="{ minHeight: '50vh' }"
        spellcheck="false"
        autocapitalize="off"
        autocomplete="off"
        wrap="off"
        data-autofocus
      ></textarea>
    </div>

    <div v-else class="flex flex-col gap-3">
      <Alert v-if="verifyOutput" tone="danger" title="systemd-analyze rejected the unit — nothing was saved">
        <pre class="m-0 mt-1 mono text-xs-var whitespace-pre-wrap break-words">{{ verifyOutput }}</pre>
      </Alert>

      <div class="flex items-center gap-3 text-sm-var">
        <span class="text-c-ok tabular-nums font-medium">+{{ stats.added }}</span>
        <span class="text-c-danger tabular-nums font-medium">−{{ stats.removed }}</span>
        <span class="text-c-tx2">lines changed</span>
      </div>

      <div
        class="border border-c-border rounded-theme overflow-auto max-h-[55vh] bg-c-bg"
        tabindex="0"
        role="region"
        aria-label="Changes to the unit file"
      >
        <table class="w-full border-collapse mono text-xs-var">
          <tbody>
            <template v-for="(line, index) in folded" :key="index">
              <tr v-if="line.op === 'gap'">
                <td colspan="4" class="px-3 py-1 bg-c-subtle text-c-tx3 text-center">
                  ··· {{ line.count }} unchanged line{{ line.count === 1 ? '' : 's' }} ···
                </td>
              </tr>
              <tr v-else :class="line.op === 'add' ? 'bg-c-oksoft' : line.op === 'del' ? 'bg-c-dngsoft' : ''">
                <td class="w-10 px-2 text-right text-c-tx3 tabular-nums select-none align-top">
                  {{ line.oldNo ?? '' }}
                </td>
                <td class="w-10 px-2 text-right text-c-tx3 tabular-nums select-none align-top">
                  {{ line.newNo ?? '' }}
                </td>
                <td
                  :class="[
                    'w-5 text-center select-none align-top',
                    line.op === 'add' ? 'text-c-ok' : line.op === 'del' ? 'text-c-danger' : 'text-c-tx3',
                  ]"
                >
                  <span aria-hidden="true">{{ line.op === 'add' ? '+' : line.op === 'del' ? '−' : '' }}</span>
                  <span class="sr-only">{{
                    line.op === 'add' ? 'added' : line.op === 'del' ? 'removed' : ''
                  }}</span>
                </td>
                <td class="pr-3 whitespace-pre text-c-tx">{{ line.text || ' ' }}</td>
              </tr>
            </template>
          </tbody>
        </table>
      </div>
      <p class="m-0 text-xs-var text-c-tx2">
        Saving runs <span class="mono">systemd-analyze verify</span>, keeps the old file as
        <span class="mono">{{ name }}.service.bak</span>, then reloads systemd and restarts the service.
      </p>
    </div>

    <template #footer>
      <template v-if="step === 'edit'">
        <Btn @click="dialog?.requestClose()">Cancel</Btn>
        <Btn variant="primary" :disabled="!dirty" @click="review"
          ><LIcon name="file-diff" /> Review changes</Btn
        >
      </template>
      <template v-else>
        <Btn :disabled="saving" @click="step = 'edit'"><LIcon name="arrow-left" /> Back to editing</Btn>
        <Btn v-if="verifyOutput" variant="danger" :disabled="saving" @click="saveAnyway">Save anyway</Btn>
        <Btn variant="primary" :loading="saving" @click="save()"
          ><LIcon name="check" /> Save &amp; restart</Btn
        >
      </template>
    </template>
  </BaseDialog>
</template>
