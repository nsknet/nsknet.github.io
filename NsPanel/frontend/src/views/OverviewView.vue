<script setup lang="ts">
/** Overview: is the server healthy? Alerts first, then host usage, then the
 *  apps and tools at a glance. Polls lightly while the tab is visible. */
import { storeToRefs } from 'pinia';
import { computed, ref, watch } from 'vue';
import { RouterLink, useRouter } from 'vue-router';

import type { AppRow } from '@/api/apps';
import { buildApps } from '@/components/apps/appRows';
import Alert from '@/components/ui/Alert.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import CardHeader from '@/components/ui/CardHeader.vue';
import EmptyState from '@/components/ui/EmptyState.vue';
import ErrorState from '@/components/ui/ErrorState.vue';
import LIcon from '@/components/ui/LIcon.vue';
import MetricCard from '@/components/ui/MetricCard.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import ToolLogo from '@/components/ui/ToolLogo.vue';
import TypeChip from '@/components/ui/TypeChip.vue';
import { usePolling } from '@/composables/usePolling';
import { useRefresh } from '@/composables/useRefresh';
import { useDashboardStore } from '@/stores/dashboard';
import { useServicesStore } from '@/stores/services';
import { toSite } from '@/stores/sites';
import { ago } from '@/utils/format';

const router = useRouter();
const dashboardStore = useDashboardStore();
const { dashboard, loading, loaded, error } = storeToRefs(dashboardStore);
const servicesStore = useServicesStore();
const { services, loaded: servicesLoaded, error: servicesError } = storeToRefs(servicesStore);
const { refresh, refreshing } = useRefresh();

const POLL_MS = 10_000;
usePolling(() => dashboardStore.poll(), POLL_MS);

const stats = computed(() => dashboard.value.stats);
const alerts = computed(() => dashboard.value.alerts);

// ── CPU sparkline: one sample per dashboard load, last 30 kept ────────────
const SAMPLES = 30;
const cpuHistory = ref<number[]>([]);
watch(
  dashboard,
  (data) => {
    const cpu = data.stats.cpu_percent;
    if (typeof cpu === 'number') cpuHistory.value = [...cpuHistory.value, cpu].slice(-SAMPLES);
  },
  { immediate: true },
);

/** Line + filled area for a 0–100 series in a 100×32 box. */
const spark = computed(() => {
  const values = cpuHistory.value;
  if (values.length < 2) return null;
  const step = 100 / (values.length - 1);
  const points = values.map((v, i) => `${(i * step).toFixed(2)},${(31 - (Math.min(Math.max(v, 0), 100) / 100) * 30).toFixed(2)}`);
  const line = `M${points.join(' L')}`;
  return { line, area: `${line} L100,32 L0,32 Z` };
});

const fixed = (value: number | undefined, digits = 1) => (typeof value === 'number' ? value.toFixed(digits) : '—');

const metrics = computed(() => {
  const s = stats.value;
  return {
    cpu: { value: typeof s.cpu_percent === 'number' ? Math.round(s.cpu_percent) : '—', percent: s.cpu_percent ?? null },
    ram: {
      value: fixed(s.ram_used_gb),
      unit: `/ ${fixed(s.ram_total_gb)} GB`,
      percent: s.ram_percent ?? null,
      sub: typeof s.ram_percent === 'number' ? `${Math.round(s.ram_percent)}% used` : '',
    },
    disk: {
      value: fixed(s.disk_used_gb),
      unit: `/ ${fixed(s.disk_total_gb)} GB`,
      percent: s.disk_percent ?? null,
      sub: typeof s.disk_percent === 'number' ? `${Math.round(s.disk_percent)}% used` : '',
    },
    uptime: { value: s.uptime || '—', sub: [s.hostname, s.kernel].filter(Boolean).join(' · ') },
  };
});

// ── Apps ──────────────────────────────────────────────────────────────────
const apps = computed<AppRow[]>(() => buildApps(dashboard.value.sites.map(toSite), services.value));

const counts = computed(() => {
  const c = { up: 0, stopped: 0, failed: 0, other: 0 };
  for (const app of apps.value) c[app.state]++;
  return c;
});

const COUNT_TILES = [
  { key: 'up', label: 'Running', tone: 'text-c-ok' },
  { key: 'stopped', label: 'Stopped', tone: 'text-c-tx2' },
  { key: 'failed', label: 'Failed', tone: 'text-c-danger' },
] as const;

const recentApps = computed(() => [...apps.value].sort((a, b) => b.modifiedAt - a.modifiedAt).slice(0, 5));

// ── Tools ─────────────────────────────────────────────────────────────────
const installedTools = computed(() =>
  dashboard.value.tools
    .filter((tool) => tool.status.installed)
    .map((tool) => ({
      id: tool.module.name,
      name: tool.module.display_name,
      logo: tool.module.logo ? `/logo/${tool.module.logo}` : tool.module.name.slice(0, 2).toUpperCase(),
      version: tool.status.version?.match(/\d+\.\d+(?:\.\d+)*/)?.[0] ?? null,
      state: tool.status.service_state === 'n/a' ? 'installed' : tool.status.service_state,
    })),
);
const toolCount = computed(() => dashboard.value.tools.length);

