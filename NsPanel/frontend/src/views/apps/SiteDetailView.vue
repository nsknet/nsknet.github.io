<script setup lang="ts">
/** One nginx site: details, logs (nginx access/error, plus the journal for .NET)
 *  and its nginx config. .NET sites also get start/stop/autostart controls. */
import { storeToRefs } from 'pinia';
import { computed, ref, watch } from 'vue';
import { RouterLink, useRoute, useRouter } from 'vue-router';

import { fmtCpu, fmtMem, logFileName, siteState, TYPE_LABEL } from '@/components/apps/appRows';
import TextPanel from '@/components/apps/TextPanel.vue';
import { useRemoteText } from '@/components/apps/useRemoteText';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import CardHeader from '@/components/ui/CardHeader.vue';
import EmptyState from '@/components/ui/EmptyState.vue';
import ErrorState from '@/components/ui/ErrorState.vue';
import FilterPills from '@/components/ui/FilterPills.vue';
import KeyValueList from '@/components/ui/KeyValueList.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import Skeleton from '@/components/ui/Skeleton.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import Tabs from '@/components/ui/Tabs.vue';
import TypeChip from '@/components/ui/TypeChip.vue';
import type { KeyValueItem, TabItem } from '@/components/ui/types';
import { useJobRunner } from '@/composables/useJobs';
import { useQueryRef } from '@/composables/useQueryRef';
import { useSitesStore } from '@/stores/sites';
import { useSystemStore } from '@/stores/system';
import { useUiStore } from '@/stores/ui';
import { apiPath } from '@/utils/format';

const route = useRoute();
const router = useRouter();
const ui = useUiStore();
const { run } = useJobRunner();
const sitesStore = useSitesStore();
const { loaded, loading, error } = storeToRefs(sitesStore);
const { host } = storeToRefs(useSystemStore());

const name = computed(() => String(route.params.name ?? ''));
// Never fall back to another site: a stale or mistyped URL must not put
// Start/Stop buttons in front of a different site.
const site = computed(() => sitesStore.bySlug(name.value));
const isDotnet = computed(() => site.value?.type === 'dotnet');
const running = computed(() => !!site.value && isDotnet.value && site.value.status === 'running');

// ── Tabs ──────────────────────────────────────────────────────────────────
const TABS = ['overview', 'logs', 'config'] as const;
type Tab = (typeof TABS)[number];
const tab = useQueryRef<Tab>('tab', 'overview', TABS);
const tabModel = computed<string>({ get: () => tab.value, set: (value) => (tab.value = value as Tab) });
const tabItems: TabItem[] = [
  { key: 'overview', label: 'Overview', icon: 'info' },
  { key: 'logs', label: 'Logs', icon: 'scroll-text' },
  { key: 'config', label: 'nginx config', icon: 'file-code' },
];

const logs = useRemoteText(() => apiPath`/api/v1/sites/${name.value}/logs`);
const config = useRemoteText(() => apiPath`/api/v1/sites/${name.value}/config`);

watch(
  [tab, site],
  ([current, exists]) => {
    if (!exists) return;
    if (current === 'logs') logs.ensure();
    if (current === 'config') config.ensure();
  },
  { immediate: true },
);

/** The logs endpoint joins sections as "===== label =====\n<text>"; split them back. */
const logSections = computed(() => {
  const sections: { label: string; text: string }[] = [];
  const pattern = /^===== (.+?) =====$/gm;
  const text = logs.text.value;
  const marks = [...text.matchAll(pattern)];
  marks.forEach((match, index) => {
    const start = (match.index ?? 0) + match[0].length + 1;
    const end = index + 1 < marks.length ? (marks[index + 1].index ?? text.length) : text.length;
    sections.push({ label: match[1], text: text.slice(start, end).replace(/\s+$/, '') });
  });
  if (!sections.length && text) sections.push({ label: 'log', text });
  return sections;
});

const logSection = ref('');
const sectionOptions = computed(() =>
  logSections.value.map((section) => ({ value: section.label, label: section.label })),
);
const currentSection = computed(
  () => logSections.value.find((section) => section.label === logSection.value) ?? logSections.value[0],
);
const logSectionModel = computed<string>({
  get: () => currentSection.value?.label ?? '',
  set: (value) => (logSection.value = value),
});

// ── Details ───────────────────────────────────────────────────────────────
/** Where to open the site: the domain, or this server's address and the port. */
const openUrl = computed(() => {
  const s = site.value;
  if (!s) return '';
  if (s.accessKind === 'domain') return `http://${s.accessValue}`;
  if (s.accessKind === 'port') return `http://${window.location.hostname}:${s.accessValue}`;
  return '';
});

