<script setup lang="ts">
/** Overview: host metrics, the newest sites, and every tool's state. */
import { storeToRefs } from 'pinia';
import { computed } from 'vue';
import { useRouter } from 'vue-router';

import Btn from '@/components/ui/Btn.vue';
import LIcon from '@/components/ui/LIcon.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import TypeChip from '@/components/ui/TypeChip.vue';
import { useReload } from '@/composables/useScreenData';
import { useSitesStore } from '@/stores/sites';
import { useSystemStore } from '@/stores/system';
import { useToolsStore } from '@/stores/tools';
import { useUiStore } from '@/stores/ui';

const router = useRouter();
const ui = useUiStore();
const reload = useReload();
const { host } = storeToRefs(useSystemStore());
const { sites } = storeToRefs(useSitesStore());
const { tools } = storeToRefs(useToolsStore());

function barClass(pct: number): string {
  if (pct > 85) return 'bar-danger';
  if (pct > 70) return 'bar-warn';
  return 'bar-ok';
}

const statCards = computed(() => {
  const h = host.value;
  const [uptimeHead, ...uptimeRest] = h.uptime.split(',');
  return [
    {
      label: 'CPU',
      icon: 'cpu',
      value: String(h.cpu.usage),
      unit: '%',
      sub: `${h.cpu.cores} cores · load ${h.cpu.load.join(' / ')}`,
      bar: null as { pct: number; cls: string } | null,
    },
    {
      label: 'Memory',
      icon: 'memory-stick',
      value: h.ram.used.toFixed(1),
      unit: `/ ${h.ram.total.toFixed(1)} GB`,
      sub: `${h.ram.pct}% used`,
      bar: { pct: h.ram.pct, cls: barClass(h.ram.pct) },
    },
    {
      label: 'Disk',
      icon: 'hard-drive',
      value: h.disk.used.toFixed(1),
      unit: `/ ${h.disk.total.toFixed(1)} GB`,
      sub: `${h.disk.pct}% used · /`,
      bar: { pct: h.disk.pct, cls: barClass(h.disk.pct) },
    },
    {
      label: 'Uptime',
      icon: 'clock',
      value: uptimeHead,
      unit: '',
      sub: `${uptimeRest.join(',').trim()} · ${h.kernel.split(' ')[1] ?? ''}`,
      bar: null,
    },
  ];
});

const recentSites = computed(() => sites.value.slice(0, 5));

async function refresh(): Promise<void> {
  await reload();
  ui.addToast({ t: 'Stats refreshed', k: 'info' });
}
</script>

<template>
  <section>
    <div class="flex items-end justify-between gap-6 mb-6">
      <div>
        <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">Overview</h1>
        <div class="text-sm-var text-c-tx2 mono">{{ host.distro }} · {{ host.kernel }}</div>
      </div>
      <div class="flex gap-2">
        <Btn @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
        <Btn variant="primary" @click="router.push('/sites/new')">
          <LIcon name="plus" /> Create site
        </Btn>
      </div>
    </div>

    <div class="grid grid-cols-4 gap-3">
      <div
        v-for="card in statCards"
        :key="card.label"
        class="bg-c-bg border border-c-border rounded-theme overflow-hidden py-4 px-[18px]"
      >
        <div
          class="flex items-center justify-between text-c-tx2 text-xs-var uppercase tracking-[0.06em] font-medium"
        >
          {{ card.label }}
          <LIcon :name="card.icon" is="width:14px;height:14px;color:var(--text-3)" />
        </div>
        <div class="text-[28px] font-semibold tracking-[-0.03em] mt-2 tabular-nums">
          {{ card.value
          }}<span v-if="card.unit" class="text-sm text-c-tx3 font-medium ml-0.5">
            {{ card.unit }}</span
          >
        </div>
        <div class="mt-1 text-xs-var text-c-tx3 mono">{{ card.sub }}</div>
        <div v-if="card.bar" :class="['bar', card.bar.cls]">
          <span :style="{ width: `${card.bar.pct}%` }"></span>
        </div>
      </div>
    </div>

    <div class="text-xs-var text-c-tx3 uppercase tracking-[0.08em] font-medium mt-6 mb-2.5">
      Sites <span class="text-c-tx3">· {{ sites.length }} total</span>
    </div>
    <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
      <table class="tbl">
        <thead>
          <tr>
            <th>Name</th>
            <th>Type</th>
            <th>Access</th>
            <th>Status</th>
            <th class="num">PID</th>
            <th>Mem</th>
            <th>CPU</th>
            <th>Modified</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="!recentSites.length">
            <td colspan="9" class="muted" style="text-align: center; padding: 24px 0">
              No sites yet.
            </td>
          </tr>
          <tr
            v-for="site in recentSites"
            :key="site.slug"
            class="row-click"
            @click="router.push(`/sites/${site.slug}`)"
          >
            <td>
              <strong>{{ site.name }}</strong>
            </td>
            <td><TypeChip :type="site.type" /></td>
            <td class="mono muted">{{ site.access }}</td>
            <td><StatusBadge :status="site.status" /></td>
            <td class="num muted">{{ site.pid || '—' }}</td>
            <td class="num">{{ site.mem != null ? site.mem.toFixed(1) : '—' }}</td>
            <td class="num">{{ site.cpu != null ? `${site.cpu.toFixed(1)}%` : '—' }}</td>
            <td class="muted">{{ site.modified }}</td>
            <td><LIcon name="chevron-right" is="width:14px;height:14px;color:var(--text-3)" /></td>
          </tr>
        </tbody>
      </table>
    </div>

    <div class="text-xs-var text-c-tx3 uppercase tracking-[0.08em] font-medium mt-6 mb-2.5">
      Installed tools
    </div>
    <div class="grid gap-2.5" style="grid-template-columns: repeat(auto-fill, minmax(240px, 1fr))">
      <div
        v-for="tool in tools"
        :key="tool.id"
        class="flex flex-col gap-2.5 p-3.5 bg-c-bg border border-c-border rounded-theme cursor-pointer transition-colors hover:border-c-bstrong hover:bg-c-elev"
        @click="router.push('/tools')"
      >
        <div class="flex items-center gap-2">
          <div
            class="w-7 h-7 rounded-md bg-c-subtle flex items-center justify-center shrink-0 overflow-hidden p-1 select-none"
          >
            <img
              v-if="tool.logo.endsWith('.png')"
              :src="tool.logo"
              :alt="tool.name"
              class="w-full h-full object-contain"
            />
            <span v-else class="text-[11px] font-bold mono" :style="{ color: tool.color }">{{
              tool.logo
            }}</span>
          </div>
          <div class="flex-1"></div>
          <StatusBadge :status="tool.state" />
        </div>
        <div>
          <div class="font-medium text-sm-var">{{ tool.name }}</div>
          <div class="mono text-xs-var text-c-tx3">{{ tool.version || 'not installed' }}</div>
        </div>
      </div>
    </div>
  </section>
</template>
