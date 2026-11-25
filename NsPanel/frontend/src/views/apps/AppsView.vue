<script setup lang="ts">
/** Apps: nginx sites (static, reverse proxy, .NET) and systemd services
 *  (including Cloudflare tunnels) in one list, filterable by type and searchable. */
import { storeToRefs } from 'pinia';
import { computed } from 'vue';
import { useRouter } from 'vue-router';

import type { AppRow } from '@/api/apps';
import { buildApps, fmtCpu, fmtMem, TYPE_LABEL } from '@/components/apps/appRows';
import Alert from '@/components/ui/Alert.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import DataTable from '@/components/ui/DataTable.vue';
import FilterPills from '@/components/ui/FilterPills.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import TypeChip from '@/components/ui/TypeChip.vue';
import type { Column } from '@/components/ui/types';
import { useQueryRef } from '@/composables/useQueryRef';
import { useRefresh } from '@/composables/useRefresh';
import { useServicesStore } from '@/stores/services';
import { useSitesStore } from '@/stores/sites';
import { useToolsStore } from '@/stores/tools';

const router = useRouter();
const sitesStore = useSitesStore();
const servicesStore = useServicesStore();
const { sites, loading: sitesLoading, loaded: sitesLoaded, error: sitesError } = storeToRefs(sitesStore);
const {
  services,
  loading: servicesLoading,
  loaded: servicesLoaded,
  error: servicesError,
} = storeToRefs(servicesStore);
const toolsStore = useToolsStore();
const { refresh, refreshing } = useRefresh();

const FILTERS = ['all', 'site', 'service', 'tunnel'] as const;
type Filter = (typeof FILTERS)[number];
const filter = useQueryRef<Filter>('type', 'all', FILTERS);
const search = useQueryRef<string>('q', '');

const apps = computed(() => buildApps(sites.value, services.value));

function matchesType(app: AppRow, value: Filter): boolean {
  if (value === 'all') return true;
  if (value === 'site') return app.kind === 'site';
  if (value === 'tunnel') return app.type === 'tunnel';
  return app.type === 'service';
}

const filterOptions = computed(() => [
  { value: 'all', label: 'All', count: apps.value.length },
  { value: 'site', label: 'Sites', count: apps.value.filter((a) => matchesType(a, 'site')).length },
  { value: 'service', label: 'Services', count: apps.value.filter((a) => matchesType(a, 'service')).length },
  { value: 'tunnel', label: 'Tunnels', count: apps.value.filter((a) => matchesType(a, 'tunnel')).length },
]);

const filterModel = computed<string>({
  get: () => filter.value,
  set: (value) => (filter.value = value as Filter),
});

const rows = computed(() => {
  const needle = search.value.trim().toLowerCase();
  return apps.value.filter(
    (app) =>
      matchesType(app, filter.value) &&
      (!needle || app.name.toLowerCase().includes(needle) || app.target.toLowerCase().includes(needle)),
  );
});

const filtered = computed(() => filter.value !== 'all' || !!search.value.trim());

const columns: Column<AppRow>[] = [
  { key: 'name', label: 'Name', sortable: true },
  { key: 'type', label: 'Type', sortable: true, hideOnMobile: true },
  { key: 'target', label: 'Access / target', class: 'mono', hideOnMobile: true },
  { key: 'status', label: 'Status', sortable: true },
  {
    key: 'mem',
    label: 'Memory',
    align: 'right',
    class: 'num',
    sortable: true,
    sortValue: (row) => row.mem ?? -1,
    hideOnMobile: true,
  },
  {
    key: 'cpu',
    label: 'CPU',
    align: 'right',
    class: 'num',
    sortable: true,
    sortValue: (row) => row.cpu ?? -1,
    hideOnMobile: true,
  },
  {
    key: 'modified',
    label: 'Modified',
    sortable: true,
    sortValue: (row) => row.modifiedAt,
    class: 'num',
    hideOnMobile: true,
  },
];

const anyLoading = computed(() => (sitesLoading.value && !sitesLoaded.value) || (servicesLoading.value && !servicesLoaded.value));

/** The table's error: only when nothing could be shown at all. */
const tableError = computed(() => {
  if (rows.value.length) return null;
  if (sitesError.value && !sitesLoaded.value) return sitesError.value;
  if (servicesError.value && !servicesLoaded.value) return servicesError.value;
  return null;
});

/** One list failed while the other loaded: show what we have and say what is missing. */
const partialError = computed(() => {
  if (tableError.value) return null;
  if (sitesError.value && !sitesLoaded.value) return { what: 'Sites', message: sitesError.value };
  if (servicesError.value && !servicesLoaded.value) return { what: 'Services', message: servicesError.value };
  return null;
});

