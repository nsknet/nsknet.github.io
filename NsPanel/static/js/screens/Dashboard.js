import { MOCK, appState, navigate, openSite, addToast, fetchSamples } from '../store.js';

const { computed, onMounted, nextTick } = Vue;

export const Dashboard = {
  name: 'ScreenDashboard',
  setup() {
    const statCards = computed(() => {
      const h  = MOCK.host;
      return [
        {
          label: 'CPU', icon: 'cpu',
          value: h.cpu.usage, unit: '%',
          sub: `${h.cpu.cores} cores · load ${h.cpu.load.join(' / ')}`,
        },
        {
          label: 'Memory', icon: 'memory-stick',
          value: h.ram.used.toFixed(1), unit: `/ ${h.ram.total.toFixed(1)} GB`,
          sub: `${h.ram.pct}% used`,
          bar: { pct: h.ram.pct, cls: h.ram.pct > 85 ? 'bar-danger' : h.ram.pct > 70 ? 'bar-warn' : 'bar-ok' },
        },
        {
          label: 'Disk', icon: 'hard-drive',
          value: h.disk.used.toFixed(1), unit: `/ ${h.disk.total.toFixed(1)} GB`,
          sub: `${h.disk.pct}% used · /`,
          bar: { pct: h.disk.pct, cls: h.disk.pct > 85 ? 'bar-danger' : h.disk.pct > 70 ? 'bar-warn' : 'bar-ok' },
        },
        {
          label: 'Uptime', icon: 'clock',
          value: h.uptime.split(',')[0], unit: '',
          sub: h.uptime.split(',').slice(1).join(',').trim() + ' · ' + h.kernel.split(' ')[1],
        },
      ];
    });

    const dashboardSites = computed(() => MOCK.sites.slice(0, 5));

    async function refresh() {
      try {
        await fetchSamples();
        addToast({ t: 'Stats refreshed', k: 'info' });
      } catch (e) {
        addToast({ t: 'Failed to refresh stats', k: 'danger' });
      }
    }

    onMounted(() => nextTick(() => window.lucide?.createIcons()));

    return { MOCK, statCards, dashboardSites, navigate, openSite, refresh };
  },
  template: `
    <section>
      <div class="flex items-end justify-between gap-6 mb-6">
        <div>
          <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">Overview</h1>
          <div class="text-sm-var text-c-tx2 mono">{{ MOCK.host.distro }} · {{ MOCK.host.kernel }}</div>
        </div>
        <div class="flex gap-2">
          <btn @click="refresh">
            <l-icon name="refresh-cw" /> Refresh
          </btn>
          <btn variant="primary" @click="navigate('create-site')">
            <l-icon name="plus" /> Create site
          </btn>
        </div>
      </div>

      <div class="grid grid-cols-4 gap-3">
        <div v-for="card in statCards" :key="card.label" class="bg-c-bg border border-c-border rounded-theme overflow-hidden py-4 px-[18px]">
          <div class="flex items-center justify-between text-c-tx2 text-xs-var uppercase tracking-[0.06em] font-medium">
            {{ card.label }}
            <l-icon :name="card.icon" is="width:14px;height:14px;color:var(--text-3)" />
          </div>
          <div class="text-[28px] font-semibold tracking-[-0.03em] mt-2 tabular-nums">{{ card.value }}<span v-if="card.unit" class="text-sm text-c-tx3 font-medium ml-0.5"> {{ card.unit }}</span></div>
          <div class="mt-1 text-xs-var text-c-tx3 mono">{{ card.sub }}</div>
          <div v-if="card.bar" :class="['bar', card.bar.cls]"><span :style="{ width: card.bar.pct + '%' }"></span></div>

        </div>
      </div>

      <div class="text-xs-var text-c-tx3 uppercase tracking-[0.08em] font-medium mt-6 mb-2.5">
        Sites <span class="text-c-tx3">· {{ MOCK.sites.length }} total</span>
      </div>
      <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
        <table class="tbl">
          <thead><tr>
            <th>Name</th><th>Type</th><th>Access</th><th>Status</th>
            <th class="num">PID</th><th>Mem</th><th>CPU</th><th>Modified</th><th></th>
          </tr></thead>
          <tbody>
            <tr v-for="s in dashboardSites" :key="s.slug" class="row-click" @click="openSite(s.slug)">
              <td><strong>{{ s.name }}</strong></td>
              <td><type-chip :type="s.type" /></td>
              <td class="mono muted">{{ s.access }}</td>
              <td><status-badge :status="s.status" /></td>
              <td class="num muted">{{ s.pid || '—' }}</td>
              <td class="num">{{ s.mem != null ? s.mem.toFixed(1) : '—' }}</td>
              <td class="num">{{ s.cpu != null ? s.cpu.toFixed(1) + '%' : '—' }}</td>
              <td class="muted">{{ s.modified }}</td>
              <td><l-icon name="chevron-right" is="width:14px;height:14px;color:var(--text-3)" /></td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="text-xs-var text-c-tx3 uppercase tracking-[0.08em] font-medium mt-6 mb-2.5">Installed tools</div>
      <div class="grid gap-2.5" style="grid-template-columns:repeat(auto-fill,minmax(240px,1fr))">
        <div v-for="t in MOCK.tools" :key="t.id" class="flex flex-col gap-2.5 p-3.5 bg-c-bg border border-c-border rounded-theme cursor-pointer transition-colors hover:border-c-bstrong hover:bg-c-elev" @click="navigate('tools')">
          <div class="flex items-center gap-2">
            <div class="w-7 h-7 rounded-md bg-c-subtle flex items-center justify-center shrink-0 overflow-hidden p-1 select-none">
              <img v-if="t.logo.endsWith('.png')" :src="t.logo" class="w-full h-full object-contain" />
              <span v-else class="text-[11px] font-bold mono" :style="{ color: t.color }">{{ t.logo }}</span>
            </div>
            <div class="flex-1"></div>
            <status-badge :status="t.state" />
          </div>
          <div>
            <div class="font-medium text-sm-var">{{ t.name }}</div>
            <div class="mono text-xs-var text-c-tx3">{{ t.version || 'not installed' }}</div>
          </div>
        </div>
      </div>
    </section>
  `,
};
