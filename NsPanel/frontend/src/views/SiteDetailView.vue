<script setup lang="ts">
/** One nginx site: metadata, paths, runtime, and its config/log viewers. */
import { storeToRefs } from 'pinia';
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';

import { fetchData } from '@/api/client';
import OutputDialog from '@/components/OutputDialog.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import LIcon from '@/components/ui/LIcon.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import TypeChip from '@/components/ui/TypeChip.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useSitesStore } from '@/stores/sites';
import { useSystemStore } from '@/stores/system';
import { useUiStore } from '@/stores/ui';

const props = defineProps<{ slug: string }>();

const router = useRouter();
const ui = useUiStore();
const { run } = useJobRunner();
const sitesStore = useSitesStore();
const { sites } = storeToRefs(sitesStore);
const { host } = storeToRefs(useSystemStore());

const showConfig = ref(false);
const configContent = ref('');
const showLogs = ref(false);
const logsContent = ref('');

const site = computed(() => sitesStore.bySlug(props.slug) ?? sites.value[0]);

const TYPE_LABEL: Record<string, string> = {
  dotnet: '.NET Core (Kestrel)',
  proxy: 'Reverse proxy',
  static: 'Static files',
};

const meta = computed(() => {
  const s = site.value;
  if (!s) return [];
  const rows = [
    { key: 'Type', value: TYPE_LABEL[s.type] ?? '—', mono: false },
    { key: 'Created', value: s.created || '—', mono: false },
    { key: 'Access', value: s.access || '—', mono: true },
  ];
  if (s.type === 'dotnet') {
    rows.push(
      { key: 'DLL', value: s.dll || '—', mono: true },
      { key: 'Internal port', value: String(s.internalPort ?? '—'), mono: true },
      { key: 'Environment', value: s.env || '—', mono: true },
      { key: 'Autostart', value: s.autostart || '—', mono: true },
    );
  }
  if (s.type === 'proxy') {
    rows.push({ key: 'Proxy target', value: s.proxyTarget || '—', mono: true });
  }
  return rows;
});

const paths = computed(() => {
  const s = site.value;
  if (!s) return [];
  const rows = [
    { key: 'Web root', value: s.webRoot || '—' },
    { key: 'Nginx vhost', value: s.configPath || '—' },
  ];
  if (s.type === 'dotnet') rows.push({ key: 'systemd unit', value: s.unitPath || '—' });
  return rows;
});

const runtime = computed(() => {
  const s = site.value;
  return [
    { label: 'Memory', value: s?.mem != null ? s.mem.toFixed(1) : '—', unit: 'MB' },
    { label: 'CPU', value: s?.cpu != null ? s.cpu.toFixed(1) : '—', unit: '%' },
  ];
});

const logsFilename = computed(() => {
  const pad = (value: number) => String(value).padStart(2, '0');
  const safe = (value: string) => value.replace(/[^a-zA-Z0-9._-]/g, '_');
  const now = new Date();
  const stamp = `${pad(now.getMonth() + 1)}-${pad(now.getDate())}-${now.getFullYear()}-${pad(now.getHours())}-${pad(now.getMinutes())}-${pad(now.getSeconds())}`;
  return `${safe(host.value.hostname || 'server')}-${safe(site.value?.name ?? 'site')}-${stamp}.log`;
});

async function load(kind: 'config' | 'logs'): Promise<void> {
  if (!site.value) return;
  try {
    const text = await fetchData<string>(`/api/v1/sites/${site.value.name}/${kind}`);
    if (kind === 'config') {
      configContent.value = text;
      showConfig.value = true;
    } else {
      logsContent.value = text;
      showLogs.value = true;
    }
  } catch (error) {
    ui.addToast({
      t: `Failed to fetch ${kind}`,
      d: error instanceof Error ? error.message : String(error),
      k: 'danger',
    });
  }
}

function siteAction(action: string, title: string): void {
  if (!site.value) return;
  void run(`/api/v1/sites/${site.value.name}/${action}`, {}, { title });
}
</script>

