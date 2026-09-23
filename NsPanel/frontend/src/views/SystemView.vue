<script setup lang="ts">
/** Host diagnostics, network interfaces, quick actions and disk management. */
import { storeToRefs } from 'pinia';
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue';

import type { DiskPartition, NetworkInterface } from '@/api/types';
import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import LIcon from '@/components/ui/LIcon.vue';
import Spinner from '@/components/ui/Spinner.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useSystemStore } from '@/stores/system';
import { useUiStore } from '@/stores/ui';

const ui = useUiStore();
const { run, reload } = useJobRunner();
const { host, disks, loadingDisks } = storeToRefs(useSystemStore());

const FS_TYPES = ['ext4', 'xfs', 'btrfs', 'vfat', 'ntfs', 'ext3', 'ext2'];
const TIMEZONES = [
  { tz: 'Asia/Ho_Chi_Minh', label: 'GMT+7 (Vietnam)' },
  { tz: 'America/New_York', label: 'EST (US East)' },
];

const swapSize = ref(4);

function barClass(pct: number): string {
  if (pct > 85) return 'bar-danger';
  if (pct > 70) return 'bar-warn';
  return 'bar-ok';
}

function fmtGB(value: number | null | undefined): string {
  return value != null ? `${value.toFixed(1)} GB` : '—';
}

const statCards = computed(() => {
  const h = host.value;
  return [
    {
      label: 'CPU',
      icon: 'cpu',
      value: String(h.cpu.usage),
      unit: '%',
      sub: `${h.cpu.cores} cores · ${h.cpu.threads} threads`,
      bar: null as { pct: number; cls: string } | null,
      alert: null as { tone: 'warn' | 'danger'; text: string } | null,
      rows: [
        ['1m load', String(h.cpu.load[0])],
        ['5m load', String(h.cpu.load[1])],
        ['15m load', String(h.cpu.load[2])],
      ] as [string, string][],
    },
    {
      label: 'Memory',
      icon: 'memory-stick',
      value: h.ram.used.toFixed(1),
      unit: `/ ${h.ram.total.toFixed(1)} GB`,
      sub: `${h.ram.pct}% used`,
      bar: { pct: h.ram.pct, cls: barClass(h.ram.pct) },
      alert: null,
      rows: [['Free', `${(h.ram.total - h.ram.used).toFixed(1)} GB`]] as [string, string][],
    },
    {
      label: 'Disk /',
      icon: 'hard-drive',
      value: h.disk.used.toFixed(1),
      unit: `/ ${h.disk.total.toFixed(1)} GB`,
      sub: `${h.disk.pct}% used`,
      bar: { pct: h.disk.pct, cls: barClass(h.disk.pct) },
      alert:
        h.disk.pct > 85
          ? ({ tone: 'danger', text: 'Critical: above 85%' } as const)
          : h.disk.pct > 70
            ? ({ tone: 'warn', text: 'Caution: above 70%' } as const)
            : null,
      rows: null,
    },
    {
      label: 'Swap',
      icon: 'layers',
      value: h.swap.total > 0 ? h.swap.used.toFixed(1) : null,
      unit: h.swap.total > 0 ? `/ ${h.swap.total.toFixed(1)} GB` : '',
      sub: h.swap.total > 0 ? `${h.swap.pct}% used · /swapfile` : 'No swap configured',
      bar: h.swap.total > 0 ? { pct: h.swap.pct, cls: 'bar-ok' } : null,
      alert: null,
      rows: null,
    },
  ];
});

const hostRows = computed(() => {
  const h = host.value;
  return [
    { key: 'Hostname', value: h.hostname, mono: true },
    { key: 'Distribution', value: h.distro, mono: false },
    { key: 'Kernel', value: h.kernel, mono: true },
    { key: 'Timezone', value: h.timezone, mono: true },
    { key: 'Uptime', value: h.uptime, mono: false },
  ];
});

// --- Disks -------------------------------------------------------------------

interface DiskRow extends DiskPartition {
  level: number;
  name: string;
  path: string;
  type: string;
  children?: DiskRow[];
  size_gb?: number;
  used_gb?: number;
  use_percent?: number;
  model?: string;
  removable?: boolean;
}

/** Flatten the disk tree, tagging depth so partitions indent under their disk. */
const diskRows = computed<DiskRow[]>(() => {
  const rows: DiskRow[] = [];
  const walk = (node: DiskRow, level: number) => {
    rows.push({ ...node, level });
    (node.children ?? []).forEach((child) => walk(child, level + 1));
  };
  (disks.value as unknown as DiskRow[]).forEach((disk) => walk(disk, 0));
  return rows;
});