const showSkeleton = computed(() => loading.value && !loaded.value);
</script>

<template>
  <section>
    <PageHeader title="Overview" subtitle="Health of this server at a glance.">
      <Btn :loading="refreshing" @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
      <Btn variant="primary" @click="router.push('/apps/new')"><LIcon name="plus" /> New app</Btn>
    </PageHeader>

    <!-- Nothing loaded and the call failed: say so instead of showing zeros. -->
    <Card v-if="error && !loaded">
      <ErrorState title="Could not load the overview" :message="error" :retrying="loading" @retry="refresh" />
    </Card>

    <div v-else class="flex flex-col gap-4">
      <Alert v-if="error" tone="warn" title="Showing the last data that loaded">
        {{ error }}
      </Alert>

      <!-- Alerts -->
      <Card v-if="showSkeleton" class="p-4" aria-busy="true" aria-label="Loading alerts">
        <div class="skeleton h-4 w-1/3"></div>
        <div class="skeleton h-3 w-1/2 mt-2"></div>
      </Card>
      <Card v-else-if="alerts.length" :tone="alerts.some((a) => a.level === 'danger') ? 'danger' : 'warn'">
        <CardHeader title="Needs attention" icon="bell">
          <span class="text-xs-var text-c-tx2 tabular-nums">{{ alerts.length }}</span>
        </CardHeader>
        <ul class="m-0 p-0 list-none divide-y divide-c-border">
          <li v-for="(alert, index) in alerts" :key="index" class="flex items-start gap-3 px-4 py-3">
            <LIcon
              :name="alert.level === 'danger' ? 'octagon-x' : 'triangle-alert'"
              :is="`width:16px;height:16px;flex-shrink:0;margin-top:2px;color:var(--${alert.level === 'danger' ? 'danger' : 'warn'})`"
            />
            <div class="flex-1 min-w-0">
              <div class="text-sm-var font-medium text-c-tx">
                <span class="sr-only">{{ alert.level === 'danger' ? 'Problem: ' : 'Warning: ' }}</span>{{ alert.title }}
              </div>
              <div v-if="alert.detail" class="text-xs-var text-c-tx2 mt-0.5 break-words">{{ alert.detail }}</div>
            </div>
            <RouterLink
              v-if="alert.link"
              :to="alert.link"
              class="shrink-0 inline-flex items-center gap-1 text-sm-var text-c-actx font-medium no-underline hover:underline underline-offset-2"
            >
              Open<span class="sr-only">: {{ alert.title }}</span>
              <LIcon name="chevron-right" is="width:14px;height:14px" />
            </RouterLink>
          </li>
        </ul>
      </Card>
      <Card v-else class="flex items-center gap-3 px-4 py-3.5">
        <span class="w-8 h-8 rounded-full bg-c-oksoft grid place-items-center shrink-0" aria-hidden="true">
          <LIcon name="circle-check" is="width:16px;height:16px;color:var(--ok)" />
        </span>
        <div role="status">
          <div class="text-sm-var font-medium">All good</div>
          <div class="text-xs-var text-c-tx2">Nothing needs your attention right now.</div>
        </div>
      </Card>

      <!-- Host usage -->
      <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-3">
        <MetricCard
          label="CPU"
          icon="cpu"
          :value="metrics.cpu.value"
          unit="%"
          :percent="metrics.cpu.percent"
          sub="Sampled every 10 s"
          :loading="showSkeleton"
        >
          <svg v-if="spark" class="spark !mt-1" viewBox="0 0 100 32" preserveAspectRatio="none" aria-hidden="true">
            <path class="area" :d="spark.area" />
            <path :d="spark.line" />
          </svg>
        </MetricCard>
        <MetricCard
          label="Memory"
          icon="memory-stick"
          :value="metrics.ram.value"
          :unit="metrics.ram.unit"
          :percent="metrics.ram.percent"
          :sub="metrics.ram.sub"
          :loading="showSkeleton"
        />
        <MetricCard
          label="Disk /"
          icon="hard-drive"
          :value="metrics.disk.value"
          :unit="metrics.disk.unit"
          :percent="metrics.disk.percent"
          :sub="metrics.disk.sub"
          :loading="showSkeleton"
        />
        <MetricCard
          label="Uptime"
          icon="clock"
          :value="metrics.uptime.value"
          :sub="metrics.uptime.sub"
          :loading="showSkeleton"
        />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-[3fr_2fr] gap-4 items-start">
        <!-- Apps -->
        <Card class="min-w-0">
          <CardHeader title="Apps" icon="layers">
            <RouterLink
              to="/apps"
              class="inline-flex items-center gap-1 text-sm-var text-c-actx font-medium no-underline hover:underline underline-offset-2"
            >
              View all<span class="sr-only"> apps</span> <LIcon name="chevron-right" is="width:14px;height:14px" />
            </RouterLink>
          </CardHeader>

          <dl class="m-0 grid grid-cols-3 border-b border-c-border">
            <div
              v-for="tile in COUNT_TILES"
              :key="tile.key"
              class="px-4 py-3 border-r border-c-border last:border-r-0 min-w-0"
            >
              <dt class="text-xs-var text-c-tx2 font-medium">{{ tile.label }}</dt>
              <dd class="m-0 mt-0.5 text-xl font-semibold tabular-nums">
                <span v-if="showSkeleton" class="skeleton inline-block h-5 w-8 align-middle"></span>
                <span v-else :class="counts[tile.key] ? tile.tone : 'text-c-tx3'">{{ counts[tile.key] }}</span>
              </dd>
            </div>
          </dl>

          <div v-if="servicesError && !servicesLoaded" class="px-4 pt-3">
            <Alert tone="warn" title="Services could not be loaded">
              {{ servicesError }}
              <template #action>
                <Btn sm @click="servicesStore.load()"><LIcon name="refresh-cw" /> Retry</Btn>
              </template>
            </Alert>
          </div>

          <div v-if="showSkeleton" class="p-4 flex flex-col gap-3" aria-busy="true" aria-label="Loading apps">
            <div v-for="n in 3" :key="n" class="skeleton h-4" :style="{ width: `${80 - n * 12}%` }"></div>
          </div>
          <EmptyState
            v-else-if="!apps.length"
            icon="layers"
            title="No apps yet"
            hint="Create a site, a service or a Cloudflare tunnel."
          />
          <template v-else>
            <h3 class="m-0 px-4 pt-3 pb-1 text-xs-var font-medium uppercase tracking-[0.06em] text-c-tx2">
              Recently changed
            </h3>
            <ul class="m-0 p-0 pb-1 list-none">
              <li v-for="app in recentApps" :key="app.key">
                <RouterLink
                  :to="app.to"
                  class="flex items-center gap-3 px-4 py-2.5 text-c-tx no-underline hover:bg-c-hover focus-visible:bg-c-hover"
                >
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2 min-w-0">
                      <span class="font-medium text-sm-var truncate">{{ app.name }}</span>
                      <TypeChip :type="app.type" />
                    </div>
                    <div class="mono text-xs-var text-c-tx2 truncate mt-0.5">{{ app.target || '—' }}</div>
                  </div>
                  <span class="hidden sm:inline text-xs-var text-c-tx2 tabular-nums shrink-0" :title="app.modified">
                    {{ app.modifiedAt ? ago(app.modifiedAt / 1000) : '' }}
                  </span>
                  <StatusBadge :status="app.status" />
                </RouterLink>
              </li>
            </ul>
          </template>
        </Card>

        <!-- Tools -->
        <Card class="min-w-0">
          <CardHeader title="Tools" icon="package">
            <template #subtitle>
              <span v-if="!showSkeleton" class="tabular-nums">{{ installedTools.length }} of {{ toolCount }} installed</span>
            </template>
            <RouterLink
              to="/tools"
              class="inline-flex items-center gap-1 text-sm-var text-c-actx font-medium no-underline hover:underline underline-offset-2"
            >
              Manage<span class="sr-only"> tools</span> <LIcon name="chevron-right" is="width:14px;height:14px" />
            </RouterLink>
          </CardHeader>

          <div v-if="showSkeleton" class="p-4 flex flex-col gap-3" aria-busy="true" aria-label="Loading tools">
            <div v-for="n in 3" :key="n" class="skeleton h-4" :style="{ width: `${75 - n * 10}%` }"></div>
          </div>
          <EmptyState v-else-if="!installedTools.length" icon="package" title="No tools installed yet">
            <RouterLink to="/tools" class="text-c-actx font-medium underline underline-offset-2">Browse tools</RouterLink>
          </EmptyState>
          <ul v-else class="m-0 p-0 py-1 list-none">
            <li v-for="tool in installedTools" :key="tool.id">
              <RouterLink
                :to="{ path: '/tools', query: { q: tool.name } }"
                class="flex items-center gap-3 px-4 py-2 text-c-tx no-underline hover:bg-c-hover focus-visible:bg-c-hover"
              >
                <ToolLogo :logo="tool.logo" :name="tool.name" size="sm" :dim="tool.state === 'inactive'" />
                <div class="flex-1 min-w-0">
                  <div class="text-sm-var font-medium truncate">{{ tool.name }}</div>
                  <div class="mono text-xs-var text-c-tx2 truncate">{{ tool.version || '—' }}</div>
                </div>
                <StatusBadge :status="tool.state" />
              </RouterLink>
            </li>
          </ul>
        </Card>
      </div>
    </div>
  </section>
</template>
