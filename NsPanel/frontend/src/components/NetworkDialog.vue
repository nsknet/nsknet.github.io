<script setup lang="ts">
/** DHCP or a static IPv4 address for one interface. */
import { computed, onMounted, onUnmounted, ref } from 'vue';

import { useUiStore, type NetworkDialog } from '@/stores/ui';

import Btn from './ui/Btn.vue';
import LIcon from './ui/LIcon.vue';

const props = defineProps<{ dialog: NetworkDialog }>();
const emit = defineEmits<{ close: [] }>();

const ui = useUiStore();

const iface = props.dialog.iface;
const current = props.dialog.current;

const mode = ref<'dhcp' | 'manual'>(current.method === 'dhcp' ? 'dhcp' : 'manual');
const address = ref(
  current.cidr || (current.ip ? (current.prefix != null ? `${current.ip}/${current.prefix}` : current.ip) : ''),
);
const gateway = ref(current.gateway || '');
const dns = ref(Array.isArray(current.dns) ? current.dns.join(', ') : current.dns || '1.1.1.1');

// Mirrors the backend's checks so mistakes are flagged before submitting.
const IPV4 = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/;

function validIp(value: string): boolean {
  return IPV4.test(value.trim());
}

function validCidr(value: string): boolean {
  const match = value.trim().match(/^(.+)\/(\d{1,2})$/);
  if (!match) return false;
  const prefix = Number(match[2]);
  return IPV4.test(match[1]) && prefix >= 0 && prefix <= 32;
}

const addressError = computed(
  () => mode.value === 'manual' && !!address.value.trim() && !validCidr(address.value),
);
const gatewayError = computed(
  () => mode.value === 'manual' && !!gateway.value.trim() && !validIp(gateway.value),
);

function dismiss(): void {
  emit('close');
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key === 'Escape') dismiss();
}

onMounted(() => document.addEventListener('keydown', onKeydown));
onUnmounted(() => document.removeEventListener('keydown', onKeydown));

function confirm(): void {
  if (mode.value === 'dhcp') {
    dismiss();
    props.dialog.onConfirm({ iface, method: 'dhcp' });
    return;
  }

  if (!validCidr(address.value)) {
    ui.addToast({
      t: 'Invalid IP address',
      d: 'Use CIDR notation, e.g. 192.168.1.50/24',
      k: 'warn',
    });
    return;
  }
  if (gateway.value.trim() && !validIp(gateway.value)) {
    ui.addToast({ t: 'Invalid gateway', d: 'Enter a valid IPv4 address.', k: 'warn' });
    return;
  }

  const servers = dns.value
    .split(/[,\s]+/)
    .map((server) => server.trim())
    .filter(Boolean);
  for (const server of servers) {
    if (!validIp(server)) {
      ui.addToast({ t: 'Invalid DNS server', d: server, k: 'warn' });
      return;
    }
  }

  dismiss();
  props.dialog.onConfirm({
    iface,
    method: 'manual',
    address: address.value.trim(),
    // A manual config with no gateway would leave the host without a default
    // route, so fall back rather than silently dropping it off the network.
    gateway: gateway.value.trim() || '192.168.1.1',
    dns: servers.join(','),
  });
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
          <LIcon name="network" is="width:20px;height:20px" />
        </div>
        <div class="min-w-0">
          <h3 class="m-0 text-base font-semibold tracking-[-0.01em] truncate">
            Edit <span class="mono">{{ iface }}</span>
          </h3>
          <p class="m-0 text-c-tx2 text-xs-var">Configure IPv4 addressing for this interface.</p>
        </div>
      </div>

      <div class="grid grid-cols-2 gap-1.5 mb-4">
        <button
          type="button"
          :class="[
            'flex flex-col items-start gap-0.5 px-3 py-2.5 rounded-theme border text-left transition-colors',
            mode === 'dhcp'
              ? 'border-c-accent bg-c-acsoft text-c-tx'
              : 'border-c-border bg-c-elev text-c-tx2 hover:bg-c-hover',
          ]"
          @click="mode = 'dhcp'"
        >
          <span class="flex items-center gap-1.5 text-sm-var font-medium">
            <LIcon name="zap" is="width:14px;height:14px" /> Automatic
          </span>
          <span class="text-[11px] text-c-tx3">DHCP — assigned by the network</span>
        </button>
        <button
          type="button"
          :class="[
            'flex flex-col items-start gap-0.5 px-3 py-2.5 rounded-theme border text-left transition-colors',
            mode === 'manual'
              ? 'border-c-accent bg-c-acsoft text-c-tx'
              : 'border-c-border bg-c-elev text-c-tx2 hover:bg-c-hover',
          ]"
          @click="mode = 'manual'"
        >
          <span class="flex items-center gap-1.5 text-sm-var font-medium">
            <LIcon name="pencil" is="width:14px;height:14px" /> Manual
          </span>
          <span class="text-[11px] text-c-tx3">Static IP address</span>
        </button>
      </div>

      <div v-if="mode === 'manual'" class="flex flex-col gap-3">
        <div>
          <label class="block text-xs-var text-c-tx2 mb-1.5">
            <span class="uppercase tracking-[0.05em] text-[10px] font-medium"
              >IP address (CIDR)</span
            >
          </label>
          <input
            v-model="address"
            class="input mono w-full"
            :class="addressError ? 'border-c-danger' : ''"
            placeholder="192.168.1.50/24"
            spellcheck="false"
            autocomplete="off"
          />
          <div v-if="addressError" class="text-[11px] text-c-danger mt-1">
            Enter an address in CIDR notation, e.g. 192.168.1.50/24.
          </div>
        </div>
        <div>
          <label class="block text-xs-var text-c-tx2 mb-1.5">
            <span class="uppercase tracking-[0.05em] text-[10px] font-medium">
              Gateway
              <span class="text-c-tx3 normal-case tracking-normal"
                >(optional, defaults to 192.168.1.1)</span
              >
            </span>
          </label>
          <input
            v-model="gateway"
            class="input mono w-full"
            :class="gatewayError ? 'border-c-danger' : ''"
            placeholder="192.168.1.1"
            spellcheck="false"
            autocomplete="off"
          />
          <div v-if="gatewayError" class="text-[11px] text-c-danger mt-1">
            Enter a valid IPv4 address.
          </div>
        </div>
        <div>
          <label class="block text-xs-var text-c-tx2 mb-1.5">
            <span class="uppercase tracking-[0.05em] text-[10px] font-medium">
              DNS servers
              <span class="text-c-tx3 normal-case tracking-normal">(optional, comma-separated)</span>
            </span>
          </label>
          <input
            v-model="dns"
            class="input mono w-full"
            placeholder="1.1.1.1, 8.8.8.8"
            spellcheck="false"
            autocomplete="off"
          />
        </div>
      </div>

      <div v-else class="text-xs-var text-c-tx2 border border-c-border rounded-theme p-3 bg-c-elev">
        The interface will request its address, gateway and DNS automatically from the network's
        DHCP server.
      </div>

      <div class="flex items-start gap-1.5 text-[11px] text-c-warn mt-3">
        <LIcon name="triangle-alert" is="width:12px;height:12px;margin-top:1px;flex-shrink:0" />
        <span>
          Applies via <span class="mono">netplan</span>. If you are connected over
          <span class="mono">{{ iface }}</span
          >, your session may briefly drop.
        </span>
      </div>

      <div class="flex justify-end gap-1.5 mt-5">
        <Btn @click="dismiss">Cancel</Btn>
        <Btn variant="primary" @click="confirm"><LIcon name="check" /> Apply</Btn>
      </div>
    </div>
  </div>
</template>
