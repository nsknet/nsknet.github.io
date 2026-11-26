<script setup lang="ts">
/** One systemd unit (a service or a Cloudflare tunnel): details, logs and
 *  status output, the unit file with a reviewed editor, lifecycle and deletion. */
import { storeToRefs } from 'pinia';
import { computed, ref, watch } from 'vue';
import { RouterLink, useRoute, useRouter } from 'vue-router';

import { fmtCpu, fmtMem, logFileName, serviceStatusLabel } from '@/components/apps/appRows';
import TextPanel from '@/components/apps/TextPanel.vue';
import TunnelDeleteDialog from '@/components/apps/TunnelDeleteDialog.vue';
import UnitEditorDialog from '@/components/apps/UnitEditorDialog.vue';
import { useRemoteText } from '@/components/apps/useRemoteText';
import Alert from '@/components/ui/Alert.vue';
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
import { useServicesStore } from '@/stores/services';
import { useSitesStore } from '@/stores/sites';
import { useSystemStore } from '@/stores/system';
import { useUiStore } from '@/stores/ui';
import { apiPath } from '@/utils/format';

const route = useRoute();
const router = useRouter();
const ui = useUiStore();
const { run } = useJobRunner();
const servicesStore = useServicesStore();
const { loaded, loading, error } = storeToRefs(servicesStore);
const sitesStore = useSitesStore();
const { host } = storeToRefs(useSystemStore());

const name = computed(() => String(route.params.name ?? ''));
// Never fall back to another unit: a stale or mistyped URL must not put
// Stop/Delete buttons in front of a different service.
const service = computed(() => servicesStore.byName(name.value));
const tunnel = computed(() => service.value?.tunnel ?? null);
const running = computed(() => service.value?.status === 'active');
const statusLabel = computed(() => serviceStatusLabel(service.value?.status ?? ''));
/** The unit of a .NET site (same name) — known only if the sites list is loaded. */
const ownerSite = computed(() => (sitesStore.loaded ? sitesStore.bySlug(name.value) : undefined));
const ownerSiteLink = computed(() => apiPath`/apps/site/${name.value}`);

// ── Tabs ──────────────────────────────────────────────────────────────────
const TABS = ['overview', 'logs', 'config'] as const;
type Tab = (typeof TABS)[number];
const tab = useQueryRef<Tab>('tab', 'overview', TABS);
const tabModel = computed<string>({ get: () => tab.value, set: (value) => (tab.value = value as Tab) });
const tabItems: TabItem[] = [
  { key: 'overview', label: 'Overview', icon: 'info' },
  { key: 'logs', label: 'Logs', icon: 'scroll-text' },
  { key: 'config', label: 'Unit file', icon: 'file-code' },
];

const LOG_SOURCES = [
  { value: 'journal', label: 'Journal' },
  { value: 'status', label: 'systemctl status' },
];
const logSource = ref<'journal' | 'status'>('journal');
const logSourceModel = computed<string>({
  get: () => logSource.value,
  set: (value) => (logSource.value = value as 'journal' | 'status'),
});
const journal = useRemoteText(() => apiPath`/api/v1/services/${name.value}/logs`);
const status = useRemoteText(() => apiPath`/api/v1/services/${name.value}/status`);
const currentLog = computed(() => (logSource.value === 'journal' ? journal : status));

watch(
  [tab, logSource, service],
  ([current, , exists]) => {
    if (exists && current === 'logs') currentLog.value.ensure();
  },
  { immediate: true },
);

const logDownload = computed(() => logFileName(host.value.hostname, name.value, logSource.value));

// ── Details ───────────────────────────────────────────────────────────────
const details = computed<KeyValueItem[]>(() => {
  const s = service.value;
  if (!s) return [];
  const restart = s.restart ? `${s.restart}${s.restartSec ? `, after ${s.restartSec}s` : ''}` : '';
  return [
    { key: 'desc', label: 'Description', value: s.desc },
    { key: 'cmd', label: 'Command', value: s.cmd, mono: true, copy: true },
    { key: 'dir', label: 'Working dir', value: s.workingDir, mono: true, copy: true },
    { key: 'user', label: 'User', value: s.user || 'root', mono: true },
    { key: 'restart', label: 'Restart policy', value: restart },
    { key: 'syslog', label: 'Syslog id', value: s.syslogId || s.name, mono: true },
    { key: 'modified', label: 'Last modified', value: s.modified },
    { key: 'path', label: 'Unit file', value: s.path, mono: true, copy: true },
  ];
});

const tunnelDetails = computed<KeyValueItem[]>(() => {
  const t = tunnel.value;
  if (!t) return [];
  return [
    { key: 'public', label: 'Public URL', value: t.public_url },
    { key: 'local', label: 'Local service', value: t.service_url, mono: true, copy: true },
    { key: 'name', label: 'Tunnel name', value: t.tunnel_name, mono: true },
    { key: 'id', label: 'Tunnel ID', value: t.tunnel_id, mono: true, copy: true },
    { key: 'zone', label: 'Zone', value: t.zone, mono: true },
  ];
});

