<script setup lang="ts">
/** Pre-install prompts: admin password, module params, and firewall scope. */
import { computed, onMounted, onUnmounted, ref } from 'vue';

import { useUiStore, type InstallDialog } from '@/stores/ui';

import Btn from './ui/Btn.vue';
import LIcon from './ui/LIcon.vue';

const props = defineProps<{ dialog: InstallDialog }>();
const emit = defineEmits<{ close: [] }>();

const ui = useUiStore();

const SUBNET_OPTIONS = [
  { cidr: '10.0.0.0/8', label: 'Class A — private' },
  { cidr: '172.16.0.0/12', label: 'Class B — private' },
  { cidr: '192.168.0.0/16', label: 'Class C — private' },
  { cidr: '127.0.0.0/8', label: 'Loopback (local)' },
  { cidr: '0.0.0.0/0', label: 'Any IP — public' },
];

const ALPHANUM = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

/** Alphanumeric only — the backend rejects characters that are unsafe in the
 *  SQL strings and unit files the install scripts build. */
function generatePassword(length = 24): string {
  const values = new Uint32Array(length);
  crypto.getRandomValues(values);
  return Array.from(values, (value) => ALPHANUM[value % ALPHANUM.length]).join('');
}

const tool = props.dialog.tool;
const isPasswordMode = props.dialog.mode === 'password';
const needsPassword = isPasswordMode || tool.requiresPassword;
const ports = isPasswordMode ? [] : (tool.firewallPorts ?? []);
const needsPorts = ports.length > 0;
const params = isPasswordMode ? [] : (tool.installParams ?? []);

const paramValues = ref<Record<string, string | boolean>>(
  Object.fromEntries(
    params.map((param) => {
      if (param.type === 'checkbox') {
        return [param.name, param.default === true || param.default === 'true'];
      }
      if (param.default !== undefined && param.default !== null && param.default !== '') {
        return [param.name, String(param.default)];
      }
      if (param.type === 'select' && param.options?.length) {
        return [param.name, param.options[0].value];
      }
      return [param.name, ''];
    }),
  ),
);

const password = ref(needsPassword ? generatePassword() : '');
const showPassword = ref(true);
// Default scope: private subnets plus loopback, never the public internet.
const selected = ref<Record<string, boolean>>({
  '10.0.0.0/8': true,
  '172.16.0.0/12': true,
  '192.168.0.0/16': true,
  '127.0.0.0/8': true,
  '0.0.0.0/0': false,
});

const chosenSubnets = computed(() =>
  SUBNET_OPTIONS.map((option) => option.cidr).filter((cidr) => selected.value[cidr]),
);

function dismiss(): void {
  emit('close');
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key === 'Escape') dismiss();
}

onMounted(() => document.addEventListener('keydown', onKeydown));
onUnmounted(() => document.removeEventListener('keydown', onKeydown));

function copyPassword(): void {
  navigator.clipboard
    .writeText(password.value)
    .then(() => ui.addToast({ t: 'Password copied', k: 'ok' }))
    .catch(() => ui.addToast({ t: 'Could not copy', k: 'warn' }));
}

function toggle(cidr: string): void {
  const next = !selected.value[cidr];
  if (cidr === '0.0.0.0/0' && next) {
    // "Any" supersedes everything else — clear the narrower scopes.
    for (const key of Object.keys(selected.value)) selected.value[key] = false;
    selected.value['0.0.0.0/0'] = true;
    return;
  }
  selected.value[cidr] = next;
  if (next) selected.value['0.0.0.0/0'] = false;
}

function confirm(): void {
  if (needsPassword && password.value.trim().length < 8) {
    ui.addToast({ t: 'Password too short', d: 'Use at least 8 characters.', k: 'warn' });
    return;
  }
  if (needsPorts && chosenSubnets.value.length === 0) {
    ui.addToast({ t: 'Select a firewall scope', d: 'Pick at least one subnet.', k: 'warn' });
    return;
  }

  const payload: Record<string, string> = {};
  if (needsPassword) payload.db_password = password.value.trim();
  if (needsPorts) payload.allowed_subnets = chosenSubnets.value.join(',');
  for (const param of params) {
    const value = paramValues.value[param.name];
    payload[param.name] = param.type === 'checkbox' ? (value ? 'true' : 'false') : String(value);
  }

  dismiss();
  props.dialog.onConfirm(payload);
}
</script>