const details = computed<KeyValueItem[]>(() => {
  const s = site.value;
  if (!s) return [];
  const items: KeyValueItem[] = [
    { key: 'type', label: 'Type', value: TYPE_LABEL[s.type as keyof typeof TYPE_LABEL] ?? s.type },
    {
      key: 'access',
      label: s.accessKind === 'port' ? 'Port' : 'Domain',
      value: s.accessValue,
      mono: true,
      copy: true,
    },
  ];
  if (s.type === 'proxy')
    items.push({ key: 'proxy', label: 'Proxy target', value: s.proxyTarget, mono: true, copy: true });
  if (s.type === 'dotnet') {
    items.push(
      { key: 'dll', label: 'DLL', value: s.dll, mono: true },
      { key: 'internal', label: 'Internal port', value: s.internalPort, mono: true },
      { key: 'env', label: 'Environment', value: s.env, mono: true },
      { key: 'autostart', label: 'Autostart', value: s.autostart },
    );
  }
  items.push(
    { key: 'created', label: 'Created', value: s.created },
    { key: 'modified', label: 'Modified', value: s.modified },
  );
  return items;
});

const paths = computed<KeyValueItem[]>(() => {
  const s = site.value;
  if (!s) return [];
  const items: KeyValueItem[] = [
    { key: 'webroot', label: 'Web root', value: s.webRoot, mono: true, copy: true },
    { key: 'conf', label: 'nginx config', value: s.configPath, mono: true, copy: true },
  ];
  if (s.logDir) items.push({ key: 'logs', label: 'Log folder', value: s.logDir, mono: true, copy: true });
  if (s.type === 'dotnet')
    items.push({ key: 'unit', label: 'systemd unit', value: s.unitPath, mono: true, copy: true });
  return items;
});

const runtime = computed<KeyValueItem[]>(() => {
  const s = site.value;
  if (!s) return [];
  return [
    { key: 'status', label: 'Status', value: s.status },
    { key: 'pid', label: 'PID', value: running.value ? s.pid : null, mono: true },
    { key: 'mem', label: 'Memory', value: fmtMem(s.mem, running.value) },
    { key: 'cpu', label: 'CPU', value: fmtCpu(s.cpu, running.value) },
  ];
});

// ── Actions ───────────────────────────────────────────────────────────────
function action(verb: string, title: string): void {
  void run(apiPath`/api/v1/sites/${name.value}/${verb}`, {}, { title });
}

function stop(): void {
  ui.confirmThen(
    `Stop ${name.value}?`,
    'The .NET app stops and the site returns errors until it is started again.',
    () => action('stop', `Stopping ${name.value}`),
    { danger: true, confirmLabel: 'Stop site' },
  );
}

function disable(): void {
  ui.confirmThen(
    `Disable autostart for ${name.value}?`,
    'The app keeps running now, but will not start again after a reboot.',
    () => action('disable', `Disabling ${name.value}`),
    { danger: true, confirmLabel: 'Disable autostart' },
  );
}

const unitLink = computed(() => ({ path: apiPath`/apps/service/${name.value}`, query: { tab: 'config' } }));

const state = computed(() => (site.value ? siteState(site.value.status) : 'other'));
const logsDownload = computed(() =>
  logFileName(host.value.hostname, name.value, currentSection.value?.label ?? 'logs'),
);
</script>

