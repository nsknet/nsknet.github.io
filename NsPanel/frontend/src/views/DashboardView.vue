<script setup lang="ts">
/** Overview: host metrics, the newest sites, and the installed tools' state. */
import { storeToRefs } from 'pinia';
import { computed, onMounted, onUnmounted, ref, watch } from 'vue';
import { RouterLink, useRouter } from 'vue-router';

import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import SectionTitle from '@/components/ui/SectionTitle.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import ToolLogo from '@/components/ui/ToolLogo.vue';
import TypeChip from '@/components/ui/TypeChip.vue';
import { useReload } from '@/composables/useScreenData';
import { useSitesStore } from '@/stores/sites';
import { useSystemStore } from '@/stores/system';
import { useToolsStore } from '@/stores/tools';
import { useUiStore } from '@/stores/ui';

const router = useRouter();
const ui = useUiStore();
const reload = useReload();
const system = useSystemStore();
const { host } = storeToRefs(system);
const { sites } = storeToRefs(useSitesStore());
const { tools } = storeToRefs(useToolsStore());

/** Samples kept for the CPU / memory sparklines, and how often to take one. */
const HISTORY = 30;
const SAMPLE_MS = 5000;

const cpuHistory = ref<number[]>([]);
const ramHistory = ref<number[]>([]);

watch(
  host,
  (h) => {
    if (!h.hostname) return;
    cpuHistory.value = [...cpuHistory.value, h.cpu.usage].slice(-HISTORY);
    ramHistory.value = [...ramHistory.value, h.ram.pct].slice(-HISTORY);
  },
  { immediate: true },
);

let sampler: ReturnType<typeof setInterval> | undefined;

onMounted(() => {
  sampler = setInterval(async () => {
    if (document.hidden) return;
    const before = host.value;
    await system.load();
    // A failed load keeps the old object and toasts; stop rather than toast every tick.
    if (host.value === before) clearInterval(sampler);
  }, SAMPLE_MS);
});
onUnmounted(() => clearInterval(sampler));

/** SVG path pair (line + filled area) for a 0-100 series in a 100x32 box. */
function sparkPaths(values: number[]): { line: string; area: string } | null {
  if (values.length < 2) return null;
  const step = 100 / (values.length - 1);
  const points = values.map((v, i) => {
    const y = 31 - (Math.min(Math.max(v, 0), 100) / 100) * 30;
    return `${(i * step).toFixed(2)},${y.toFixed(2)}`;
  });
  const line = `M${points.join(' L')}`;
  return { line, area: `${line} L100,32 L0,32 Z` };
}

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
      spark: sparkPaths(cpuHistory.value),
    },
    {
      label: 'Memory',
      icon: 'memory-stick',
      value: h.ram.used.toFixed(1),
      unit: `/ ${h.ram.total.toFixed(1)} GB`,
      sub: `${h.ram.pct}% used`,
      bar: { pct: h.ram.pct, cls: barClass(h.ram.pct) },
      spark: sparkPaths(ramHistory.value),
    },
    {
      label: 'Disk',
      icon: 'hard-drive',
      value: h.disk.used.toFixed(1),
      unit: `/ ${h.disk.total.toFixed(1)} GB`,
      sub: `${h.disk.pct}% used · /`,
      bar: { pct: h.disk.pct, cls: barClass(h.disk.pct) },
      spark: null,
    },
    {
      label: 'Uptime',
      icon: 'clock',
      value: uptimeHead,
      unit: '',
      sub: `${uptimeRest.join(',').trim()} · ${h.kernel.split(' ')[1] ?? ''}`,
      bar: null,
      spark: null,
    },
  ];
});

const recentSites = computed(() => sites.value.slice(0, 5));
const installedTools = computed(() => tools.value.filter((tool) => tool.installed));

async function refresh(): Promise<void> {
  await reload();
  ui.addToast({ t: 'Stats refreshed', k: 'info' });
}
</script>

