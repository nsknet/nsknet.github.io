<script setup lang="ts">
/** Before a tool installs (or changes its password): the admin password, the
 *  module's own install parameters, and which networks its ports open to.
 *
 * `dialog.onConfirm` may return a promise of `false` (or `false`) when the
 * request failed: the dialog then stays open with the input intact.
 */
import { computed, onMounted, reactive, ref, useId } from 'vue';

import type { InstallParam } from '@/api/types';
import type { InstallDialog } from '@/stores/ui';
import { ANY_IP, generatePassword } from '@/utils/secrets';
import { first, required } from '@/utils/validate';

import BaseDialog from './ui/BaseDialog.vue';
import Btn from './ui/Btn.vue';
import Field from './ui/Field.vue';
import LIcon from './ui/LIcon.vue';
import PasswordField from './ui/PasswordField.vue';
import SubnetPicker from './ui/SubnetPicker.vue';

const props = defineProps<{ dialog: InstallDialog }>();
const emit = defineEmits<{ close: [] }>();

const formId = useId();
const tool = props.dialog.tool;
const isPasswordMode = props.dialog.mode === 'password';
const needsPassword = isPasswordMode || tool.requiresPassword;
const ports = isPasswordMode ? [] : (tool.firewallPorts ?? []);
const params: InstallParam[] = isPasswordMode ? [] : (tool.installParams ?? []);
/** Tools without a login of their own are never offered to every IP. */
const allowPublic = tool.allowPublic !== false;