/** Mount/unmount/format only make sense for a leaf block device under /dev. */
function actionable(row: DiskRow): boolean {
  return (
    (row.children ?? []).length === 0 &&
    row.path?.startsWith('/dev/') &&
    ['part', 'disk', 'lvm', 'crypt', 'rom'].includes(row.type)
  );
}

const diskDialog = reactive({
  open: false,
  mode: 'mount' as 'mount' | 'format',
  device: '',
  name: '',
  mountpoint: '',
  persist: true,
  fstype: 'ext4',
  label: '',
  ack: false,
});

function openMount(row: DiskRow): void {
  Object.assign(diskDialog, {
    open: true,
    mode: 'mount',
    device: row.path,
    name: row.name,
    mountpoint: `/mnt/${row.name}`,
    persist: true,
    fstype: 'ext4',
    label: '',
    ack: false,
  });
}

function openFormat(row: DiskRow): void {
  Object.assign(diskDialog, {
    open: true,
    mode: 'format',
    device: row.path,
    name: row.name,
    mountpoint: '',
    persist: true,
    fstype: row.fstype && FS_TYPES.includes(row.fstype) ? row.fstype : 'ext4',
    label: row.label ?? '',
    ack: false,
  });
}

function closeDialog(): void {
  diskDialog.open = false;
}

function submitDialog(event: Event): void {
  event.preventDefault();

  if (diskDialog.mode === 'mount') {
    const mountpoint = diskDialog.mountpoint.trim();
    if (!mountpoint.startsWith('/')) {
      ui.addToast({ t: 'Enter an absolute mount point', k: 'warn' });
      return;
    }
    closeDialog();
    void run(
      '/api/v1/system/disk/mount',
      { device: diskDialog.device, mountpoint, persist: diskDialog.persist },
      { title: `Mount ${diskDialog.device} → ${mountpoint}` },
    );
    return;
  }

  if (!diskDialog.ack) {
    ui.addToast({ t: 'Confirm the erase warning first', k: 'warn' });
    return;
  }
  const { device, fstype } = diskDialog;
  closeDialog();
  void run(
    '/api/v1/system/disk/format',
    { device, fstype, label: diskDialog.label.trim() },
    { title: `Format ${device} as ${fstype}` },
  );
}

function unmount(row: DiskRow): void {
  const target = row.mountpoint || row.path;
  ui.confirmThen(
    'Unmount partition?',
    `This unmounts ${row.path} from ${row.mountpoint} and removes its /etc/fstab entry so it will not remount on boot.`,
    () => {
      void run(
        '/api/v1/system/disk/unmount',
        { target, remove_fstab: true },
        { title: `Unmount ${target}` },
      );
    },
  );
}

// --- Quick actions ------------------------------------------------------------

async function refresh(): Promise<void> {
  await reload();
  ui.addToast({ t: 'Diagnostics refreshed', k: 'info' });
}

function setTimezone(tz: string, label: string): void {
  void run('/api/v1/system/set-timezone', { tz }, { title: `Set timezone — ${label}` });
}

function installUtils(): void {
  void run('/api/v1/system/install-utils', {}, { title: 'Installing common utilities' });
}

function installSwap(): void {
  ui.confirmThen(
    'Replace swap?',
    'This disables and rewrites /swapfile. Existing swap data is lost.',
    () => {
      void run(
        '/api/v1/system/swap',
        { size_gb: swapSize.value },
        { title: 'Provisioning swap' },
      );
    },
  );
}

function editNetwork(iface: NetworkInterface): void {
  ui.openNetworkDialog(iface.iface, iface, (payload) => {
    const title =
      payload.method === 'dhcp'
        ? `Set ${payload.iface} → DHCP`
        : `Set ${payload.iface} → ${payload.address}`;
    void run('/api/v1/system/set-network', payload, { title });
  });
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key === 'Escape') diskDialog.open = false;
}

onMounted(() => document.addEventListener('keydown', onKeydown));
onUnmounted(() => document.removeEventListener('keydown', onKeydown));
</script>