<template>
  <section v-if="site">
    <PageHeader :title="site.name">
      <template #title>
        <span class="truncate">{{ site.name }}</span>
        <TypeChip :type="site.type" />
        <StatusBadge :status="site.status" />
      </template>
      <template #subtitle>
        <span class="mono">{{ site.access }}</span>
        <a
          v-if="openUrl"
          :href="openUrl"
          target="_blank"
          rel="noopener noreferrer"
          class="ml-2 inline-flex items-center gap-1 text-c-actx underline underline-offset-2"
        >
          Open<span class="sr-only"> {{ site.name }} in a new tab</span>
          <LIcon is="width:13px;height:13px" name="external-link" />
        </a>
      </template>

      <template v-if="isDotnet">
        <Btn v-if="!running" variant="success" @click="action('start', `Starting ${site.name}`)">
          <LIcon name="play" /> Start
        </Btn>
        <Btn v-else variant="danger" @click="stop"><LIcon name="square" /> Stop</Btn>
        <Btn @click="action('restart', `Restarting ${site.name}`)"><LIcon name="rotate-cw" /> Restart</Btn>
      </template>
      <Btn @click="action('reload-nginx', 'Reloading nginx')"><LIcon name="refresh-cw" /> Reload nginx</Btn>
    </PageHeader>

    <Tabs v-model="tabModel" :items="tabItems" label="Site sections">
      <!-- Overview -->
      <div v-if="tab === 'overview'" class="grid grid-cols-1 lg:grid-cols-[3fr_2fr] gap-4 items-start">
        <div class="flex flex-col gap-4 min-w-0">
          <Card>
            <CardHeader title="Details" icon="info" />
            <div class="p-4"><KeyValueList :items="details" /></div>
          </Card>
          <Card>
            <CardHeader title="Paths" icon="hard-drive" />
            <div class="p-4">
              <KeyValueList :items="paths">
                <template #value-unit="{ item }">
                  <span class="mono text-xs-var break-all min-w-0">{{ item.value || '—' }}</span>
                  <RouterLink
                    :to="unitLink"
                    class="shrink-0 text-xs-var text-c-actx underline underline-offset-2"
                  >
                    Edit unit
                  </RouterLink>
                </template>
              </KeyValueList>
            </div>
          </Card>
        </div>

        <div class="flex flex-col gap-4 min-w-0">
          <Card v-if="isDotnet">
            <CardHeader title="Runtime" icon="activity" />
            <div class="p-4 flex flex-col gap-4">
              <KeyValueList :items="runtime" label-width="100px">
                <template #value-status="{ item }"><StatusBadge :status="String(item.value)" /></template>
              </KeyValueList>
              <div class="flex flex-wrap gap-2 pt-3 border-t border-c-border">
                <Btn
                  v-if="site.autostart !== 'enabled'"
                  sm
                  @click="action('enable', `Enabling ${site.name}`)"
                >
                  <LIcon name="circle-check" /> Enable autostart
                </Btn>
                <Btn v-else sm variant="danger" @click="disable">
                  <LIcon name="ban" /> Disable autostart
                </Btn>
              </div>
            </div>
          </Card>
          <Card v-else>
            <CardHeader title="Status" icon="activity" />
            <div class="p-4 text-sm-var text-c-tx2 flex flex-col gap-2">
              <div class="flex items-center gap-2"><StatusBadge :status="site.status" /></div>
              <p class="m-0">
                <template v-if="state === 'up'"
                  >nginx serves this site and its config passes <span class="mono">nginx -t</span>.</template
                >
                <template v-else-if="state === 'failed'">
                  <span class="mono">nginx -t</span> fails. Check the error log and the config, then reload
                  nginx.
                </template>
                <template v-else>The site's nginx config file is missing.</template>
              </p>
            </div>
          </Card>
        </div>
      </div>

      <!-- Logs -->
      <TextPanel
        v-else-if="tab === 'logs'"
        :label="`${currentSection?.label ?? 'Site'} log`"
        :text="currentSection?.text ?? ''"
        :loading="logs.loading.value"
        :error="logs.error.value"
        :download-name="logsDownload"
        @refresh="logs.load()"
      >
        <template #toolbar>
          <FilterPills
            v-if="sectionOptions.length > 1"
            v-model="logSectionModel"
            :options="sectionOptions"
            label="Log"
          />
        </template>
      </TextPanel>

      <!-- Config -->
      <TextPanel
        v-else
        label="nginx config"
        :text="config.text.value"
        :loading="config.loading.value"
        :error="config.error.value"
        :wrap="false"
        @refresh="config.load()"
      >
        <template #toolbar>
          <span class="mono text-xs-var text-c-tx2 truncate">{{ site.configPath }}</span>
        </template>
      </TextPanel>
    </Tabs>
  </section>

  <section v-else-if="error && !loaded">
    <Card><ErrorState :message="error" :retrying="loading" @retry="sitesStore.load()" /></Card>
  </section>

  <section v-else-if="!loaded" aria-busy="true">
    <div class="skeleton h-7 w-64 mb-6"></div>
    <Skeleton variant="cards" :count="2" />
  </section>

  <section v-else>
    <Card>
      <EmptyState icon="globe" title="Site not found" :hint="`No site named ${name} exists.`" />
      <div class="flex justify-center pb-6">
        <Btn sm @click="router.push('/apps')"><LIcon name="arrow-left" /> All apps</Btn>
      </div>
    </Card>
  </section>
</template>