function retry(): void {
  void sitesStore.load();
  void servicesStore.load();
}

/** nginx state, only when the tools list happens to be loaded already (no extra request). */
const nginxState = computed(() => {
  if (!toolsStore.loaded) return null;
  const nginx = toolsStore.tools.find((tool) => tool.id === 'nginx');
  return nginx?.installed ? nginx.state : null;
});

function clearFilters(): void {
  filter.value = 'all';
  search.value = '';
}

const subtitle = computed(() => {
  const siteCount = sites.value.length;
  const serviceCount = apps.value.length - siteCount;
  return `${siteCount} site${siteCount === 1 ? '' : 's'} · ${serviceCount} service${serviceCount === 1 ? '' : 's'}`;
});
</script>

<template>
  <section>
    <PageHeader title="Apps">
      <template #subtitle>
        <span class="inline-flex flex-wrap items-center gap-2">
          <span class="tabular-nums">{{ subtitle }}</span>
          <span v-if="nginxState" class="inline-flex items-center gap-1.5">
            · nginx <StatusBadge :status="nginxState" />
          </span>
        </span>
      </template>
      <Btn :loading="refreshing" @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
      <Btn variant="primary" @click="router.push('/apps/new')"><LIcon name="plus" /> New app</Btn>
    </PageHeader>

    <div class="flex flex-col gap-3">
      <div class="flex flex-col sm:flex-row sm:items-center gap-3">
        <FilterPills v-model="filterModel" :options="filterOptions" label="Filter by type" />
        <div class="relative sm:ml-auto sm:w-72">
          <label for="apps-search" class="sr-only">Search apps</label>
          <LIcon
            name="search"
            is="width:15px;height:15px;position:absolute;left:10px;top:50%;transform:translateY(-50%);color:var(--text-3);pointer-events:none"
          />
          <input
            id="apps-search"
            v-model="search"
            type="search"
            class="input"
            :style="{ paddingLeft: '32px' }"
            placeholder="Search by name or target"
            autocomplete="off"
          />
        </div>
      </div>

      <Alert v-if="partialError" tone="warn" :title="`${partialError.what} could not be loaded`">
        {{ partialError.message }}
        <template #action>
          <Btn sm @click="retry"><LIcon name="refresh-cw" /> Retry</Btn>
        </template>
      </Alert>

      <Card class="overflow-hidden">
        <DataTable
          :columns="columns"
          :rows="rows"
          row-key="key"
          label="Apps"
          :loading="anyLoading"
          :error="tableError"
          :row-to="(row) => row.to"
          sort-key="name"
          :row-muted="(row) => row.state === 'stopped'"
          :empty-icon="filtered ? 'search-x' : 'layers'"
          :empty-title="filtered ? 'No apps match' : 'No apps yet'"
          @retry="retry"
        >
          <template #cell-name="{ row }">
            <span class="font-medium">{{ row.name }}</span>
            <span class="md:hidden block text-xs-var text-c-tx2 font-normal">{{ TYPE_LABEL[row.type] }}</span>
          </template>
          <template #cell-type="{ row }">
            <TypeChip :type="row.type" />
          </template>
          <template #cell-target="{ row }">
            <span class="block max-w-[320px] truncate text-c-tx2" :title="row.target">{{ row.target || '—' }}</span>
          </template>
          <template #cell-status="{ row }">
            <StatusBadge :status="row.status" />
          </template>
          <template #cell-mem="{ row }">{{ fmtMem(row.mem, row.mem !== null) }}</template>
          <template #cell-cpu="{ row }">{{ fmtCpu(row.cpu, row.cpu !== null) }}</template>
          <template #cell-modified="{ row }">
            <span class="text-c-tx2">{{ row.modified || '—' }}</span>
          </template>
          <template #empty>
            <span v-if="filtered" class="inline-flex flex-col items-center gap-3">
              Try another type or search term.
              <Btn sm @click="clearFilters"><LIcon name="x" /> Clear filters</Btn>
            </span>
            <span v-else class="inline-flex flex-col items-center gap-3">
              Create a site, a systemd service or a Cloudflare tunnel.
              <Btn sm variant="primary" @click="router.push('/apps/new')"><LIcon name="plus" /> New app</Btn>
            </span>
          </template>
        </DataTable>
      </Card>

      <p class="m-0 text-xs-var text-c-tx3">
        A .NET site runs as a systemd unit of the same name; it is listed once, as the site.
      </p>
    </div>
  </section>
</template>
