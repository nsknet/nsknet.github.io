import { MOCK, appState, addToast, confirmThen, runJobAction, fetchSamples, openNetworkDialog } from '../store.js';

const { computed, reactive, ref, onMounted, onUnmounted, nextTick } = Vue;

const FS_TYPES = ['ext4', 'xfs', 'btrfs', 'vfat', 'ntfs', 'ext3', 'ext2'];

export const System = {
  name: 'ScreenSystem',
  setup() {
    const swapSize = ref(4);

    // ── Disks ──────────────────────────────────────────────────────────────────
    // Flatten the nested disk tree into rows, tagging each with a depth level so
    // partitions render indented under their parent disk.
    const diskRows = computed(() => {
      const out = [];
      const walk = (node, level) => {
        out.push({ ...node, level });
        (node.children || []).forEach((c) => walk(c, level + 1));
      };
      (MOCK.disks || []).forEach((d) => walk(d, 0));
      return out;
    });

    // A row is actionable (mount/unmount/format) when it is a leaf block device
    // under /dev with no partitions of its own.
    function actionable(d) {
      return (d.children || []).length === 0
        && (d.path || '').startsWith('/dev/')
        && ['part', 'disk', 'lvm', 'crypt', 'rom'].includes(d.type);
    }

    function usagePct(d) {
      return d.use_percent != null ? d.use_percent : null;
    }
    function barClass(pct) {
      return pct > 85 ? 'bar-danger' : pct > 70 ? 'bar-warn' : 'bar-ok';
    }
    function fmtGB(v) {
      return v != null ? `${v.toFixed(1)} GB` : '—';
    }

    // Mount / format share one dialog, switched by `mode`.
    const diskDialog = reactive({ open: false, mode: 'mount', device: '', name: '', mountpoint: '', persist: true, fstype: 'ext4', label: '', ack: false });

    function openMount(d) {
      Object.assign(diskDialog, {
        open: true, mode: 'mount', device: d.path, name: d.name,
        mountpoint: `/mnt/${d.name}`, persist: true, fstype: 'ext4', label: '', ack: false,
      });
    }
    function openFormat(d) {
      Object.assign(diskDialog, {
        open: true, mode: 'format', device: d.path, name: d.name,
        mountpoint: '', persist: true, fstype: d.fstype && FS_TYPES.includes(d.fstype) ? d.fstype : 'ext4',
        label: d.label || '', ack: false,
      });
    }
    function closeDialog() { diskDialog.open = false; }

    function submitDialog(e) {
      if (e) e.preventDefault();
      if (diskDialog.mode === 'mount') {
        const mp = diskDialog.mountpoint.trim();
        if (!mp.startsWith('/')) { addToast({ t: 'Enter an absolute mount point', k: 'warn' }); return; }
        closeDialog();
        runJobAction('/api/v1/system/disk/mount',
          { device: diskDialog.device, mountpoint: mp, persist: diskDialog.persist },
          `Mount ${diskDialog.device} → ${mp}`);
      } else {
        if (!diskDialog.ack) { addToast({ t: 'Confirm the erase warning first', k: 'warn' }); return; }
        const dev = diskDialog.device, fs = diskDialog.fstype;
        closeDialog();
        runJobAction('/api/v1/system/disk/format',
          { device: dev, fstype: fs, label: diskDialog.label.trim() },
          `Format ${dev} as ${fs}`);
      }
    }

    function unmount(d) {
      confirmThen(
        'Unmount partition?',
        `This unmounts ${d.path} from ${d.mountpoint} and removes its /etc/fstab entry so it won't remount on boot.`,
        () => runJobAction('/api/v1/system/disk/unmount',
          { target: d.mountpoint || d.path, remove_fstab: true },
          `Unmount ${d.mountpoint || d.path}`)
      );
    }

    const statCards = computed(() => {
      const h = MOCK.host;
      return [
        {
          label: 'CPU', icon: 'cpu',
          value: h.cpu.usage, unit: '%',
          sub: `${h.cpu.cores} cores · ${h.cpu.threads} threads`,
          rows: [['1m load', h.cpu.load[0]], ['5m load', h.cpu.load[1]], ['15m load', h.cpu.load[2]]],
        },
        {
          label: 'Memory', icon: 'memory-stick',
          value: h.ram.used.toFixed(1), unit: `/ ${h.ram.total.toFixed(1)} GB`,
          sub: `${h.ram.pct}% used`,
          bar: { pct: h.ram.pct, cls: h.ram.pct > 85 ? 'bar-danger' : h.ram.pct > 70 ? 'bar-warn' : 'bar-ok' },
          rows: [['Free', (h.ram.total - h.ram.used).toFixed(1) + ' GB'], ['Buffers', '0.8 GB']],
        },
        {
          label: 'Disk /', icon: 'hard-drive',
          value: h.disk.used.toFixed(1), unit: `/ ${h.disk.total.toFixed(1)} GB`,
          sub: `${h.disk.pct}% used`,
          bar: { pct: h.disk.pct, cls: h.disk.pct > 85 ? 'bar-danger' : h.disk.pct > 70 ? 'bar-warn' : 'bar-ok' },
          alert: h.disk.pct > 85 ? { k: 'danger', t: 'Critical: above 85%' } : h.disk.pct > 70 ? { k: 'warn', t: 'Caution: above 70%' } : null,
        },
        {
          label: 'Swap', icon: 'layers',
          value: h.swap ? h.swap.used.toFixed(1) : null, unit: h.swap ? `/ ${h.swap.total.toFixed(1)} GB` : '',
          sub: h.swap ? `${h.swap.pct}% used · /swapfile` : 'No swap configured',
          bar: h.swap ? { pct: h.swap.pct, cls: 'bar-ok' } : null,
        },
      ];
    });

    const hostRows = computed(() => {
      const h = MOCK.host;
      return [
        { k: 'Hostname',     v: h.hostname, mono: true },
        { k: 'Distribution', v: h.distro,   mono: false },
        { k: 'Kernel',       v: h.kernel,   mono: true },
        { k: 'Timezone',     v: h.timezone, mono: true },
        { k: 'Uptime',       v: h.uptime,   mono: false },
        { k: 'Boot time',    v: new Date(Date.now() - 14*24*60*60*1000).toLocaleString(), mono: false },
      ];
    });

    async function refresh() {
      await fetchSamples();
      addToast({ t: 'Diagnostics refreshed', k: 'info' });
    }

    function setTimezone(tz, label) {
      runJobAction('/api/v1/system/set-timezone', { tz }, `Set timezone — ${label}`);
    }

    function installUtils() {
      runJobAction('/api/v1/system/install-utils', {}, 'Installing common utilities');
    }

    function installSwap() {
      confirmThen(
        'Replace swap?',
        'This disables and rewrites /swapfile. Existing swap data is lost.',
        () => runJobAction('/api/v1/system/swap', { size_gb: swapSize.value }, 'Provisioning swap')
      );
    }

    function editNetwork(n) {
      openNetworkDialog(n.iface, n, (payload) => {
        const title = payload.method === 'dhcp'
          ? `Set ${payload.iface} → DHCP`
          : `Set ${payload.iface} → ${payload.address}`;
        runJobAction('/api/v1/system/set-network', payload, title);
      });
    }

    function onKeydown(e) { if (e.key === 'Escape') diskDialog.open = false; }
    onMounted(() => { document.addEventListener('keydown', onKeydown); nextTick(() => window.lucide?.createIcons()); });
    onUnmounted(() => document.removeEventListener('keydown', onKeydown));

    return {
      MOCK, appState, statCards, hostRows, swapSize, refresh, setTimezone, installUtils, installSwap, editNetwork,
      FS_TYPES, diskRows, actionable, usagePct, barClass, fmtGB,
      diskDialog, openMount, openFormat, closeDialog, submitDialog, unmount,
    };
  },
  template: `
    <section>
      <div class="flex items-end justify-between gap-6 mb-6">
        <div>
          <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">System</h1>
          <div class="text-sm-var text-c-tx2">Host machine diagnostics and global configuration.</div>
        </div>
        <div class="flex gap-2">
          <btn @click="refresh">
            <l-icon name="refresh-cw" /> Refresh diagnostics
          </btn>
        </div>
      </div>

      <div class="grid grid-cols-4 gap-3">
        <div v-for="c in statCards" :key="c.label" class="bg-c-bg border border-c-border rounded-theme overflow-hidden p-[18px]">
          <div class="flex items-center justify-between gap-3 mb-2.5">
            <div class="flex items-center gap-2 text-sm-var font-medium text-c-tx">
              <l-icon :name="c.icon" is="width:15px;height:15px;color:var(--text-2)" />
              {{ c.label }}
            </div>
            <badge v-if="c.alert" :tone="c.alert.k" dot>{{ c.alert.t }}</badge>
          </div>
          <div class="text-[22px] font-semibold tracking-[-0.02em] tabular-nums">
            <template v-if="c.value !== null">{{ c.value }}<span v-if="c.unit" class="text-[13px] text-c-tx3 font-medium ml-0.5"> {{ c.unit }}</span></template>
            <span v-else class="text-c-tx3">disabled</span>
          </div>
          <div class="text-xs-var text-c-tx3 mono mt-1">{{ c.sub }}</div>
          <div v-if="c.bar" :class="['bar', c.bar.cls]"><span :style="{ width: c.bar.pct + '%' }"></span></div>
          <div v-if="c.rows" class="grid grid-cols-2 gap-y-2.5 gap-x-4 text-xs-var mt-3.5">
            <div v-for="r in c.rows" :key="r[0]">
              <div class="text-c-tx3 uppercase tracking-[0.06em]">{{ r[0] }}</div>
              <div class="text-c-tx mono text-sm-var mt-0.5">{{ r[1] }}</div>
            </div>
          </div>
        </div>
      </div>

      <div class="grid gap-3 mt-4" style="grid-template-columns:2fr 1fr">
        <div class="flex flex-col gap-3">
          <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
            <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border"><h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Host</h3><span class="text-xs-var text-c-tx3 mono">{{ MOCK.host.kernel }}</span></div>
            <div class="p-4">
              <dl class="grid gap-y-2 gap-x-4 text-sm-var m-0" style="grid-template-columns:140px 1fr">
                <template v-for="r in hostRows" :key="r.k">
                  <dt class="text-c-tx2">{{ r.k }}</dt>
                  <dd class="m-0 tabular-nums" :class="r.mono ? 'mono text-xs-var' : ''">{{ r.v }}</dd>
                </template>
              </dl>
            </div>
          </div>
          <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
            <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border"><h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Network interfaces</h3></div>
            <table class="tbl">
              <thead><tr><th>Interface</th><th>IP address</th><th>Source</th><th>Status</th><th></th></tr></thead>
              <tbody>
                <tr v-for="n in MOCK.host.network" :key="n.iface">
                  <td class="mono"><strong>{{ n.iface }}</strong></td>
                  <td class="mono muted">{{ n.cidr || n.ip }}</td>
                  <td>
                    <badge v-if="n.method === 'dhcp'" tone="info">DHCP</badge>
                    <badge v-else-if="n.method === 'static'" tone="muted">Static</badge>
                    <badge v-else tone="muted">{{ n.ip.includes(':') ? 'IPv6' : 'IPv4' }}</badge>
                  </td>
                  <td><badge tone="ok" dot>up</badge></td>
                  <td class="text-right">
                    <btn v-if="!n.ip.includes(':')" sm @click="editNetwork(n)">
                      <l-icon name="pencil" /> Edit
                    </btn>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden self-start">
          <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border"><h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Quick actions</h3></div>

          <div class="px-4 py-3.5 border-b border-c-border">
            <div class="flex items-center justify-between gap-3 mb-2">
              <div class="flex items-center gap-2 text-sm-var font-medium">
                <l-icon name="clock" is="width:14px;height:14px;color:var(--text-2)" />Timezone
              </div>
              <span class="text-c-tx3 mono text-xs-var">{{ MOCK.host.timezone }}</span>
            </div>
            <div class="text-xs-var text-c-tx2 mb-2.5">Apply a preset timezone. Updates <span class="mono">/etc/timezone</span>.</div>
            <div class="flex gap-1.5 flex-wrap">
              <btn sm @click="setTimezone('Asia/Ho_Chi_Minh', 'GMT+7 (Vietnam)')">GMT+7 (Vietnam)</btn>
              <btn sm @click="setTimezone('America/New_York', 'EST (US East)')">EST (US East)</btn>
            </div>
          </div>

          <div class="px-4 py-3.5 border-b border-c-border">
            <div class="flex items-center gap-2 text-sm-var font-medium mb-2">
              <l-icon name="package" is="width:14px;height:14px;color:var(--text-2)" />Common utilities
            </div>
            <div class="text-xs-var text-c-tx2 mb-2.5">Install <span class="mono">wget</span>, <span class="mono">curl</span>, <span class="mono">htop</span>, <span class="mono">git</span>, <span class="mono">unzip</span>, <span class="mono">tmux</span>.</div>
            <div class="flex gap-1.5 flex-wrap">
              <btn sm @click="installUtils">
                <l-icon name="download" /> Install utilities
              </btn>
            </div>
          </div>

          <div class="px-4 py-3.5">
            <div class="flex items-center justify-between gap-3 mb-2">
              <div class="flex items-center gap-2 text-sm-var font-medium">
                <l-icon name="memory-stick" is="width:14px;height:14px;color:var(--text-2)" />Virtual RAM (swap)
              </div>
              <span class="text-c-tx3 mono text-xs-var">/swapfile · 4.0 GB</span>
            </div>
            <div class="text-xs-var text-c-tx2 mb-2.5">Replaces the existing swapfile and updates <span class="mono">/etc/fstab</span>.</div>
            <div class="flex gap-1.5 flex-wrap items-center">
              <label class="text-xs-var text-c-tx2">Size</label>
              <input type="number" class="input mono w-[70px] h-7" v-model="swapSize" min="1" max="64" />
              <label class="text-xs-var text-c-tx2">GB</label>
              <btn sm @click="installSwap">
                <l-icon name="hard-drive-download" /> Install
              </btn>
            </div>
          </div>
        </div>
      </div>

      <!-- Disks -->
      <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden mt-4">
        <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
          <div class="flex items-center gap-2.5">
            <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Disks</h3>
            <span class="text-xs-var text-c-tx3 mono">{{ diskRows.length }} devices</span>
          </div>
          <span class="text-xs-var text-c-tx3 mono">block devices · partitions · mount points</span>
        </div>
        <table class="tbl">
          <thead><tr>
            <th>Device</th>
            <th>Type</th>
            <th>Size</th>
            <th>Filesystem</th>
            <th>Mount point</th>
            <th style="width:180px">Usage</th>
            <th></th>
          </tr></thead>
          <tbody>
            <tr v-if="appState.fetching.disks && !diskRows.length">
              <td colspan="7" class="muted" style="text-align:center; padding:32px 0">
                <span class="inline-flex items-center gap-2 text-c-tx2">
                  <svg class="animate-spin h-3.5 w-3.5 text-c-accent" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                  </svg>
                  Loading disks…
                </span>
              </td>
            </tr>
            <tr v-else-if="!diskRows.length">
              <td colspan="7" class="muted" style="text-align:center; padding:32px 0">
                No block devices reported. <span class="mono">lsblk</span> may be unavailable on this host.
              </td>
            </tr>
            <tr v-for="d in diskRows" :key="d.path + ':' + d.mountpoint">
              <td>
                <span class="inline-flex items-center gap-2" :style="{ paddingLeft: (d.level * 18) + 'px' }">
                  <l-icon :name="d.level === 0 ? 'hard-drive' : 'box'" is="width:14px;height:14px;color:var(--text-3)" />
                  <span class="mono" :class="d.level === 0 ? 'font-semibold' : ''">{{ d.name }}</span>
                </span>
                <div v-if="d.model || d.label" class="text-xs-var text-c-tx3 mt-0.5" :style="{ paddingLeft: (d.level * 18 + 22) + 'px' }">
                  <span v-if="d.label" class="mono">{{ d.label }}</span><span v-if="d.label && d.model"> · </span>{{ d.model }}
                </div>
              </td>
              <td><badge tone="muted">{{ d.type }}</badge><span v-if="d.removable" class="ml-1"><badge tone="info">removable</badge></span></td>
              <td class="mono muted tabular-nums">{{ d.size_gb ? d.size_gb.toFixed(1) + ' GB' : '—' }}</td>
              <td class="mono muted">{{ d.fstype || '—' }}</td>
              <td class="mono muted">{{ d.mountpoint || '—' }}</td>
              <td>
                <template v-if="usagePct(d) != null">
                  <div class="text-xs-var text-c-tx2 tabular-nums">{{ fmtGB(d.used_gb) }} / {{ fmtGB(d.size_gb) }} · {{ usagePct(d) }}%</div>
                  <div :class="['bar', barClass(usagePct(d))]"><span :style="{ width: usagePct(d) + '%' }"></span></div>
                </template>
                <span v-else class="text-c-tx3">—</span>
              </td>
              <td class="text-right whitespace-nowrap">
                <template v-if="actionable(d)">
                  <btn v-if="d.mountpoint" sm @click="unmount(d)" title="Unmount">
                    <l-icon name="eject" /> Unmount
                  </btn>
                  <btn v-else-if="d.fstype" sm @click="openMount(d)" title="Mount">
                    <l-icon name="plug" /> Mount
                  </btn>
                  <btn v-if="!d.mountpoint" variant="danger" sm class="ml-1.5" @click="openFormat(d)" title="Format">
                    <l-icon name="eraser" /> Format
                  </btn>
                </template>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- Mount / format dialog -->
      <div v-if="diskDialog.open" class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade" @click.self="closeDialog">
        <div class="w-full max-w-[460px] bg-c-bg border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop" role="dialog" aria-modal="true">
          <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
            <div class="w-7 h-7 rounded-[7px] grid place-items-center" :class="diskDialog.mode === 'format' ? 'bg-c-dngsoft' : 'bg-c-subtle'">
              <l-icon :name="diskDialog.mode === 'format' ? 'eraser' : 'plug'" is="width:14px;height:14px" />
            </div>
            <div>
              <div class="font-semibold text-sm-var">{{ diskDialog.mode === 'format' ? 'Format device' : 'Mount device' }}</div>
              <div class="text-xs-var text-c-tx2 mono">{{ diskDialog.device }}</div>
            </div>
            <btn variant="ghost" sm square class="ml-auto" @click="closeDialog" aria-label="Close">
              <l-icon name="x" />
            </btn>
          </div>

          <form class="p-4 flex flex-col gap-3.5" @submit="submitDialog">
            <template v-if="diskDialog.mode === 'mount'">
              <div class="flex flex-col gap-1.5">
                <label for="dk-mp" class="text-sm-var font-medium text-c-tx">Mount point</label>
                <input id="dk-mp" class="input mono" placeholder="/mnt/data" v-model="diskDialog.mountpoint" autofocus />
                <div class="text-xs-var text-c-tx2">Absolute path. Created if it does not exist.</div>
              </div>
              <label class="flex items-center gap-2 text-sm-var text-c-tx cursor-pointer">
                <input type="checkbox" v-model="diskDialog.persist" />
                Persist in <span class="mono">/etc/fstab</span> (auto-mount on boot)
              </label>
            </template>

            <template v-else>
              <div class="flex items-center gap-2.5 px-3.5 py-2.5 rounded-theme bg-c-dngsoft text-c-danger text-sm-var border border-transparent">
                <l-icon name="alert-triangle" is="width:16px;height:16px;flex-shrink:0" />
                <div><strong>This erases all data</strong> on {{ diskDialog.device }}. This cannot be undone.</div>
              </div>
              <div class="flex flex-col gap-1.5">
                <label for="dk-fs" class="text-sm-var font-medium text-c-tx">Filesystem</label>
                <select id="dk-fs" class="input" v-model="diskDialog.fstype">
                  <option v-for="f in FS_TYPES" :key="f" :value="f">{{ f }}</option>
                </select>
              </div>
              <div class="flex flex-col gap-1.5">
                <label for="dk-label" class="text-sm-var font-medium text-c-tx">Label <span class="text-c-tx3 font-normal">· optional</span></label>
                <input id="dk-label" class="input mono" placeholder="data" v-model="diskDialog.label" />
              </div>
              <label class="flex items-center gap-2 text-sm-var text-c-tx cursor-pointer">
                <input type="checkbox" v-model="diskDialog.ack" />
                I understand this permanently erases the device.
              </label>
            </template>

            <div class="flex justify-end gap-2 mt-1">
              <btn type="button" @click="closeDialog">Cancel</btn>
              <btn type="submit" :variant="diskDialog.mode === 'format' ? 'danger' : 'primary'">
                <l-icon :name="diskDialog.mode === 'format' ? 'eraser' : 'plug'" />
                {{ diskDialog.mode === 'format' ? 'Format' : 'Mount' }}
              </btn>
            </div>
          </form>
        </div>
      </div>
    </section>
  `,
};