<template>
  <div
    class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade"
    @click.self="dismiss"
  >
    <div
      class="w-full max-w-[460px] bg-c-bg border border-c-border rounded-theme-lg shadow-lg p-5 animate-pop"
      role="dialog"
      aria-modal="true"
    >
      <div class="flex items-center gap-3 mb-4">
        <div
          class="w-10 h-10 rounded-[10px] bg-c-acsoft text-c-accent grid place-items-center shrink-0"
        >
          <LIcon :name="isPasswordMode ? 'key-round' : 'download'" is="width:20px;height:20px" />
        </div>
        <div class="min-w-0">
          <h3 class="m-0 text-base font-semibold tracking-[-0.01em] truncate">
            {{ isPasswordMode ? `Change ${tool.name} password` : `Install ${tool.name}` }}
          </h3>
          <p class="m-0 text-c-tx2 text-xs-var">
            {{
              isPasswordMode
                ? 'Set a new admin password — the service and its credentials file are updated.'
                : 'Configure credentials and network access before installing.'
            }}
          </p>
        </div>
      </div>

      <div v-if="needsPassword" class="mb-4">
        <label class="flex items-center justify-between text-xs-var text-c-tx2 mb-1.5">
          <span class="uppercase tracking-[0.05em] text-[10px] font-medium"
            >Admin / DB password</span
          >
        </label>
        <div class="flex items-center gap-1.5">
          <div class="relative flex-1">
            <input
              v-model="password"
              :type="showPassword ? 'text' : 'password'"
              class="input mono w-full pr-8"
              autocomplete="new-password"
              spellcheck="false"
            />
            <button
              type="button"
              class="absolute right-1.5 top-1/2 -translate-y-1/2 text-c-tx3 hover:text-c-tx p-1"
              :aria-label="showPassword ? 'Hide' : 'Show'"
              @click="showPassword = !showPassword"
            >
              <LIcon :name="showPassword ? 'eye-off' : 'eye'" is="width:14px;height:14px" />
            </button>
          </div>
          <Btn sm square title="Generate new password" @click="password = generatePassword()">
            <LIcon name="refresh-cw" />
          </Btn>
          <Btn sm square title="Copy password" @click="copyPassword">
            <LIcon name="copy" />
          </Btn>
        </div>
        <div class="text-[11px] text-c-tx3 mt-1.5">
          Auto-generated. Saved to the tool's credentials file.
        </div>
      </div>

      <div v-if="params.length" class="mb-4 flex flex-col gap-3">
        <div v-for="param in params" :key="param.name">
          <label v-if="param.type !== 'checkbox'" class="block text-xs-var text-c-tx2 mb-1.5">
            <span class="uppercase tracking-[0.05em] text-[10px] font-medium">{{
              param.label
            }}</span>
          </label>
          <select
            v-if="param.type === 'select'"
            v-model="paramValues[param.name]"
            class="input w-full"
          >
            <option v-for="option in param.options" :key="option.value" :value="option.value">
              {{ option.label }}
            </option>
          </select>
          <label
            v-else-if="param.type === 'checkbox'"
            class="flex items-center gap-2.5 cursor-pointer select-none"
          >
            <input
              v-model="paramValues[param.name]"
              type="checkbox"
              class="w-3.5 h-3.5 accent-c-accent rounded shrink-0"
            />
            <span class="text-sm-var text-c-tx">{{ param.label }}</span>
          </label>
          <input
            v-else
            v-model="paramValues[param.name]"
            :type="param.type === 'number' ? 'number' : 'text'"
            class="input w-full"
            :min="param.min"
            :max="param.max"
          />
          <div v-if="param.help && param.type !== 'checkbox'" class="text-[11px] text-c-tx3 mt-1.5">
            {{ param.help }}
          </div>
        </div>
      </div>

      <div v-if="needsPorts" class="mb-4">
        <label class="block text-xs-var text-c-tx2 mb-1.5">
          <span class="uppercase tracking-[0.05em] text-[10px] font-medium">
            Open port{{ ports.length > 1 ? 's' : '' }} {{ ports.join(', ') }} to
          </span>
        </label>
        <div class="flex flex-col gap-1 border border-c-border rounded-theme p-1.5 bg-c-elev">
          <label
            v-for="option in SUBNET_OPTIONS"
            :key="option.cidr"
            :class="[
              'flex items-center gap-2.5 px-2 py-1.5 rounded-theme cursor-pointer select-none hover:bg-c-hover',
              option.cidr === '0.0.0.0/0' && selected[option.cidr] ? 'text-c-warn' : '',
            ]"
          >
            <input
              type="checkbox"
              class="w-3.5 h-3.5 accent-c-accent rounded shrink-0"
              :checked="selected[option.cidr]"
              @change="toggle(option.cidr)"
            />
            <span class="text-sm-var flex-1">{{ option.label }}</span>
            <span class="mono text-[11px] text-c-tx3 tabular-nums">{{ option.cidr }}</span>
          </label>
        </div>
        <div
          v-if="selected['0.0.0.0/0']"
          class="flex items-start gap-1.5 text-[11px] text-c-warn mt-1.5"
        >
          <LIcon name="triangle-alert" is="width:12px;height:12px;margin-top:1px;flex-shrink:0" />
          <span>Exposing this port to any IP — make sure that is intended.</span>
        </div>
      </div>

      <div class="flex justify-end gap-1.5 mt-5">
        <Btn @click="dismiss">Cancel</Btn>
        <Btn variant="primary" @click="confirm">
          <LIcon :name="isPasswordMode ? 'key-round' : 'download'" />
          {{ isPasswordMode ? 'Change password' : 'Install' }}
        </Btn>
      </div>
    </div>
  </div>
</template>
