<script setup lang="ts">
/** One card per tool module: install, re-install, uninstall, change password. */
import { storeToRefs } from 'pinia';
import { computed, ref } from 'vue';

import type { Tool } from '@/api/types';
import Btn from '@/components/ui/Btn.vue';
import EmptyState from '@/components/ui/EmptyState.vue';
import LIcon from '@/components/ui/LIcon.vue';
import Spinner from '@/components/ui/Spinner.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useToolsStore } from '@/stores/tools';
import { useUiStore } from '@/stores/ui';

const ui = useUiStore();
const { run, reload } = useJobRunner();
const { tools, loading } = storeToRefs(useToolsStore());

const filter = ref<'all' | 'installed' | 'not-installed'>('all');
const search = ref('');

const installedCount = computed(() => tools.value.filter((tool) => tool.installed).length);

const filtered = computed(() => {
  const query = search.value.toLowerCase();
  return tools.value.filter((tool) => {
    if (filter.value === 'installed' && !tool.installed) return false;
    if (filter.value === 'not-installed' && tool.installed) return false;
    if (!query) return true;
    return (
      tool.name.toLowerCase().includes(query) || (tool.desc ?? '').toLowerCase().includes(query)
    );
  });
});

function diagRows(tool: Tool): [string, string][] {
  const rows: [string, string][] = [...(tool.diag ?? [])];
  if (tool.ports) rows.push(['Ports', tool.ports]);
  if (tool.version) rows.push(['Version', tool.version]);
  return rows;
}

async function recheck(tool?: Tool): Promise<void> {
  await reload();
  ui.addToast({
    t: tool ? 'Tool status updated' : 'Tool statuses refreshed',
    d: tool ? `Checked ${tool.name} state.` : '',
    k: 'info',
  });
}

function install(tool: Tool, reinstalling = false): void {
  const launch = (payload: Record<string, string> = {}) =>
    run(
      `/api/v1/tools/${tool.id}/install`,
      reinstalling ? { ...payload, reinstall: 'true' } : payload,
      { title: `${reinstalling ? 'Re-installing' : 'Installing'} ${tool.name}` },
    );

  // Anything that needs a password, opens a port, or declares custom params
  // gets the config dialog first; the rest installs straight away.
  if (tool.requiresPassword || tool.firewallPorts?.length || tool.installParams?.length) {
    ui.openInstallDialog(tool, (payload) => void launch(payload));
  } else {
    void launch();
  }
}

function reinstall(tool: Tool): void {
  ui.confirmThen(
    `Re-install ${tool.name}?`,
    'Re-runs the installer: re-applies packages and configuration. Existing data is kept, but credentials/config may be regenerated.',
    () => install(tool, true),
  );
}

function uninstall(tool: Tool): void {
  ui.confirmThen(
    `Uninstall ${tool.name}?`,
    'Stops the service and removes its packages. For databases the data directory is deleted too. This cannot be undone.',
    () => {
      void run(`/api/v1/tools/${tool.id}/uninstall`, {}, { title: `Uninstalling ${tool.name}` });
    },
  );
}

function changePassword(tool: Tool): void {
  ui.openInstallDialog(
    tool,
    (payload) => {
      void run(`/api/v1/tools/${tool.id}/change-password`, payload, {
        title: `Changing ${tool.name} password`,
      });
    },
    'password',
  );
}

const FILTER_LABELS: Record<string, string> = {
  all: 'All',
  installed: 'Installed',
  'not-installed': 'Not installed',
};
</script>