<template>
  <section>
    <div class="flex items-end justify-between gap-6 mb-6">
      <div>
        <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">System</h1>
        <div class="text-sm-var text-c-tx2">Host machine diagnostics and global configuration.</div>
      </div>
      <div class="flex gap-2">
        <Btn @click="refresh"><LIcon name="refresh-cw" /> Refresh diagnostics</Btn>
      </div>
    </div>

    <div class="grid grid-cols-4 gap-3">
      <div
        v-for="card in statCards"
        :key="card.label"
        class="bg-c-bg border border-c-border rounded-theme overflow-hidden p-[18px]"
      >
        <div class="flex items-center justify-between gap-3 mb-2.5">
          <div class="flex items-center gap-2 text-sm-var font-medium text-c-tx">
            <LIcon :name="card.icon" is="width:15px;height:15px;color:var(--text-2)" />
            {{ card.label }}
          </div>
          <Badge v-if="card.alert" :tone="card.alert.tone" dot>{{ card.alert.text }}</Badge>
        </div>
        <div class="text-[22px] font-semibold tracking-[-0.02em] tabular-nums">
          <template v-if="card.value !== null">
            {{ card.value
            }}<span v-if="card.unit" class="text-[13px] text-c-tx3 font-medium ml-0.5">
              {{ card.unit }}</span
            >
          </template>
          <span v-else class="text-c-tx3">disabled</span>
        </div>
        <div class="text-xs-var text-c-tx3 mono mt-1">{{ card.sub }}</div>
        <div v-if="card.bar" :class="['bar', card.bar.cls]">
          <span :style="{ width: `${card.bar.pct}%` }"></span>
        </div>
        <div v-if="card.rows" class="grid grid-cols-2 gap-y-2.5 gap-x-4 text-xs-var mt-3.5">
          <div v-for="row in card.rows" :key="row[0]">
            <div class="text-c-tx3 uppercase tracking-[0.06em]">{{ row[0] }}</div>
            <div class="text-c-tx mono text-sm-var mt-0.5">{{ row[1] }}</div>
          </div>
        </div>
      </div>
    </div>

    <div class="grid gap-3 mt-4" style="grid-template-columns: 2fr 1fr">
      <div class="flex flex-col gap-3">
        <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
          <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
            <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Host</h3>
            <span class="text-xs-var text-c-tx3 mono">{{ host.kernel }}</span>
          </div>
          <div class="p-4">
            <dl class="grid gap-y-2 gap-x-4 text-sm-var m-0" style="grid-template-columns: 140px 1fr">
              <template v-for="row in hostRows" :key="row.key">
                <dt class="text-c-tx2">{{ row.key }}</dt>
                <dd class="m-0 tabular-nums" :class="row.mono ? 'mono text-xs-var' : ''">
                  {{ row.value }}
                </dd>
              </template>
            </dl>
          </div>
        </div>

        <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
          <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
            <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Network interfaces</h3>
          </div>
          <table class="tbl">
            <thead>
              <tr>
                <th>Interface</th>
                <th>IP address</th>
                <th>Source</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="iface in host.network" :key="`${iface.iface}-${iface.ip}`">
                <td class="mono">
                  <strong>{{ iface.iface }}</strong>
                </td>
                <td class="mono muted">{{ iface.cidr || iface.ip }}</td>
                <td>
                  <Badge v-if="iface.method === 'dhcp'" tone="info">DHCP</Badge>
                  <Badge v-else-if="iface.method === 'static'" tone="muted">Static</Badge>
                  <Badge v-else tone="muted">{{ iface.ip.includes(':') ? 'IPv6' : 'IPv4' }}</Badge>
                </td>
                <td><Badge tone="ok" dot>up</Badge></td>
                <td class="text-right">
                  <Btn v-if="!iface.ip.includes(':')" sm @click="editNetwork(iface)">
                    <LIcon name="pencil" /> Edit
                  </Btn>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden self-start">
        <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
          <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Quick actions</h3>
        </div>

        <div class="px-4 py-3.5 border-b border-c-border">
          <div class="flex items-center justify-between gap-3 mb-2">
            <div class="flex items-center gap-2 text-sm-var font-medium">
              <LIcon name="clock" is="width:14px;height:14px;color:var(--text-2)" />Timezone
            </div>
            <span class="text-c-tx3 mono text-xs-var">{{ host.timezone }}</span>
          </div>
          <div class="text-xs-var text-c-tx2 mb-2.5">
            Apply a preset timezone. Updates <span class="mono">/etc/timezone</span>.
          </div>
          <div class="flex gap-1.5 flex-wrap">
            <Btn
              v-for="zone in TIMEZONES"
              :key="zone.tz"
              sm
              @click="setTimezone(zone.tz, zone.label)"
            >
              {{ zone.label }}
            </Btn>
          </div>
        </div>

        <div class="px-4 py-3.5 border-b border-c-border">
          <div class="flex items-center gap-2 text-sm-var font-medium mb-2">
            <LIcon name="package" is="width:14px;height:14px;color:var(--text-2)" />Common utilities
          </div>
          <div class="text-xs-var text-c-tx2 mb-2.5">
            Install <span class="mono">wget</span>, <span class="mono">curl</span>,
            <span class="mono">htop</span>, <span class="mono">git</span>,
            <span class="mono">unzip</span>, <span class="mono">tmux</span>.
          </div>
          <div class="flex gap-1.5 flex-wrap">
            <Btn sm @click="installUtils"><LIcon name="download" /> Install utilities</Btn>
          </div>
        </div>

        <div class="px-4 py-3.5">
          <div class="flex items-center justify-between gap-3 mb-2">
            <div class="flex items-center gap-2 text-sm-var font-medium">
              <LIcon name="memory-stick" is="width:14px;height:14px;color:var(--text-2)" />Virtual
              RAM (swap)
            </div>
            <span class="text-c-tx3 mono text-xs-var">
              {{ host.swap.total > 0 ? `/swapfile · ${host.swap.total.toFixed(1)} GB` : 'none' }}
            </span>
          </div>
          <div class="text-xs-var text-c-tx2 mb-2.5">
            Replaces the existing swapfile and updates <span class="mono">/etc/fstab</span>.
          </div>
          <div class="flex gap-1.5 flex-wrap items-center">
            <label for="swap-size" class="text-xs-var text-c-tx2">Size</label>
            <input
              id="swap-size"
              v-model="swapSize"
              type="number"
              class="input mono w-[70px] h-7"
              min="1"
              max="64"
            />
            <span class="text-xs-var text-c-tx2">GB</span>
            <Btn sm @click="installSwap"><LIcon name="hard-drive-download" /> Install</Btn>
          </div>
        </div>
      </div>
    </div>

    <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden mt-4">
      <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
        <div class="flex items-center gap-2.5">
          <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Disks</h3>
          <span class="text-xs-var text-c-tx3 mono">{{ diskRows.length }} devices</span>
        </div>
        <span class="text-xs-var text-c-tx3 mono">block devices · partitions · mount points</span>
      </div>
      <table class="tbl">
        <thead>
          <tr>
            <th>Device</th>
            <th>Type</th>
            <th>Size</th>
            <th>Filesystem</th>
            <th>Mount point</th>
            <th style="width: 180px">Usage</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="loadingDisks && !diskRows.length">
            <td colspan="7" class="muted" style="text-align: center; padding: 32px 0">
              <Spinner label="Loading disks…" />
            </td>
          </tr>
          <tr v-else-if="!diskRows.length">
            <td colspan="7" class="muted" style="text-align: center; padding: 32px 0">
              No block devices reported. <span class="mono">lsblk</span> may be unavailable on this
              host.
            </td>
          </tr>
          <tr v-for="row in diskRows" :key="`${row.path}:${row.mountpoint}`">
            <td>
              <span
                class="inline-flex items-center gap-2"
                :style="{ paddingLeft: `${row.level * 18}px` }"
              >
                <LIcon
                  :name="row.level === 0 ? 'hard-drive' : 'box'"
                  is="width:14px;height:14px;color:var(--text-3)"
                />
                <span class="mono" :class="row.level === 0 ? 'font-semibold' : ''">
                  {{ row.name }}
                </span>
              </span>
              <div
                v-if="row.model || row.label"
                class="text-xs-var text-c-tx3 mt-0.5"
                :style="{ paddingLeft: `${row.level * 18 + 22}px` }"
              >
                <span v-if="row.label" class="mono">{{ row.label }}</span
                ><span v-if="row.label && row.model"> · </span>{{ row.model }}
              </div>
            </td>
            <td>
              <Badge tone="muted">{{ row.type }}</Badge>
              <span v-if="row.removable" class="ml-1"><Badge tone="info">removable</Badge></span>
            </td>
            <td class="mono muted tabular-nums">{{ fmtGB(row.size_gb) }}</td>
            <td class="mono muted">{{ row.fstype || '—' }}</td>
            <td class="mono muted">{{ row.mountpoint || '—' }}</td>
            <td>
              <template v-if="row.use_percent != null">
                <div class="text-xs-var text-c-tx2 tabular-nums">
                  {{ fmtGB(row.used_gb) }} / {{ fmtGB(row.size_gb) }} · {{ row.use_percent }}%
                </div>
                <div :class="['bar', barClass(row.use_percent)]">
                  <span :style="{ width: `${row.use_percent}%` }"></span>
                </div>
              </template>
              <span v-else class="text-c-tx3">—</span>
            </td>
            <td class="text-right whitespace-nowrap">
              <template v-if="actionable(row)">
                <Btn v-if="row.mountpoint" sm title="Unmount" @click="unmount(row)">
                  <LIcon name="eject" /> Unmount
                </Btn>
                <Btn v-else-if="row.fstype" sm title="Mount" @click="openMount(row)">
                  <LIcon name="plug" /> Mount
                </Btn>
                <Btn
                  v-if="!row.mountpoint"
                  variant="danger"
                  sm
                  class="ml-1.5"
                  title="Format"
                  @click="openFormat(row)"
                >
                  <LIcon name="eraser" /> Format
                </Btn>
              </template>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <div
      v-if="diskDialog.open"
      class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade"
      @click.self="closeDialog"
    >
      <div
        class="w-full max-w-[460px] bg-c-bg border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop"
        role="dialog"
        aria-modal="true"
      >
        <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
          <div
            class="w-7 h-7 rounded-[7px] grid place-items-center"
            :class="diskDialog.mode === 'format' ? 'bg-c-dngsoft' : 'bg-c-subtle'"
          >
            <LIcon
              :name="diskDialog.mode === 'format' ? 'eraser' : 'plug'"
              is="width:14px;height:14px"
            />
          </div>
          <div>
            <div class="font-semibold text-sm-var">
              {{ diskDialog.mode === 'format' ? 'Format device' : 'Mount device' }}
            </div>
            <div class="text-xs-var text-c-tx2 mono">{{ diskDialog.device }}</div>
          </div>
          <Btn variant="ghost" sm square class="ml-auto" aria-label="Close" @click="closeDialog">
            <LIcon name="x" />
          </Btn>
        </div>

        <form class="p-4 flex flex-col gap-3.5" @submit="submitDialog">
          <template v-if="diskDialog.mode === 'mount'">
            <div class="flex flex-col gap-1.5">
              <label for="dk-mp" class="text-sm-var font-medium text-c-tx">Mount point</label>
              <input
                id="dk-mp"
                v-model="diskDialog.mountpoint"
                class="input mono"
                placeholder="/mnt/data"
              />
              <div class="text-xs-var text-c-tx2">Absolute path. Created if it does not exist.</div>
            </div>
            <label class="flex items-center gap-2 text-sm-var text-c-tx cursor-pointer">
              <input v-model="diskDialog.persist" type="checkbox" />
              Persist in <span class="mono">/etc/fstab</span> (auto-mount on boot)
            </label>
          </template>

          <template v-else>
            <div
              class="flex items-center gap-2.5 px-3.5 py-2.5 rounded-theme bg-c-dngsoft text-c-danger text-sm-var border border-transparent"
            >
              <LIcon name="triangle-alert" is="width:16px;height:16px;flex-shrink:0" />
              <div>
                <strong>This erases all data</strong> on {{ diskDialog.device }}. This cannot be
                undone.
              </div>
            </div>
            <div class="flex flex-col gap-1.5">
              <label for="dk-fs" class="text-sm-var font-medium text-c-tx">Filesystem</label>
              <select id="dk-fs" v-model="diskDialog.fstype" class="input">
                <option v-for="fs in FS_TYPES" :key="fs" :value="fs">{{ fs }}</option>
              </select>
            </div>
            <div class="flex flex-col gap-1.5">
              <label for="dk-label" class="text-sm-var font-medium text-c-tx">
                Label <span class="text-c-tx3 font-normal">· optional</span>
              </label>
              <input id="dk-label" v-model="diskDialog.label" class="input mono" placeholder="data" />
            </div>
            <label class="flex items-center gap-2 text-sm-var text-c-tx cursor-pointer">
              <input v-model="diskDialog.ack" type="checkbox" />
              I understand this permanently erases the device.
            </label>
          </template>

          <div class="flex justify-end gap-2 mt-1">
            <Btn type="button" @click="closeDialog">Cancel</Btn>
            <Btn type="submit" :variant="diskDialog.mode === 'format' ? 'danger' : 'primary'">
              <LIcon :name="diskDialog.mode === 'format' ? 'eraser' : 'plug'" />
              {{ diskDialog.mode === 'format' ? 'Format' : 'Mount' }}
            </Btn>
          </div>
        </form>
      </div>
    </div>
  </section>
</template>