<template>
  <section v-if="site">
    <div class="flex flex-col lg:flex-row lg:items-end lg:justify-between gap-4 mb-6">
      <div>
        <div class="flex items-center gap-2 mb-2">
          <Btn variant="ghost" sm @click="router.push('/sites')">
            <LIcon name="arrow-left" /> Sites
          </Btn>
        </div>
        <div class="flex items-center gap-3">
          <h1 class="text-[22px] font-semibold tracking-[-0.02em]">{{ site.name }}</h1>
          <StatusBadge :status="site.status" />
          <TypeChip :type="site.type" />
        </div>
        <div class="text-sm-var text-c-tx2 mono mt-1">{{ site.access }}</div>
      </div>

      <div class="flex flex-col gap-2 w-full lg:w-auto lg:items-end">
        <div class="flex flex-wrap gap-2">
          <Btn variant="success" @click="siteAction('reload-nginx', 'Reloading Nginx')">
            <LIcon name="refresh-cw" /> Reload Nginx
          </Btn>
          <Btn variant="info" @click="load('config')">
            <LIcon name="file-text" /> Show config
          </Btn>
          <Btn variant="info" @click="load('logs')"><LIcon name="terminal" /> Tail logs</Btn>
        </div>
        <div v-if="site.type === 'dotnet'" class="flex flex-wrap gap-2">
          <Btn
            variant="success"
            :disabled="site.status === 'running'"
            @click="siteAction('start', 'Starting service')"
          >
            <LIcon name="play" /> Start
          </Btn>
          <Btn
            variant="danger"
            :disabled="site.status !== 'running'"
            @click="siteAction('stop', 'Stopping service')"
          >
            <LIcon name="square" /> Stop
          </Btn>
          <Btn variant="warn" @click="siteAction('restart', 'Restarting service')">
            <LIcon name="rotate-ccw" /> Restart
          </Btn>
          <div class="hidden sm:block w-px bg-c-border mx-1 self-stretch"></div>
          <Btn
            variant="success"
            :disabled="site.autostart === 'enabled'"
            @click="siteAction('enable', 'Enabling service')"
          >
            <LIcon name="circle-check" /> Enable
          </Btn>
          <Btn
            variant="danger"
            :disabled="site.autostart === 'disabled'"
            @click="siteAction('disable', 'Disabling service')"
          >
            <LIcon name="ban" /> Disable
          </Btn>
        </div>
      </div>
    </div>

    <div class="grid grid-cols-1 lg:grid-cols-[2fr_1fr] gap-3">
      <div class="flex flex-col gap-3">
        <Card class="overflow-clip">
          <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
            <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Configuration</h3>
            <span class="text-xs-var text-c-tx3 mono">YAML metadata</span>
          </div>
          <div class="p-4">
            <dl class="grid grid-cols-1 sm:grid-cols-[140px_1fr] gap-y-2 gap-x-4 text-sm-var m-0">
              <template v-for="row in meta" :key="row.key">
                <dt class="text-c-tx2">{{ row.key }}</dt>
                <dd class="m-0 tabular-nums" :class="row.mono ? 'mono text-xs-var' : ''">
                  {{ row.value }}
                </dd>
              </template>
            </dl>
          </div>
        </Card>

        <Card class="overflow-clip">
          <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
            <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Filesystem</h3>
          </div>
          <div class="p-4">
            <dl class="grid grid-cols-1 sm:grid-cols-[140px_1fr] gap-y-2 gap-x-4 text-sm-var m-0">
              <template v-for="row in paths" :key="row.key">
                <dt class="text-c-tx2">{{ row.key }}</dt>
                <dd class="m-0 mono text-xs-var break-all">{{ row.value }}</dd>
              </template>
            </dl>
          </div>
        </Card>
      </div>

      <div class="flex flex-col gap-3">
        <Card class="overflow-clip">
          <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
            <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Runtime</h3>
            <span class="text-xs-var text-c-tx3 mono">{{ site.pid ? `PID ${site.pid}` : '' }}</span>
          </div>
          <div class="p-4">
            <div class="grid grid-cols-2 gap-x-2 gap-y-3.5">
              <div v-for="stat in runtime" :key="stat.label">
                <div class="text-c-tx2 text-xs-var uppercase tracking-[0.06em]">
                  {{ stat.label }}
                </div>
                <div class="text-xl font-semibold tracking-[-0.02em] tabular-nums">
                  {{ stat.value
                  }}<span class="text-xs text-c-tx3 font-medium"> {{ stat.unit }}</span>
                </div>
              </div>
            </div>
          </div>
        </Card>
      </div>
    </div>

    <OutputDialog
      v-if="showConfig"
      title="Nginx configuration"
      :subtitle="site.configPath"
      :content="configContent"
      icon="file-text"
      :wrap="false"
      @close="showConfig = false"
    />

    <OutputDialog
      v-if="showLogs"
      title="Site logs"
      subtitle="Tail of recent access & error output"
      :content="logsContent"
      :download-name="logsFilename"
      ansi
      @close="showLogs = false"
    />
  </section>

  <section v-else class="text-c-tx2 text-sm-var">Site not found.</section>
</template>
