<script setup lang="ts">
/** Install the panel as a systemd service, or change how it runs: port,
 *  networks the port is opened to, HTTPS, and optionally a new admin password. */
import { computed, reactive, ref, useId } from 'vue';

import type { PanelInstallValues, PanelTarget } from '@/api/settings';
import type { PanelServiceStatus } from '@/api/types';
import Alert from '@/components/ui/Alert.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import CardHeader from '@/components/ui/CardHeader.vue';
import Field from '@/components/ui/Field.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PasswordField from '@/components/ui/PasswordField.vue';
import SubnetPicker from '@/components/ui/SubnetPicker.vue';
import { useJobRunner } from '@/composables/useJobs';
import { endpoints } from '@/api/client';
import { first, password as passwordRule, PASSWORD_MIN, port as portRule } from '@/utils/validate';

const props = defineProps<{ status: PanelServiceStatus; disabled?: boolean }>();
const emit = defineEmits<{ cancel: []; saved: [target: PanelTarget] }>();

const { run } = useJobRunner();
const tlsId = useId();
const s = props.status;

// Empty keeps the host's current admin password (the one you signed in with).
const password = ref('');
const port = ref(String(s.installed ? s.port : s.default_port));
const tls = ref(s.installed ? s.tls : true);
const current = new Set(s.subnets);
const selected = ref<Record<string, boolean>>(
  Object.fromEntries(
    s.subnet_choices.map((choice) => [
      choice.cidr,
      s.installed && current.size ? current.has(choice.cidr) : choice.default,
    ]),
  ),
);

const submitted = ref(false);
const touched = reactive({ password: false, port: false });
const pending = ref(false);

const chosenSubnets = computed(() =>
  Object.keys(selected.value).filter((cidr) => selected.value[cidr]),
);

const passwordError = computed(() => {
  const value = password.value;
  if (!value) return '';
  return first(
    passwordRule(value, PASSWORD_MIN),
    value.trim() !== value ? 'The password must not start or end with a space.' : '',
  );
});
const portError = computed(() => {
  const message = portRule(port.value, { min: 1024 });
  if (message) return message;
  // The panel serving this page holds its port — unless it is the service itself.
  if (!s.is_self && Number(port.value) === s.current_port) {
    return `Port ${port.value} is used by the panel you are on. Pick another one.`;
  }
  return '';
});
const subnetError = computed(() => (chosenSubnets.value.length ? '' : 'Pick at least one network.'));

const shown = (key: 'password' | 'port', message: string) => (submitted.value || touched[key] ? message : '');

const restartsSelf = computed(() => s.installed && s.is_self);

async function submit(): Promise<void> {
  submitted.value = true;
  if (passwordError.value || portError.value || subnetError.value || pending.value) return;
  const values: PanelInstallValues = {
    // Omitted when empty: the service keeps the current admin password.
    password: password.value || undefined,
    port: Number(port.value),
    allowed_subnets: chosenSubnets.value.join(','),
    tls: tls.value,
  };
  const target: PanelTarget = { port: values.port, scheme: values.tls ? 'https:' : 'http:' };
  pending.value = true;
  try {
    await run(`${endpoints.panel}/install`, { ...values }, { onSuccess: () => emit('saved', target) });
  } finally {
    pending.value = false;
  }
}
</script>

<template>
  <Card class="overflow-clip max-w-[680px]">
    <CardHeader :title="status.installed ? 'Reconfigure the service' : 'Install as a service'" icon="rocket">
      <span class="mono text-xs-var text-c-tx3 truncate">{{ status.repo_dir || '/opt/nspanel' }}</span>
    </CardHeader>
    <form class="p-4 flex flex-col gap-5" novalidate @submit.prevent="submit">
      <p class="m-0 text-sm-var text-c-tx2">
        Installs the panel from GitHub (<span class="mono">{{ status.branch }}</span>) into its own directory,
        starts it with systemd on boot, and opens its port in UFW for the networks you pick.
      </p>
      <Alert v-if="restartsSelf" tone="warn">
        Saving restarts the panel you are on. This page follows it to the new address.
      </Alert>

      <Field
        label="Port"
        help="1024–65535. The service's URL changes if you change it."
        :error="shown('port', portError)"
        required
        v-slot="f"
      >
        <input
          :id="f.id"
          v-model="port"
          type="text"
          inputmode="numeric"
          class="input mono max-w-[160px]"
          autocomplete="off"
          :aria-describedby="f.describedBy"
          :aria-invalid="f.invalid"
          @blur="touched.port = true"
        />
      </Field>

      <div>
        <SubnetPicker v-model="selected" :choices="status.subnet_choices" :legend="`Open port ${port || '…'} to`" />
        <p v-if="selected['0.0.0.0/0']" class="m-0 mt-1.5 text-xs-var text-c-warn">
          Anyone who can reach this server could try the panel login.
        </p>
        <p v-if="submitted && subnetError" class="m-0 mt-1.5 text-xs-var text-c-danger" role="alert">
          {{ subnetError }}
        </p>
      </div>

      <div class="flex flex-col gap-1.5">
        <label :for="tlsId" class="flex items-start gap-2.5 cursor-pointer select-none">
          <input
            :id="tlsId"
            v-model="tls"
            type="checkbox"
            class="w-4 h-4 mt-0.5 accent-c-accent shrink-0"
            :aria-describedby="`${tlsId}-help`"
          />
          <span class="text-sm-var font-medium text-c-tx">Serve over HTTPS</span>
        </label>
        <p :id="`${tlsId}-help`" class="m-0 pl-[26px] text-xs-var text-c-tx3">
          With a self-signed certificate made for this host: the browser asks you to trust it once. Replace the
          files in <span class="mono">/etc/nspanel/tls</span> to use your own.
        </p>
        <Alert v-if="!tls" tone="warn" class="mt-1">
          Plain HTTP: anyone on the same network segment could read the password in transit.
        </Alert>
      </div>

      <Field
        label="New admin password (optional)"
        :help="`Leave empty to keep the password you signed in with. A new one (at least ${PASSWORD_MIN} characters) replaces the admin password of every NsPanel on this host; only its hash is stored.`"
        :error="shown('password', passwordError)"
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

      <div class="flex flex-wrap justify-end gap-2 pt-1">
        <Btn v-if="status.installed" :disabled="pending" @click="emit('cancel')">Cancel</Btn>
        <Btn variant="primary" type="submit" :loading="pending" :disabled="disabled">
          <LIcon :name="status.installed ? 'check' : 'download'" />
          {{ status.installed ? 'Save & restart' : 'Install service' }}
        </Btn>
      </div>
    </form>
  </Card>
</template>
