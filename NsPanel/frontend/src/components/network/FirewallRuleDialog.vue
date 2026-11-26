<script setup lang="ts">
/** Add one UFW rule: port, action, source and comment.
 *
 * Stays open until the job starts; a blocking rule (DENY/REJECT/LIMIT) on an
 * SSH or panel port needs the typed confirmation first.
 */
import { computed, reactive, ref } from 'vue';

import type { FirewallState } from '@/api/system';
import BaseDialog from '@/components/ui/BaseDialog.vue';
import Btn from '@/components/ui/Btn.vue';
import Field from '@/components/ui/Field.vue';
import LIcon from '@/components/ui/LIcon.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useUiStore } from '@/stores/ui';
import { cidr, IPV4 } from '@/utils/validate';

import { ACTIONS, blockingHit, portOfSpec, portSpecError, type RuleAction } from './firewall';

const props = defineProps<{ state: FirewallState }>();
const emit = defineEmits<{ close: [] }>();

const ui = useUiStore();
const { run } = useJobRunner();

const ACTION_HELP: Record<RuleAction, string> = {
  ALLOW: 'Let matching traffic in.',
  DENY: 'Drop matching traffic silently.',
  REJECT: 'Refuse matching traffic and tell the sender.',
  LIMIT: 'Allow, but block an address that opens 6+ connections in 30 seconds.',
};

const clientIsV4 = computed(() => IPV4.test(props.state.client_ip.replace(/^::ffff:/i, '')));

const SOURCES = computed(() => [
  { value: 'any', label: 'Anywhere (every address)' },
  { value: '10.0.0.0/8', label: 'Private 10.0.0.0/8' },
  { value: '172.16.0.0/12', label: 'Private 172.16.0.0/12' },
  { value: '192.168.0.0/16', label: 'Private 192.168.0.0/16' },
  ...(clientIsV4.value ? [{ value: 'client', label: `This computer (${clientAddress.value})` }] : []),
  { value: 'custom', label: 'Custom address or range…' },
]);

const clientAddress = computed(() => props.state.client_ip.replace(/^::ffff:/i, ''));

const form = reactive({
  port: '',
  action: 'ALLOW' as RuleAction,
  source: 'any',
  custom: '',
  comment: '',
});
const submitted = ref(false);
const pending = ref(false);

const portError = computed(() => portSpecError(form.port));
const customError = computed(() => {
  if (form.source !== 'custom') return '';
  const value = form.custom.trim();
  if (!value) return 'Enter an IPv4 address or a range such as 203.0.113.0/24.';
  return IPV4.test(value) ? '' : cidr(value);
});
const commentError = computed(() =>
  form.comment.trim().length > 64 ? 'Keep the comment under 64 characters.' : '',
);

const show = reactive({ port: false, custom: false, comment: false });
const visible = (key: keyof typeof show, message: string) => (submitted.value || show[key] ? message : '');

const sourceValue = computed(() => {
  if (form.source === 'any') return 'Anywhere';
  if (form.source === 'client') return clientAddress.value;
  if (form.source === 'custom') return form.custom.trim();
  return form.source;
});

const dirty = computed(() => !!(form.port || form.custom || form.comment));
const hit = computed(() => blockingHit(portOfSpec(form.port), form.action, props.state));

async function send(): Promise<void> {
  pending.value = true;
  const port = form.port.trim().toLowerCase();
  const result = await run(
    '/api/v1/firewall/add-port',
    { port, action: form.action.toLowerCase(), source: sourceValue.value, comment: form.comment.trim() },
    { title: `Adding rule: ${form.action} ${port} from ${sourceValue.value}` },
  );
  pending.value = false;
  if (result) emit('close');
}