<template>
  <section>
    <div class="flex items-end justify-between gap-6 mb-6">
      <div>
        <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">Tools</h1>
        <div class="text-sm-var text-c-tx2">
          {{ installedCount }} of {{ tools.length }} tools installed. One-click provisioning, live
          health.
        </div>
      </div>
      <div class="flex gap-2">
        <Btn @click="recheck()"><LIcon name="refresh-cw" /> Re-check all</Btn>
      </div>
    </div>

    <div class="flex items-center gap-2 mb-3 flex-wrap">
      <div class="relative flex-1 max-w-xs">
        <LIcon
          name="search"
          is="position:absolute;left:10px;top:50%;transform:translateY(-50%);pointer-events:none;color:var(--text-3);width:14px;height:14px"
        />
        <input
          v-model="search"
          class="input h-8 pl-[30px]"
          type="search"
          autocomplete="off"
          placeholder="Filter tools…"
        />
      </div>
      <button
        v-for="key in ['all', 'installed', 'not-installed'] as const"
        :key="key"
        :class="[
          'h-7 px-2.5 rounded-full border text-xs-var mono cursor-pointer inline-flex items-center gap-1 transition-colors',
          filter === key
            ? 'bg-c-tx text-c-txinv border-c-tx'
            : 'bg-c-bg text-c-tx2 border-c-border hover:text-c-tx hover:border-c-bstrong',
        ]"
        @click="filter = key"
      >
        {{ FILTER_LABELS[key] }}
      </button>
    </div>

    <div v-if="loading && !tools.length" class="text-center py-12 px-6">
      <Spinner label="Loading tools…" />
    </div>

    <EmptyState
      v-else-if="!filtered.length"
      title="No matches"
      hint="Adjust the filters or search query."
    />

    <div v-else class="grid gap-3" style="grid-template-columns: repeat(auto-fill, minmax(320px, 1fr))">
      <template v-for="tool in filtered" :key="tool.id">
        <div
          v-if="tool.installed"
          class="flex flex-col gap-3 p-[18px] bg-c-bg border border-c-border rounded-theme transition-colors hover:border-c-bstrong"
        >
          <div class="flex items-start gap-3">
            <div
              class="w-10 h-10 rounded-[9px] bg-c-subtle flex items-center justify-center shrink-0 overflow-hidden p-1.5 select-none"
            >
              <img
                v-if="tool.logo.endsWith('.png')"
                :src="tool.logo"
                :alt="tool.name"
                class="w-full h-full object-contain"
              />
              <span
                v-else
                class="text-[13px] font-bold mono tracking-[-0.02em]"
                :style="{ color: tool.color }"
                >{{ tool.logo }}</span
              >
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center justify-between gap-2 min-w-0">
                <div class="font-semibold text-[15px] tracking-[-0.01em] truncate" :title="tool.name">
                  {{ tool.name }}
                </div>
                <StatusBadge :status="tool.state" />
              </div>
              <div class="text-xs-var text-c-tx2 mt-0.5 leading-normal">{{ tool.desc }}</div>
            </div>
          </div>

          <div
            class="grid gap-x-3.5 gap-y-1.5 text-xs-var pt-2.5 border-t border-c-border"
            style="grid-template-columns: auto 1fr"
          >
            <template v-for="row in diagRows(tool)" :key="row[0]">
              <div class="text-c-tx3 uppercase tracking-[0.05em] text-[10px] pt-0.5">
                {{ row[0] }}
              </div>
              <div class="text-c-tx mono text-xs-var tabular-nums">{{ row[1] }}</div>
            </template>
          </div>

          <div class="flex items-center gap-1.5 mt-auto pt-1">
            <Btn sm @click="recheck(tool)"><LIcon name="refresh-cw" /> Re-check</Btn>
            <span class="flex-1"></span>
            <Btn sm square title="Re-install (re-run installer)" @click="reinstall(tool)">
              <LIcon name="rotate-cw" />
            </Btn>
            <Btn
              v-if="tool.canChangePassword"
              sm
              square
              title="Change password"
              @click="changePassword(tool)"
            >
              <LIcon name="key-round" />
            </Btn>
            <Btn
              v-if="tool.canUninstall"
              variant="ghost"
              sm
              square
              title="Uninstall"
              @click="uninstall(tool)"
            >
              <LIcon name="trash-2" />
            </Btn>
          </div>
        </div>

        <div
          v-else
          class="flex flex-col gap-3 p-[18px] bg-c-elev border border-c-border rounded-theme transition-colors hover:border-c-bstrong"
        >
          <div class="flex items-start gap-3">
            <div
              class="w-10 h-10 rounded-[9px] bg-c-subtle flex items-center justify-center shrink-0 overflow-hidden p-1.5 opacity-70 select-none"
            >
              <img
                v-if="tool.logo.endsWith('.png')"
                :src="tool.logo"
                :alt="tool.name"
                class="w-full h-full object-contain"
              />
              <span
                v-else
                class="text-[13px] font-bold mono tracking-[-0.02em]"
                :style="{ color: tool.color }"
                >{{ tool.logo }}</span
              >
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center justify-between gap-2 min-w-0">
                <div class="font-semibold text-[15px] tracking-[-0.01em] truncate" :title="tool.name">
                  {{ tool.name }}
                </div>
                <StatusBadge status="not installed" />
              </div>
              <div class="text-xs-var text-c-tx2 mt-0.5 leading-normal">{{ tool.desc }}</div>
            </div>
          </div>

          <div v-if="tool.requiresPassword || tool.firewallPorts.length" class="flex flex-wrap gap-1.5">
            <span
              v-if="tool.requiresPassword"
              class="inline-flex items-center gap-1 text-[10px] text-c-tx3 mono uppercase tracking-[0.05em] px-1.5 py-0.5 bg-c-subtle border border-c-border rounded"
            >
              <LIcon name="key-round" is="width:11px;height:11px" /> password
            </span>
            <span
              v-if="tool.firewallPorts.length"
              class="inline-flex items-center gap-1 text-[10px] text-c-tx3 mono uppercase tracking-[0.05em] px-1.5 py-0.5 bg-c-subtle border border-c-border rounded"
            >
              <LIcon name="shield" is="width:11px;height:11px" /> port
              {{ tool.firewallPorts.join(', ') }}
            </span>
          </div>

          <div class="flex gap-1.5 mt-auto pt-1">
            <Btn variant="primary" sm @click="install(tool)"><LIcon name="download" /> Install</Btn>
            <span class="flex-1"></span>
            <Btn variant="ghost" sm @click="recheck(tool)">
              <LIcon name="refresh-cw" /> Re-check
            </Btn>
          </div>
        </div>
      </template>
    </div>
  </section>
</template>
