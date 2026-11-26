<script setup lang="ts">
/** The host: facts, live usage, timezone, swap and one-click maintenance. */
import { storeToRefs } from 'pinia';
import { computed, ref } from 'vue';

import TimezonePicker from '@/components/system/TimezonePicker.vue';
import Alert from '@/components/ui/Alert.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import CardHeader from '@/components/ui/CardHeader.vue';
import ErrorState from '@/components/ui/ErrorState.vue';
import Field from '@/components/ui/Field.vue';
import KeyValueList from '@/components/ui/KeyValueList.vue';
import LIcon from '@/components/ui/LIcon.vue';
import MetricCard from '@/components/ui/MetricCard.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import type { KeyValueItem } from '@/components/ui/types';
import { useJobRunner } from '@/composables/useJobs';
import { usePolling } from '@/composables/usePolling';
import { useRefresh } from '@/composables/useRefresh';
import { useSystemStore } from '@/stores/system';
import { useUiStore } from '@/stores/ui';
import { gb } from '@/utils/format';

const ui = useUiStore();
const { run } = useJobRunner();
const { refresh, refreshing } = useRefresh();
const system = useSystemStore();
const { host, architecture, hostLoaded, hostError, loadingHost } = storeToRefs(system);

usePolling(() => system.load({ silent: true }), 10_000);

const UTILITIES =
  'wget, curl, rsync, htop, ncdu, iotop, sysstat, tmux, zip/unzip, jq, git, bc, tree, pv, nano, vim, less, lsof, psmisc, dnsutils, net-tools, traceroute';

const facts = computed<KeyValueItem[]>(() => {
  const h = host.value;
  return [
    { key: 'hostname', label: 'Hostname', value: h.hostname, mono: true, copy: true },
    { key: 'os', label: 'Operating system', value: h.distro },
    { key: 'kernel', label: 'Kernel', value: h.kernel, mono: true },
    { key: 'arch', label: 'Architecture', value: architecture.value, mono: true },
    {
      key: 'cpu',
      label: 'CPU',
      value: h.cpu.threads ? `${h.cpu.cores || '?'} cores · ${h.cpu.threads} threads` : '',
    },
    { key: 'uptime', label: 'Uptime', value: h.uptime },
    { key: 'timezone', label: 'Timezone', value: h.timezone, mono: true },
  ];
});

const load = computed(() => host.value.cpu.load.map((value) => value.toFixed(2)).join(' / '));
const hasSwap = computed(() => host.value.swap.total > 0);

// --- Timezone ------------------------------------------------------------------
const pickingZone = ref(false);

// --- Swap ----------------------------------------------------------------------
const swapSize = ref<string | number>(
  String(Math.min(64, Math.max(1, Math.round(host.value.swap.total) || 4))),
);
const swapTouched = ref(false);
const swapError = computed(() => {
  // v-model on a number input yields a number (or "" when empty).
  const text = String(swapSize.value).trim();
  if (!/^\d+$/.test(text)) return 'Enter a whole number of gigabytes.';
  const size = Number(text);
  return size >= 1 && size <= 64 ? '' : 'Use a size between 1 and 64 GB.';
});
const swapPending = ref(false);

function applySwap(): void {
  swapTouched.value = true;
  if (swapError.value) return;
  const size = Number(swapSize.value);
  const replacing = hasSwap.value;
  ui.confirmThen(
    replacing ? `Replace swap with ${size} GB?` : `Create ${size} GB of swap?`,
    replacing
      ? `Swap is turned off, /swapfile is rewritten at ${size} GB and turned back on.`
      : `Creates /swapfile (${size} GB), turns it on and adds it to /etc/fstab.`,
    async () => {
      swapPending.value = true;
      await run('/api/v1/system/swap', { size_gb: size }, { title: `Provisioning ${size} GB swap` });
      swapPending.value = false;
    },
    {
      danger: replacing,
      confirmLabel: replacing ? 'Replace swap' : 'Create swap',
      details: [
        `Needs ${size} GB + 512 MB free on / (the current swap file counts as free). Without it the job stops and changes nothing.`,
        '/etc/fstab is backed up, checked after the edit and restored on error.',
        ...(replacing
          ? ['Turning swap off moves its pages back into RAM; this can take a while on a busy host.']
          : []),
      ],
    },
  );
}

// --- Maintenance ---------------------------------------------------------------
function installUtils(): void {
  ui.confirmThen(
    'Install common utilities?',
    'Runs apt-get update and installs the usual command-line tools. Installed packages are left as they are.',
    () => void run('/api/v1/system/install-utils', {}, { title: 'Installing common utilities' }),
    {
      confirmLabel: 'Install utilities',
      details: [
        UTILITIES + '.',
        'Optional extras when available: axel, bpytop, rar/unrar, p7zip, iftop, mtr.',
      ],
    },
  );
}

function commonConfig(): void {
  ui.confirmThen(
    'Run the common configuration?',
    'Prepares a fresh VPS in one job. Safe to run again; finished steps are skipped.',
    () => void run('/api/v1/system/common-config', {}, { title: 'Common configuration' }),
    {
      confirmLabel: 'Run configuration',
      details: [
        'Installs the common utilities (as above).',
        'Installs cloudflared.',
        'Installs and enables UFW: allows SSH and this panel’s port first, then denies other incoming traffic.',
        'Does not change the timezone, swap or network settings.',
      ],
    },
  );
}
</script>