const runtime = computed<KeyValueItem[]>(() => {
  const s = service.value;
  if (!s) return [];
  return [
    { key: 'status', label: 'Status', value: statusLabel.value },
    { key: 'autostart', label: 'Autostart', value: s.autostart },
    { key: 'pid', label: 'PID', value: running.value ? s.pid : null, mono: true },
    { key: 'mem', label: 'Memory', value: fmtMem(s.mem, running.value) },
    { key: 'cpu', label: 'CPU', value: fmtCpu(s.cpu, running.value) },
  ];
});

// ── Actions ───────────────────────────────────────────────────────────────
function action(verb: string, title: string): void {
  void run(apiPath`/api/v1/services/${name.value}/${verb}`, {}, { title });
}

function stop(): void {
  ui.confirmThen(
    `Stop ${name.value}?`,
    tunnel.value
      ? `${tunnel.value.hostname} stops answering until the tunnel is started again.`
      : 'The process is stopped until you start it again (or the server reboots, if autostart is on).',
    () => action('stop', `Stopping ${name.value}`),
    { danger: true, confirmLabel: 'Stop service' },
  );
}

function disable(): void {
  ui.confirmThen(
    `Disable autostart for ${name.value}?`,
    'It keeps running now, but will not start again after a reboot.',
    () => action('disable', `Disabling ${name.value}`),
    { danger: true, confirmLabel: 'Disable autostart' },
  );
}

function deleteService(): void {
  const target = name.value;
  const details = ['Stops and disables the service', `Deletes ${service.value?.path || `${target}.service`}`];
  if (tunnel.value)
    details.push(`The tunnel and the DNS record for ${tunnel.value.hostname} stay on Cloudflare`);
  if (ownerSite.value) details.push(`The .NET site ${target} stops working`);
  ui.confirmThen(
    `Delete ${target}?`,
    'This cannot be undone.',
    () =>
      void run(
        apiPath`/api/v1/services/${target}/delete`,
        {},
        {
          title: `Deleting ${target}`,
          onSuccess: () => void router.push('/apps'),
        },
      ),
    { danger: true, confirmLabel: 'Delete service', typeToConfirm: target, details },
  );
}

const editing = ref(false);
const deletingTunnel = ref(false);
</script>

