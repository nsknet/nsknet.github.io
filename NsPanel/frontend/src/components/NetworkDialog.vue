<script setup lang="ts">
/** DHCP or a static IPv4 address for one interface.
 *
 * Opened through `ui.openNetworkDialog`. `onConfirm` may return a promise of
 * the action's result: the dialog stays open while it runs and when it
 * resolves to null/false (the request failed), and closes otherwise.
 * A static change is confirmed first: it can drop the session.
 */
import { computed, reactive, ref } from 'vue';

import { useUiStore, type NetworkDialog } from '@/stores/ui';
import { cidr, IPV4, ipv4, sameSubnet } from '@/utils/validate';

import BaseDialog from './ui/BaseDialog.vue';
import Btn from './ui/Btn.vue';
import Field from './ui/Field.vue';
import LIcon from './ui/LIcon.vue';

const props = defineProps<{ dialog: NetworkDialog }>();
const emit = defineEmits<{ close: [] }>();

const ui = useUiStore();

const iface = props.dialog.iface;
const current = props.dialog.current;

const initial = {
  mode: (current.method === 'dhcp' ? 'dhcp' : 'manual') as 'dhcp' | 'manual',
  address: current.cidr || (current.ip && current.prefix != null ? `${current.ip}/${current.prefix}` : current.ip || ''),
  gateway: current.gateway || '',
  dns: (Array.isArray(current.dns) ? current.dns : []).join(', '),
};
const form = reactive({ ...initial });
const submitted = ref(false);
const touched = reactive({ address: false, gateway: false, dns: false });
const pending = ref(false);

const dnsServers = computed(() =>
  form.dns
    .split(/[,\s]+/)
    .map((server) => server.trim())
    .filter(Boolean),
);

const addressError = computed(() => {
  if (form.mode !== 'manual') return '';
  if (!form.address.trim()) return 'Enter the address with its prefix, e.g. 192.168.1.50/24.';
  if (cidr(form.address)) return 'Use CIDR notation, e.g. 192.168.1.50/24.';
  const prefix = Number(form.address.split('/')[1]);
  return prefix < 8 ? 'A prefix shorter than /8 is almost certainly a mistake.' : '';
});

const gatewayError = computed(() => {
  if (form.mode !== 'manual') return '';
  if (!form.gateway.trim()) return 'A gateway is required: without it the host loses its default route.';
  if (ipv4(form.gateway)) return ipv4(form.gateway);
  if (addressError.value) return '';
  const [address, prefix] = form.address.trim().split('/');
  if (form.gateway.trim() === address) return 'The gateway cannot be this interface’s own address.';
  if (Number(prefix) < 32 && !sameSubnet(form.address, form.gateway)) {
    return `The gateway must be inside ${networkOf(form.address)}.`;
  }
  return '';
});

const dnsError = computed(() => {
  if (form.mode !== 'manual') return '';
  const bad = dnsServers.value.find((server) => !IPV4.test(server));
  return bad ? `${bad} is not an IPv4 address.` : '';
});

const show = (key: keyof typeof touched, message: string) => (submitted.value || touched[key] ? message : '');

const dirty = computed(
  () =>
    form.mode !== initial.mode ||
    form.address !== initial.address ||
    form.gateway !== initial.gateway ||
    form.dns !== initial.dns,
);

function networkOf(address: string): string {
  const [ip, prefixText] = address.trim().split('/');
  const prefix = Number(prefixText);
  const value = ip.split('.').reduce((acc, part) => (acc << 8) + Number(part), 0) >>> 0;
  const mask = prefix === 0 ? 0 : (~0 << (32 - prefix)) >>> 0;
  const net = (value & mask) >>> 0;
  return `${[24, 16, 8, 0].map((shift) => (net >>> shift) & 255).join('.')}/${prefix}`;
}

async function apply(values: Record<string, string>): Promise<void> {
  pending.value = true;
  let ok = true;
  try {
    const result: unknown = await Promise.resolve(props.dialog.onConfirm(values) as unknown);
    ok = result !== null && result !== false;
  } catch {
    ok = false;
  } finally {
    pending.value = false;
  }
  if (ok) emit('close');
}

function submit(): void {
  submitted.value = true;
  if (form.mode === 'dhcp') {
    ui.confirmThen(
      `Switch ${iface} to DHCP?`,
      'The address may change to whatever the network’s DHCP server assigns.',
      () => void apply({ iface, method: 'dhcp' }),
      {
        danger: true,
        confirmLabel: 'Switch to DHCP',
        details: [
          'If you reach the panel through this interface, reconnect on the new address.',
          'The server rolls back automatically if the interface gets no address.',
        ],
      },
    );
    return;
  }

  if (addressError.value || gatewayError.value || dnsError.value) return;
  const address = form.address.trim();
  const gateway = form.gateway.trim();
  ui.confirmThen(
    `Apply ${address} to ${iface}?`,
    'netplan applies the change immediately. If you are connected through this interface, your session may drop.',
    () =>
      void apply({
        iface,
        method: 'manual',
        address,
        gateway,
        dns: dnsServers.value.join(','),
      }),
    {
      danger: true,
      confirmLabel: 'Apply static address',
      details: [
        `Address ${address}, gateway ${gateway}${dnsServers.value.length ? `, DNS ${dnsServers.value.join(', ')}` : ''}.`,
        'If the gateway does not answer within about 10 seconds, the server restores the previous configuration by itself.',
        address.split('/')[0] !== current.ip
          ? `The address changes from ${current.ip || 'none'}: reconnect to the panel on ${address.split('/')[0]}.`
          : 'The address stays the same.',
      ],
    },
  );
}
</script>