function submit(): void {
  submitted.value = true;
  if (portError.value || customError.value || commentError.value) return;
  const blocking = hit.value;
  if (!blocking) {
    void send();
    return;
  }
  ui.confirmThen(
    `${form.action} traffic to the ${blocking.what} port?`,
    `This rule ${form.action === 'LIMIT' ? 'rate-limits' : 'blocks'} port ${blocking.port}, which ${blocking.what} uses.`,
    () => void send(),
    {
      danger: true,
      confirmLabel: `Add ${form.action} rule`,
      typeToConfirm: String(blocking.port),
      details: [
        `You may lose access to ${blocking.what}.`,
        `Source: ${sourceValue.value}. Your address: ${props.state.client_ip || 'unknown'}.`,
        'UFW applies rules top to bottom: an earlier ALLOW still wins.',
      ],
    },
  );
}
</script>

<template>
  <BaseDialog
    title="Add firewall rule"
    description="Applies to IPv4 and IPv6. UFW must be enabled for rules to take effect."
    icon="shield-plus"
    tone="accent"
    :dirty="dirty"
    :closable="!pending"
    @close="emit('close')"
  >
    <form id="fw-add-rule" class="flex flex-col gap-4" novalidate @submit.prevent="submit">
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Field
          v-slot="f"
          label="Port"
          required
          :error="visible('port', portError)"
          help="One port, optionally with tcp or udp."
        >
          <input
            :id="f.id"
            v-model="form.port"
            class="input mono"
            inputmode="numeric"
            autocomplete="off"
            spellcheck="false"
            placeholder="443/tcp"
            data-autofocus
            :aria-describedby="f.describedBy"
            :aria-invalid="f.invalid"
            @blur="show.port = true"
          />
        </Field>
        <Field v-slot="f" label="Action" :help="ACTION_HELP[form.action]">
          <select :id="f.id" v-model="form.action" class="input" :aria-describedby="f.describedBy">
            <option v-for="action in ACTIONS" :key="action" :value="action">{{ action }}</option>
          </select>
        </Field>
      </div>

      <Field v-slot="f" label="Source" help="Which addresses the rule applies to.">
        <select :id="f.id" v-model="form.source" class="input" :aria-describedby="f.describedBy">
          <option v-for="source in SOURCES" :key="source.value" :value="source.value">
            {{ source.label }}
          </option>
        </select>
      </Field>

      <Field
        v-if="form.source === 'custom'"
        v-slot="f"
        label="Address or range"
        required
        :error="visible('custom', customError)"
        help="An IPv4 address or CIDR range, e.g. 203.0.113.0/24."
      >
        <input
          :id="f.id"
          v-model="form.custom"
          class="input mono"
          autocomplete="off"
          spellcheck="false"
          placeholder="203.0.113.0/24"
          :aria-describedby="f.describedBy"
          :aria-invalid="f.invalid"
          @blur="show.custom = true"
        />
      </Field>

      <Field
        v-slot="f"
        label="Comment"
        :error="visible('comment', commentError)"
        help="Optional. Shown next to the rule."
      >
        <input
          :id="f.id"
          v-model="form.comment"
          class="input"
          autocomplete="off"
          placeholder="e.g. HTTPS"
          :aria-describedby="f.describedBy"
          :aria-invalid="f.invalid"
          @blur="show.comment = true"
        />
      </Field>

      <p v-if="hit" class="m-0 flex items-start gap-1.5 text-xs-var text-c-warn" role="status">
        <LIcon is="width:13px;height:13px;margin-top:2px;flex-shrink:0" name="triangle-alert" />
        Port {{ hit.port }} is used by {{ hit.what }}. A {{ form.action }} rule can cut off your access.
      </p>
      <p
        v-else-if="form.source === 'any' && form.action === 'ALLOW' && form.port"
        class="m-0 flex items-start gap-1.5 text-xs-var text-c-tx2"
      >
        <LIcon is="width:13px;height:13px;margin-top:2px;flex-shrink:0" name="globe" />
        Every address on the internet will be able to reach this port.
      </p>
    </form>

    <template #footer>
      <Btn :disabled="pending" @click="emit('close')">Cancel</Btn>
      <Btn type="submit" form="fw-add-rule" variant="primary" :loading="pending">
        <LIcon name="plus" /> Add rule
      </Btn>
    </template>
  </BaseDialog>
</template>