/** Backend rule for tool passwords (core/validators.py PASSWORD). */
const TOOL_PASSWORD = /^[A-Za-z0-9!@#%^&*()\-_=+.:,?]+$/;
const TOOL_PASSWORD_MIN = 8;

function initialValue(param: InstallParam): string | boolean {
  if (param.type === 'checkbox') return param.default === true || param.default === 'true';
  if (param.default !== undefined && param.default !== null && param.default !== '') return String(param.default);
  if (param.type === 'select' && param.options?.length) return param.options[0].value;
  return '';
}

const password = ref(needsPassword ? generatePassword() : '');
const values = reactive<Record<string, string | boolean>>(
  Object.fromEntries(params.map((param) => [param.name, initialValue(param)])),
);
// Default scope: the private ranges and loopback, never the public internet.
const selected = ref<Record<string, boolean>>({
  '10.0.0.0/8': true,
  '172.16.0.0/12': true,
  '192.168.0.0/16': true,
  '127.0.0.0/8': true,
  [ANY_IP]: false,
});

const snapshot = () => JSON.stringify([password.value, values, selected.value]);
const initial = snapshot();
const dirty = computed(() => snapshot() !== initial);

const submitted = ref(false);
const touched = reactive<Record<string, boolean>>({});
const pending = ref(false);

const chosenSubnets = computed(() => Object.keys(selected.value).filter((cidr) => selected.value[cidr]));

const passwordError = computed(() => {
  if (!needsPassword) return '';
  const value = password.value.trim();
  return first(
    required(value, 'A password'),
    value.length < TOOL_PASSWORD_MIN ? `Use at least ${TOOL_PASSWORD_MIN} characters.` : '',
    TOOL_PASSWORD.test(value) ? '' : 'Letters, digits and ! @ # % ^ & * ( ) - _ = + . : , ? only.',
  );
});

function paramError(param: InstallParam): string {
  const value = values[param.name];
  if (param.type === 'checkbox') return '';
  const text = String(value ?? '').trim();
  if (param.type === 'select') {
    return param.options?.some((option) => option.value === text) ? '' : `Choose a ${param.label.toLowerCase()}.`;
  }
  if (param.type === 'number') {
    if (!text || Number.isNaN(Number(text))) return `${param.label} must be a number.`;
    const n = Number(text);
    if (param.min !== undefined && n < param.min) return `${param.label} must be at least ${param.min}.`;
    if (param.max !== undefined && n > param.max) return `${param.label} must be at most ${param.max}.`;
    return '';
  }
  // eslint-disable-next-line no-control-regex
  if (/[\x00-\x1f]/.test(text)) return `${param.label} contains invalid characters.`;
  return text.length > 256 ? `${param.label} is too long (256 characters at most).` : '';
}

const subnetError = computed(() =>
  ports.length && !chosenSubnets.value.length ? 'Pick at least one network.' : '',
);

const hasErrors = computed(
  () => !!passwordError.value || !!subnetError.value || params.some((param) => !!paramError(param)),
);

/** Show a field's error once it was touched, or after a submit attempt. */
function shown(key: string, message: string): string {
  return submitted.value || touched[key] ? message : '';
}

const title = isPasswordMode ? `Change ${tool.name} password` : `Install ${tool.name}`;
const description = isPasswordMode
  ? 'The service and its credentials file get the new password.'
  : 'Set credentials and network access before the installer runs.';
const portsLabel = `Open port${ports.length > 1 ? 's' : ''} ${ports.join(', ')} to`;

const formEl = ref<HTMLFormElement | null>(null);
// BaseDialog focuses its first focusable (the close button); start in the form instead.
onMounted(() => formEl.value?.querySelector<HTMLElement>('input, select')?.focus());

async function submit(): Promise<void> {
  submitted.value = true;
  if (hasErrors.value || pending.value) return;

  const payload: Record<string, string> = {};
  if (needsPassword) payload.db_password = password.value.trim();
  if (ports.length) payload.allowed_subnets = chosenSubnets.value.join(',');
  for (const param of params) {
    const value = values[param.name];
    payload[param.name] = param.type === 'checkbox' ? (value ? 'true' : 'false') : String(value).trim();
  }

  pending.value = true;
  try {
    const outcome = await props.dialog.onConfirm(payload);
    if (outcome !== false) emit('close');
  } finally {
    pending.value = false;
  }
}
</script>

<template>
  <BaseDialog
    :title="title"
    :description="description"
    :icon="isPasswordMode ? 'key-round' : 'download'"
    tone="accent"
    :dirty="dirty"
    :closable="!pending"
    @close="emit('close')"
  >
    <form :id="formId" ref="formEl" class="flex flex-col gap-4" novalidate @submit.prevent="submit">
      <Field
        v-if="needsPassword"
        :label="isPasswordMode ? 'New password' : 'Admin / database password'"
        :error="shown('password', passwordError)"
        help="Generated for you. It is saved in the tool's credentials file — copy it now if you need it elsewhere."
        required
        v-slot="f"
      >
        <PasswordField
          :id="f.id"
          v-model="password"
          :described-by="f.describedBy"
          :invalid="f.invalid"
          generate
          copy
          @focusout="touched.password = true"
        />
      </Field>

      <template v-for="param in params" :key="param.name">
        <div v-if="param.type === 'checkbox'" class="flex flex-col gap-1">
          <label class="flex items-start gap-2.5 cursor-pointer select-none">
            <input
              v-model="values[param.name]"
              type="checkbox"
              class="w-4 h-4 mt-0.5 accent-c-accent shrink-0"
              :aria-describedby="param.help ? `${formId}-${param.name}-help` : undefined"
            />
            <span class="text-sm-var text-c-tx">{{ param.label }}</span>
          </label>
          <p v-if="param.help" :id="`${formId}-${param.name}-help`" class="m-0 pl-[26px] text-xs-var text-c-tx3">
            {{ param.help }}
          </p>
        </div>

        <Field
          v-else
          :label="param.label"
          :help="param.help"
          :error="shown(param.name, paramError(param))"
          v-slot="f"
        >
          <select
            v-if="param.type === 'select'"
            :id="f.id"
            v-model="values[param.name]"
            class="input"
            :aria-describedby="f.describedBy"
            :aria-invalid="f.invalid"
          >
            <option v-for="option in param.options" :key="option.value" :value="option.value">
              {{ option.label }}
            </option>
          </select>
          <input
            v-else
            :id="f.id"
            v-model="values[param.name]"
            :type="param.type === 'number' ? 'number' : 'text'"
            :inputmode="param.type === 'number' ? 'numeric' : undefined"
            :class="['input', param.type === 'number' ? 'mono max-w-[180px]' : '']"
            :min="param.min"
            :max="param.max"
            autocomplete="off"
            spellcheck="false"
            :aria-describedby="f.describedBy"
            :aria-invalid="f.invalid"
            @blur="touched[param.name] = true"
          />
        </Field>
      </template>

      <div v-if="ports.length">
        <SubnetPicker v-model="selected" :allow-public="allowPublic" :legend="portsLabel" />
        <p v-if="!allowPublic" class="m-0 mt-1.5 flex items-start gap-1.5 text-xs-var text-c-tx2">
          <LIcon name="info" is="width:13px;height:13px;margin-top:2px;flex-shrink:0" />
          {{ tool.name }} has no login of its own, so it is offered to private networks only.
        </p>
        <p v-if="submitted && subnetError" class="m-0 mt-1.5 text-xs-var text-c-danger" role="alert">
          {{ subnetError }}
        </p>
      </div>

      <p v-if="!needsPassword && !params.length && !ports.length" class="m-0 text-sm-var text-c-tx2">
        Nothing to configure — the installer runs with its defaults.
      </p>
    </form>

    <template #footer>
      <Btn :disabled="pending" @click="emit('close')">Cancel</Btn>
      <Btn variant="primary" type="submit" :form="formId" :loading="pending">
        <LIcon :name="isPasswordMode ? 'key-round' : 'download'" />
        {{ isPasswordMode ? 'Change password' : 'Install' }}
      </Btn>
    </template>
  </BaseDialog>
</template>