<template>
  <section>
    <PageHeader title="Host" :subtitle="host.distro ? `${host.distro} · ${host.kernel}` : 'This server.'">
      <Btn :loading="refreshing" @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
    </PageHeader>

    <ErrorState v-if="hostError && !hostLoaded" :message="hostError" @retry="system.load()" />

    <template v-else>
      <Alert v-if="hostError" tone="warn" class="mb-4" title="Showing the last known values">
        {{ hostError }}
      </Alert>

      <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-3 mb-4">
        <MetricCard
          label="CPU"
          icon="cpu"
          :value="Math.round(host.cpu.usage)"
          unit="%"
          :sub="`Load ${load}`"
          :percent="host.cpu.usage"
          :loading="loadingHost && !hostLoaded"
        />
        <MetricCard
          label="Memory"
          icon="memory-stick"
          :value="host.ram.used.toFixed(1)"
          :unit="`/ ${host.ram.total.toFixed(1)} GB`"
          :sub="`${Math.round(host.ram.pct)}% used · ${gb(Math.max(0, host.ram.total - host.ram.used))} free`"
          :percent="host.ram.pct"
          :loading="loadingHost && !hostLoaded"
        />
        <MetricCard
          label="Disk /"
          icon="hard-drive"
          :value="host.disk.used.toFixed(1)"
          :unit="`/ ${host.disk.total.toFixed(1)} GB`"
          :sub="`${Math.round(host.disk.pct)}% used · ${gb(Math.max(0, host.disk.total - host.disk.used))} free`"
          :percent="host.disk.pct"
          :loading="loadingHost && !hostLoaded"
        />
        <MetricCard
          label="Swap"
          icon="layers"
          :value="hasSwap ? host.swap.used.toFixed(1) : 'Off'"
          :unit="hasSwap ? `/ ${host.swap.total.toFixed(1)} GB` : ''"
          :sub="hasSwap ? `${Math.round(host.swap.pct)}% used` : 'No swap configured'"
          :percent="hasSwap ? host.swap.pct : null"
          :loading="loadingHost && !hostLoaded"
        />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)] gap-4 items-start">
        <Card class="overflow-clip">
          <CardHeader title="Host details" icon="server" subtitle="Usage refreshes every 10 s" />
          <div class="p-4">
            <KeyValueList :items="facts" label-width="150px">
              <template #value-timezone="{ item }">
                <span class="mono text-xs-var">{{ item.value || '—' }}</span>
                <Btn
                  v-if="!pickingZone"
                  variant="ghost"
                  sm
                  :aria-label="`Change timezone (now ${item.value})`"
                  @click="pickingZone = true"
                >
                  <LIcon name="pencil" /> Change
                </Btn>
              </template>
            </KeyValueList>
            <div v-if="pickingZone" class="mt-4 pt-4 border-t border-c-border">
              <TimezonePicker :current="host.timezone" @done="pickingZone = false" />
            </div>
          </div>
        </Card>

        <div class="flex flex-col gap-4 min-w-0">
          <Card class="overflow-clip">
            <CardHeader
              title="Swap"
              icon="layers"
              :subtitle="hasSwap ? `/swapfile · ${gb(host.swap.total)}` : 'none'"
            />
            <form class="p-4 flex flex-col gap-3" novalidate @submit.prevent="applySwap">
              <Field
                v-slot="f"
                label="Size (GB)"
                :error="swapTouched ? swapError : ''"
                help="1–64 GB. Needs that much free space on / plus 512 MB; the job checks before changing anything."
              >
                <input
                  :id="f.id"
                  v-model="swapSize"
                  type="number"
                  min="1"
                  max="64"
                  step="1"
                  inputmode="numeric"
                  class="input mono w-32"
                  :aria-describedby="f.describedBy"
                  :aria-invalid="f.invalid"
                  @blur="swapTouched = true"
                />
              </Field>
              <div>
                <Btn type="submit" :loading="swapPending">
                  <LIcon name="hard-drive-download" /> {{ hasSwap ? 'Resize swap' : 'Create swap' }}
                </Btn>
              </div>
            </form>
          </Card>

          <Card class="overflow-clip">
            <CardHeader title="Maintenance" icon="wrench" />
            <ul class="m-0 p-0 list-none divide-y divide-c-border">
              <li class="p-4 flex flex-col sm:flex-row sm:items-center gap-3">
                <div class="flex-1 min-w-0">
                  <div class="text-sm-var font-medium">Common utilities</div>
                  <p class="m-0 mt-0.5 text-xs-var text-c-tx2">
                    curl, wget, htop, git, tmux, jq, unzip and other everyday tools via apt.
                  </p>
                </div>
                <Btn sm class="self-start sm:self-auto" @click="installUtils">
                  <LIcon name="download" /> Install
                </Btn>
              </li>
              <li class="p-4 flex flex-col sm:flex-row sm:items-center gap-3">
                <div class="flex-1 min-w-0">
                  <div class="text-sm-var font-medium">Common configuration</div>
                  <p class="m-0 mt-0.5 text-xs-var text-c-tx2">
                    Utilities, cloudflared and the UFW firewall (SSH and panel ports kept open).
                  </p>
                </div>
                <Btn sm class="self-start sm:self-auto" @click="commonConfig">
                  <LIcon name="play" /> Run
                </Btn>
              </li>
            </ul>
          </Card>
        </div>
      </div>
    </template>
  </section>
</template>