<template>
  <BaseDialog
    :title="`Configure ${iface}`"
    description="IPv4 addressing for this interface, applied with netplan."
    icon="network"
    tone="accent"
    :dirty="dirty"
    :closable="!pending"
    @close="emit('close')"
  >
    <form id="network-form" class="flex flex-col gap-4" novalidate @submit.prevent="submit">
      <fieldset class="m-0 p-0 border-0 min-w-0">
        <legend class="text-sm-var font-medium text-c-tx mb-1.5 p-0">Addressing</legend>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
          <label
            v-for="option in [
              { value: 'dhcp', title: 'Automatic (DHCP)', hint: 'Assigned by the network', icon: 'zap' },
              { value: 'manual', title: 'Static', hint: 'An address you choose', icon: 'pencil' },
            ]"
            :key="option.value"
            :class="[
              'flex items-start gap-2.5 px-3 py-2.5 rounded-theme border cursor-pointer transition-colors',
              form.mode === option.value
                ? 'border-c-accent bg-c-acsoft text-c-tx'
                : 'border-c-border bg-c-elev text-c-tx2 hover:bg-c-hover',
            ]"
          >
            <input
              v-model="form.mode"
              type="radio"
              name="network-mode"
              :value="option.value"
              class="mt-0.5 w-4 h-4 accent-c-accent shrink-0"
              :data-autofocus="form.mode === option.value ? '' : undefined"
            />
            <span class="flex flex-col gap-0.5 min-w-0">
              <span class="flex items-center gap-1.5 text-sm-var font-medium">
                <LIcon :name="option.icon" is="width:14px;height:14px" /> {{ option.title }}
              </span>
              <span class="text-xs-var text-c-tx2">{{ option.hint }}</span>
            </span>
          </label>
        </div>
      </fieldset>

      <template v-if="form.mode === 'manual'">
        <Field
          v-slot="f"
          label="Address (CIDR)"
          required
          :error="show('address', addressError)"
          help="The address and its prefix length, e.g. 192.168.1.50/24."
        >
          <input
            :id="f.id"
            v-model="form.address"
            class="input mono"
            inputmode="decimal"
            autocomplete="off"
            spellcheck="false"
            placeholder="192.168.1.50/24"
            :aria-describedby="f.describedBy"
            :aria-invalid="f.invalid"
            @blur="touched.address = true"
          />
        </Field>
        <Field
          v-slot="f"
          label="Gateway"
          required
          :error="show('gateway', gatewayError)"
          help="The router on the same subnet. Required for a static address."
        >
          <input
            :id="f.id"
            v-model="form.gateway"
            class="input mono"
            inputmode="decimal"
            autocomplete="off"
            spellcheck="false"
            placeholder="192.168.1.1"
            :aria-describedby="f.describedBy"
            :aria-invalid="f.invalid"
            @blur="touched.gateway = true"
          />
        </Field>
        <Field
          v-slot="f"
          label="DNS servers"
          :error="show('dns', dnsError)"
          help="Optional. IPv4 addresses separated by commas or spaces."
        >
          <input
            :id="f.id"
            v-model="form.dns"
            class="input mono"
            autocomplete="off"
            spellcheck="false"
            placeholder="1.1.1.1, 8.8.8.8"
            :aria-describedby="f.describedBy"
            :aria-invalid="f.invalid"
            @blur="touched.dns = true"
          />
        </Field>
      </template>

      <p v-else class="m-0 text-sm-var text-c-tx2 border border-c-border rounded-theme p-3 bg-c-elev">
        The interface asks the network’s DHCP server for its address, gateway and DNS servers.
      </p>

      <p class="m-0 flex items-start gap-1.5 text-xs-var text-c-warn">
        <LIcon name="triangle-alert" is="width:13px;height:13px;margin-top:2px;flex-shrink:0" />
        <span>
          If you are connected through <span class="mono">{{ iface }}</span>, your session may drop
          while the change applies.
        </span>
      </p>
    </form>

    <template #footer>
      <Btn :disabled="pending" @click="emit('close')">Cancel</Btn>
      <Btn type="submit" form="network-form" variant="primary" :loading="pending">
        <LIcon name="check" /> Apply
      </Btn>
    </template>
  </BaseDialog>
</template>