<template>
  <section v-if="service">
    <PageHeader :title="service.name">
      <template #title>
        <span class="mono truncate">{{ service.name }}</span>
        <TypeChip :type="service.isTunnel ? 'tunnel' : 'service'" />
        <StatusBadge :status="statusLabel" />
      </template>
      <template #subtitle>
        <template v-if="tunnel">
          <a
            :href="tunnel.public_url"
            target="_blank"
            rel="noopener noreferrer"
            class="mono text-c-actx underline underline-offset-2 inline-flex items-center gap-1"
          >
            {{ tunnel.hostname }}<span class="sr-only"> (opens in a new tab)</span>
            <LIcon is="width:13px;height:13px" name="external-link" />
          </a>
          <span class="mono"> → {{ tunnel.service_url }}</span>
        </template>
        <template v-else>{{ service.desc || 'systemd service' }}</template>
      </template>

      <Btn v-if="!running" variant="success" @click="action('start', `Starting ${service.name}`)">
        <LIcon name="play" /> Start
      </Btn>
      <Btn v-else variant="danger" @click="stop"><LIcon name="square" /> Stop</Btn>
      <Btn @click="action('restart', `Restarting ${service.name}`)"><LIcon name="rotate-cw" /> Restart</Btn>
      <Btn @click="editing = true"><LIcon name="square-pen" /> Edit unit</Btn>
    </PageHeader>

    <Alert v-if="ownerSite" tone="info" class="mb-4">
      This is the unit of the .NET site
      <RouterLink :to="ownerSiteLink" class="font-medium underline underline-offset-2">{{
        ownerSite.name
      }}</RouterLink>. Start and stop it from there; edit the unit here.
    </Alert>

    <Tabs v-model="tabModel" :items="tabItems" label="Service sections">
      <!-- Overview -->
      <div v-if="tab === 'overview'" class="grid grid-cols-1 lg:grid-cols-[3fr_2fr] gap-4 items-start">
        <div class="flex flex-col gap-4 min-w-0">
          <Card v-if="tunnel">
            <CardHeader
              title="Cloudflare tunnel"
              icon="cloud"
              subtitle="Proxied CNAME, managed on Cloudflare"
            />
            <div class="p-4">
              <KeyValueList :items="tunnelDetails">
                <template #value-public="{ item }">
                  <a
                    :href="String(item.value)"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="text-c-actx underline underline-offset-2 inline-flex items-center gap-1 break-all"
                  >
                    {{ item.value }}<span class="sr-only"> (opens in a new tab)</span>
                    <LIcon is="width:13px;height:13px;flex-shrink:0" name="external-link" />
                  </a>
                </template>
              </KeyValueList>
            </div>
          </Card>

          <Card>
            <CardHeader title="Details" icon="info" />
            <div class="p-4"><KeyValueList :items="details" /></div>
          </Card>

          <Card>
            <CardHeader
              title="Environment variables"
              icon="list"
              :subtitle="String(service.envVars.length)"
            />
            <div class="p-4">
              <ul v-if="service.envVars.length" class="m-0 p-0 list-none flex flex-col gap-1.5">
                <li
                  v-for="variable in service.envVars"
                  :key="variable"
                  class="mono text-xs-var text-c-tx2 bg-c-subtle border border-c-border rounded-theme-sm px-2.5 py-1.5 break-all"
                >
                  {{ variable }}
                </li>
              </ul>
              <p v-else class="m-0 text-sm-var text-c-tx2">None set in the unit file.</p>
            </div>
          </Card>
        </div>

        <div class="flex flex-col gap-4 min-w-0">
          <Card>
            <CardHeader title="Runtime" icon="activity" />
            <div class="p-4 flex flex-col gap-4">
              <KeyValueList :items="runtime" label-width="100px">
                <template #value-status="{ item }"><StatusBadge :status="String(item.value)" /></template>
                <template #value-autostart="{ item }"
                  ><StatusBadge :status="String(item.value || 'unknown')"
                /></template>
              </KeyValueList>
              <div class="flex flex-wrap gap-2 pt-3 border-t border-c-border">
                <Btn
                  v-if="service.autostart !== 'enabled'"
                  sm
                  @click="action('enable', `Enabling ${service.name}`)"
                >
                  <LIcon name="circle-check" /> Enable autostart
                </Btn>
                <Btn v-else sm variant="danger" @click="disable"><LIcon name="ban" /> Disable autostart</Btn>
              </div>
            </div>
          </Card>

          <Card tone="danger">
            <CardHeader title="Danger zone" icon="triangle-alert" />
            <div class="p-4 flex flex-col gap-4">
              <div v-if="tunnel" class="flex flex-col gap-2">
                <p class="m-0 text-sm-var text-c-tx2">
                  Delete the service <em>and</em> its tunnel, DNS record and ingress rule on Cloudflare. Needs
                  your API token.
                </p>
                <div>
                  <Btn variant="danger" @click="deletingTunnel = true">
                    <LIcon name="cloud-off" /> Delete with Cloudflare cleanup
                  </Btn>
                </div>
              </div>
              <div class="flex flex-col gap-2" :class="tunnel ? 'pt-4 border-t border-c-border' : ''">
                <p class="m-0 text-sm-var text-c-tx2">
                  Stop, disable and remove the unit file{{
                    tunnel ? ' only — Cloudflare is left as it is' : ''
                  }}.
                </p>
                <div>
                  <Btn variant="danger" @click="deleteService">
                    <LIcon name="trash-2" /> {{ tunnel ? 'Delete local service only' : 'Delete service' }}
                  </Btn>
                </div>
              </div>
            </div>
          </Card>
        </div>
      </div>

      <!-- Logs -->
      <TextPanel
        v-else-if="tab === 'logs'"
        :label="logSource === 'journal' ? 'Journal' : 'systemctl status'"
        :text="currentLog.text.value"
        :loading="currentLog.loading.value"
        :error="currentLog.error.value"
        :download-name="logDownload"
        @refresh="currentLog.load()"
      >
        <template #toolbar>
          <FilterPills v-model="logSourceModel" :options="LOG_SOURCES" label="Output" />
        </template>
      </TextPanel>

      <!-- Unit file -->
      <TextPanel v-else label="Unit file" :text="service.content" :refreshable="false" :wrap="false">
        <template #toolbar>
          <span class="mono text-xs-var text-c-tx2 truncate min-w-0">{{ service.path }}</span>
          <Btn sm variant="primary" @click="editing = true"><LIcon name="square-pen" /> Edit</Btn>
        </template>
      </TextPanel>
    </Tabs>

    <UnitEditorDialog
      v-if="editing"
      :name="service.name"
      :content="service.content"
      :path="service.path"
      @close="editing = false"
    />
    <TunnelDeleteDialog
      v-if="deletingTunnel && tunnel"
      :name="service.name"
      :tunnel="tunnel"
      @close="deletingTunnel = false"
    />
  </section>

  <section v-else-if="error && !loaded">
    <Card><ErrorState :message="error" :retrying="loading" @retry="servicesStore.load()" /></Card>
  </section>

  <section v-else-if="!loaded" aria-busy="true">
    <div class="skeleton h-7 w-64 mb-6"></div>
    <Skeleton variant="cards" :count="2" />
  </section>

  <section v-else>
    <Card>
      <EmptyState icon="server" title="Service not found" :hint="`No unit named ${name} exists.`" />
      <div class="flex justify-center pb-6">
        <Btn sm @click="router.push('/apps')"><LIcon name="arrow-left" /> All apps</Btn>
      </div>
    </Card>
  </section>
</template>
