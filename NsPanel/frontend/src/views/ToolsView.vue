<script setup lang="ts">
/** One card per tool module: install, re-install, uninstall, change password.
 *
 * The list reloads itself when a job finishes (the shell's onJobFinished and
 * the runner's onDone both reload the route's stores), so no polling here. */
import { storeToRefs } from 'pinia';
import { computed } from 'vue';

import type { Tool } from '@/api/types';
import ToolCard from '@/components/tools/ToolCard.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import EmptyState from '@/components/ui/EmptyState.vue';
import ErrorState from '@/components/ui/ErrorState.vue';
import FilterPills from '@/components/ui/FilterPills.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import Skeleton from '@/components/ui/Skeleton.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useQueryRef } from '@/composables/useQueryRef';
import { useRefresh } from '@/composables/useRefresh';
import { useJobsStore } from '@/stores/jobs';
import { useToolsStore } from '@/stores/tools';
import { useUiStore } from '@/stores/ui';
import { apiPath } from '@/utils/format';

const ui = useUiStore();
const { run } = useJobRunner();
const { refresh, refreshing } = useRefresh();
const toolsStore = useToolsStore();
const { tools, loading, loaded, error } = storeToRefs(toolsStore);
const { running } = storeToRefs(useJobsStore());

const FILTERS = ['all', 'installed', 'available'] as const;
type Filter = (typeof FILTERS)[number];
const filter = useQueryRef<Filter>('show', 'all', FILTERS);
// The overview and the command palette deep-link here as /tools?q=<name>.
const search = useQueryRef<string>('q', '');

const installedCount = computed(() => tools.value.filter((tool) => tool.installed).length);

const filterOptions = computed(() => [
  { value: 'all', label: 'All', count: tools.value.length },
  { value: 'installed', label: 'Installed', count: installedCount.value },
  { value: 'available', label: 'Available', count: tools.value.length - installedCount.value },
]);

const filtered = computed(() => {
  const query = search.value.trim().toLowerCase();
  return tools.value.filter((tool) => {
    if (filter.value === 'installed' && !tool.installed) return false;
    if (filter.value === 'available' && tool.installed) return false;
    if (!query) return true;
    return `${tool.name} ${tool.id} ${tool.desc ?? ''}`.toLowerCase().includes(query);
  });
});

/** A job for this tool is running (install, uninstall, password change). */
function busy(tool: Tool): boolean {
  return running.value.some((job) => job.label.includes(tool.name));
}

function needsDialog(tool: Tool): boolean {
  return tool.requiresPassword || tool.firewallPorts.length > 0 || tool.installParams.length > 0;
}

/** Resolves to false when the request failed, so the install dialog stays open. */
async function launchInstall(tool: Tool, reinstalling: boolean, payload: Record<string, string> = {}) {
  const result = await run(
    apiPath`/api/v1/tools/${tool.id}/install`,
    reinstalling ? { ...payload, reinstall: 'true' } : payload,
    { title: `${reinstalling ? 'Re-installing' : 'Installing'} ${tool.name}` },
  );
  return result !== null;
}

function install(tool: Tool, reinstalling = false): void {
  // Anything that needs a password, opens a port or declares parameters gets
  // the dialog first; the rest installs straight away.
  if (needsDialog(tool)) {
    ui.openInstallDialog(tool, (payload) => launchInstall(tool, reinstalling, payload));
  } else {
    void launchInstall(tool, reinstalling);
  }
}

function reinstall(tool: Tool): void {
  ui.confirmThen(
    `Re-install ${tool.name}?`,
    'Runs the installer again over the existing install.',
    () => install(tool, true),
    {
      danger: true,
      confirmLabel: 'Re-install',
      details: [
        'Packages and configuration files are applied again; local edits to them may be overwritten.',
        'Existing data is kept, but generated credentials may be replaced.',
      ],
    },
  );
}

function uninstall(tool: Tool): void {
  ui.confirmThen(
    `Uninstall ${tool.name}?`,
    'Stops the service and removes its packages. This cannot be undone.',
    () => void run(apiPath`/api/v1/tools/${tool.id}/uninstall`, {}, { title: `Uninstalling ${tool.name}` }),
    {
      danger: true,
      confirmLabel: 'Uninstall',
      typeToConfirm: tool.name,
      details: [
        `${tool.name} stops and its packages are removed.`,
        'Data may be removed too — databases lose their data directory. Back it up first.',
        'Sites and services that depend on it stop working.',
      ],
    },
  );
}

function changePassword(tool: Tool): void {
  ui.openInstallDialog(
    tool,
    async (payload) =>
      (await run(apiPath`/api/v1/tools/${tool.id}/change-password`, payload, {
        title: `Changing ${tool.name} password`,
      })) !== null,
    'password',
  );
}

function clearFilters(): void {
  search.value = '';
  filter.value = 'all';
}
</script>

<template>
  <section>
    <PageHeader
      title="Tools"
      :subtitle="
        loaded
          ? `${installedCount} of ${tools.length} installed — databases, runtimes and servers this host can run.`
          : 'Databases, runtimes and servers this host can run.'
      "
    >
      <Btn :loading="refreshing" @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
    </PageHeader>

    <div class="flex flex-col sm:flex-row sm:items-center gap-2 mb-4">
      <label class="relative w-full sm:max-w-xs">
        <span class="sr-only">Search tools</span>
        <LIcon
          is="position:absolute;left:10px;top:50%;transform:translateY(-50%);pointer-events:none;color:var(--text-3);width:14px;height:14px"
          name="search"
        />
        <input
          v-model="search"
          class="input pl-[30px]"
          type="search"
          autocomplete="off"
          spellcheck="false"
          placeholder="Search tools…"
        />
      </label>
      <FilterPills v-model="filter" :options="filterOptions" label="Show tools" />
    </div>

    <Skeleton v-if="!loaded && (loading || !error)" variant="cards" :count="6" min="300px" />

    <Card v-else-if="error && !loaded">
      <ErrorState :message="error" title="Could not load the tools" @retry="toolsStore.load()" />
    </Card>

    <Card v-else-if="!tools.length">
      <EmptyState
        icon="package"
        title="No tool modules"
        hint="This panel build ships no installable tools."
      />
    </Card>

    <Card v-else-if="!filtered.length">
      <EmptyState title="No tools match">
        <p class="m-0">{{ search ? `Nothing matches “${search}”.` : 'No tools in this group.' }}</p>
        <Btn sm class="mt-3" @click="clearFilters">Clear filters</Btn>
      </EmptyState>
    </Card>

    <div v-else class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
      <ToolCard
        v-for="tool in filtered"
        :key="tool.id"
        :tool="tool"
        :busy="busy(tool)"
        @install="install(tool)"
        @reinstall="reinstall(tool)"
        @uninstall="uninstall(tool)"
        @password="changePassword(tool)"
      />
    </div>
  </section>
</template>