<template>
  <section>
    <PageHeader title="Overview" :subtitle="`${host.distro} · ${host.kernel}`" mono>
      <Btn @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
      <Btn variant="primary" @click="router.push('/sites/new')">
        <LIcon name="plus" /> Create site
      </Btn>
    </PageHeader>

    <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-3">
      <Card v-for="card in statCards" :key="card.label" class="overflow-hidden py-4 px-[18px]">
        <div
          class="flex items-center justify-between text-c-tx2 text-xs-var uppercase tracking-[0.06em] font-medium"
        >
          {{ card.label }}
          <span class="w-7 h-7 rounded-md bg-c-subtle grid place-items-center">
            <LIcon :name="card.icon" is="width:14px;height:14px;color:var(--text-2)" />
          </span>
        </div>
        <div class="text-[28px] font-semibold tracking-[-0.03em] mt-1 tabular-nums">
          {{ card.value
          }}<span v-if="card.unit" class="text-sm text-c-tx3 font-medium ml-0.5">
            {{ card.unit }}</span
          >
        </div>
        <div class="mt-1 text-xs-var text-c-tx3 mono truncate">{{ card.sub }}</div>
        <svg v-if="card.spark" class="spark" viewBox="0 0 100 32" preserveAspectRatio="none">
          <path class="area" :d="card.spark.area" />
          <path :d="card.spark.line" />
        </svg>
        <div v-if="card.bar" :class="['bar', card.bar.cls]">
          <span :style="{ width: `${card.bar.pct}%` }"></span>
        </div>
      </Card>
    </div>

    <SectionTitle title="Recent sites" :count="sites.length">
      <RouterLink
        to="/sites"
        class="text-xs-var text-c-tx2 hover:text-c-tx no-underline inline-flex items-center gap-1"
        >View all <LIcon name="chevron-right" is="width:13px;height:13px"
      /></RouterLink>
    </SectionTitle>
    <Card class="overflow-x-auto">
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
            <td class="w-8">
              <LIcon
                name="chevron-right"
                class="row-hint"
                is="width:14px;height:14px;color:var(--text-2)"
              />
            </td>
          </tr>
        </tbody>
      </table>
    </Card>

    <SectionTitle title="Installed tools" :count="`${installedTools.length}/${tools.length}`">
      <RouterLink
        to="/tools"
        class="text-xs-var text-c-tx2 hover:text-c-tx no-underline inline-flex items-center gap-1"
        >Manage <LIcon name="chevron-right" is="width:13px;height:13px"
      /></RouterLink>
    </SectionTitle>
    <Card
      v-if="!installedTools.length"
      tone="muted"
      class="text-center py-8 text-sm-var text-c-tx2"
    >
      No tools installed yet.
      <RouterLink to="/tools" class="text-c-actx font-medium hover:underline">Browse tools</RouterLink>
    </Card>
    <div
      v-else
      class="grid gap-3"
      style="grid-template-columns: repeat(auto-fill, minmax(220px, 1fr))"
    >
      <Card
        v-for="tool in installedTools"
        :key="tool.id"
        :to="{ path: '/tools', query: { q: tool.name } }"
        :tone="tool.state === 'failed' ? 'danger' : 'default'"
        class="flex items-center gap-3 p-3.5"
      >
        <ToolLogo
          :logo="tool.logo"
          :name="tool.name"
          :color="tool.color"
          :dim="tool.state === 'stopped' || tool.state === 'inactive'"
        />
        <div class="flex-1 min-w-0">
          <div class="font-medium text-sm-var text-c-tx truncate" :title="tool.name">
            {{ tool.name }}
          </div>
          <div class="flex items-center justify-between gap-2 mt-1">
            <span class="mono text-xs-var text-c-tx3 truncate">{{ tool.version || '—' }}</span>
            <StatusBadge :status="tool.state" />
          </div>
        </div>
      </Card>
    </div>
  </section>
</template>
