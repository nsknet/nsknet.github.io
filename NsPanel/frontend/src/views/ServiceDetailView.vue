<script setup lang="ts">
/** One systemd unit: configuration, lifecycle actions, diagnostics, deletion. */
import { storeToRefs } from 'pinia';
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';

import { fetchData } from '@/api/client';
import CloudflareTokenHelp from '@/components/CloudflareTokenHelp.vue';
import OutputDialog from '@/components/OutputDialog.vue';
import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import LIcon from '@/components/ui/LIcon.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useServicesStore } from '@/stores/services';
import { useSystemStore } from '@/stores/system';
import { useUiStore } from '@/stores/ui';

const props = defineProps<{ name: string }>();

const router = useRouter();
const ui = useUiStore();
const { run } = useJobRunner();
const servicesStore = useServicesStore();
const { services } = storeToRefs(servicesStore);
const { host } = storeToRefs(useSystemStore());

const isEditingUnit = ref(false);
const editableUnitContent = ref('');
const showOutput = ref(false);
const outputTitle = ref('');
const outputContent = ref('');
const showTunnelDelete = ref(false);
const tunnelDeleteToken = ref('');
const tunnelDeleteSubmitting = ref(false);

const service = computed(() => servicesStore.byName(props.name) ?? services.value[0]);

/** Set only for cloudflared.<hostname> units the panel created. */
const tunnel = computed(() => service.value?.tunnel ?? null);

const tunnelMeta = computed(() => {
  const t = tunnel.value;
  if (!t) return [];
  return [
    { key: 'Hostname', value: t.hostname, mono: true },
    { key: 'Public URL', value: t.public_url, link: true },
    { key: 'Local service', value: t.service_url, mono: true },
    { key: 'Tunnel name', value: t.tunnel_name || '—', mono: true },
    { key: 'Tunnel ID', value: t.tunnel_id, mono: true, wrap: true },
    { key: 'Zone', value: t.zone || '—', mono: true },
  ];
});

const meta = computed(() => {
  const s = service.value;
  if (!s) return [];
  // The tunnel token lives in ExecStart — mask it here (still visible in Edit unit file).
  const command = tunnel.value ? s.cmd.replace(/(--token\s+)\S+/, '$1••••••') : s.cmd;
  const restart = s.restart ? `${s.restart} / ${s.restartSec ?? '—'}s` : '—';
  return [
    { key: 'Command', value: command || '—', mono: true, wrap: true },
    { key: 'Working dir', value: s.workingDir || '—', mono: true },
    { key: 'User', value: s.user || 'root', mono: true },
    { key: 'Restart policy', value: restart, mono: false },
    { key: 'Syslog id', value: s.syslogId || s.name, mono: true },
    { key: 'Last modified', value: s.modified || '—', mono: false },
    { key: 'Unit file', value: s.path || '—', mono: true, wrap: true },
  ];
});

const runtime = computed(() => {
  const s = service.value;
  const running = s?.status === 'active';
  return [
    { label: 'Memory', value: running && s?.mem != null ? s.mem.toFixed(1) : '0.0', unit: 'MB' },
    { label: 'CPU', value: running && s?.cpu != null ? s.cpu.toFixed(1) : '0.0', unit: '%' },
  ];
});

function openEditModal(): void {
  if (!service.value) return;
  editableUnitContent.value = service.value.content;
  isEditingUnit.value = true;
}

function saveUnitFile(): void {
  if (!service.value) return;
  isEditingUnit.value = false;
  void run(
    `/api/v1/services/${service.value.name}/edit`,
    { content: editableUnitContent.value },
    { title: `Saving & restarting ${service.value.name}` },
  );
}

function runServiceAction(action: string): void {
  if (!service.value) return;
  const title = action.charAt(0).toUpperCase() + action.slice(1);
  void run(
    `/api/v1/services/${service.value.name}/${action}`,
    {},
    { title: `${title}ing service ${service.value.name}` },
  );
}

async function viewOutput(kind: 'status' | 'logs'): Promise<void> {
  if (!service.value) return;
  try {
    outputContent.value = await fetchData<string>(`/api/v1/services/${service.value.name}/${kind}`);
    outputTitle.value = kind === 'status' ? 'systemctl status' : 'journalctl output';
    showOutput.value = true;
  } catch (error) {
    ui.addToast({
      t: `Failed to fetch ${kind}`,
      d: error instanceof Error ? error.message : String(error),
      k: 'danger',
    });
  }
}

function deleteService(): void {
  const name = service.value?.name;
  if (!name) return;
  ui.confirmThen(
    `Delete service '${name}'?`,
    'This will stop, disable, and remove the unit file permanently. This action cannot be undone.',
    () => {
      void run(
        `/api/v1/services/${name}/delete`,
        {},
        { title: `Deleting service ${name}`, onDone: () => router.push('/services') },
      );
    },
  );
}

function openTunnelDelete(): void {
  tunnelDeleteToken.value = '';
  showTunnelDelete.value = true;
}

async function submitTunnelDelete(event: Event): Promise<void> {
  event.preventDefault();
  const name = service.value?.name;
  const token = tunnelDeleteToken.value.trim();
  if (!name) return;
  if (!token) {
    ui.addToast({ t: 'Validation error', d: 'Cloudflare API token is required.', k: 'warn' });
    return;
  }

  tunnelDeleteSubmitting.value = true;
  try {
    const result = await run(
      `/api/v1/services/${name}/tunnel-delete`,
      { api_token: token },
      { title: `Deleting tunnel ${name}`, onDone: () => router.push('/services') },
    );
    if (result) showTunnelDelete.value = false;
  } finally {
    tunnelDeleteSubmitting.value = false;
  }
}

const outputFilename = computed(() => {
  const pad = (value: number) => String(value).padStart(2, '0');
  const safe = (value: string) => value.replace(/[^a-zA-Z0-9._-]/g, '_');
  const now = new Date();
  const stamp = `${pad(now.getMonth() + 1)}-${pad(now.getDate())}-${now.getFullYear()}-${pad(now.getHours())}-${pad(now.getMinutes())}-${pad(now.getSeconds())}`;
  return `${safe(host.value.hostname || 'server')}-${safe(service.value?.name ?? 'service')}-${stamp}.log`;
});
</script>

<template>
  <section v-if="service">
    <div class="flex items-end justify-between gap-6 mb-6">
      <div>
        <div class="flex items-center gap-2 mb-2">
          <Btn variant="ghost" sm @click="router.push('/services')">
            <LIcon name="arrow-left" /> Services
          </Btn>
        </div>
        <div class="flex items-center gap-3">
          <h1 class="text-[22px] font-semibold tracking-[-0.02em] mono">{{ service.name }}</h1>
          <StatusBadge :status="service.status" />
          <StatusBadge :status="service.autostart" />
          <Badge v-if="tunnel" tone="accent">tunnel</Badge>
        </div>
        <div v-if="service.desc" class="text-sm-var text-c-tx2 mt-1">{{ service.desc }}</div>
      </div>
    </div>

    <div class="grid grid-cols-1 lg:grid-cols-[2fr_1fr] gap-3">
      <div class="flex flex-col gap-3">
        <Card v-if="tunnel" class="overflow-clip">
          <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
            <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em] flex items-center gap-2">
              <LIcon name="cloud" is="width:14px;height:14px" /> Cloudflare Tunnel
            </h3>
            <span class="text-xs-var text-c-tx3 mono">cloud-managed · proxied CNAME</span>
          </div>
          <div class="p-4">
            <dl class="grid grid-cols-1 sm:grid-cols-[140px_1fr] gap-y-2.5 gap-x-4 text-sm-var m-0">
              <template v-for="row in tunnelMeta" :key="row.key">
                <dt class="text-c-tx2 font-medium">{{ row.key }}</dt>
                <dd
                  class="m-0 tabular-nums"
                  :class="[row.mono ? 'mono text-xs-var select-all' : '', row.wrap ? 'break-all' : '']"
                >
                  <a
                    v-if="row.link"
                    :href="row.value"
                    target="_blank"
                    rel="noopener"
                    class="text-c-actx underline underline-offset-2 inline-flex items-center gap-1"
                  >
                    {{ row.value }} <LIcon name="external-link" is="width:12px;height:12px" />
                  </a>
                  <template v-else>{{ row.value }}</template>
                </dd>
              </template>
            </dl>
          </div>
        </Card>

        <Card class="overflow-clip">
          <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
            <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Configuration</h3>
            <span class="text-xs-var text-c-tx3 mono">systemd unit configuration</span>
          </div>
          <div class="p-4">
            <dl class="grid grid-cols-1 sm:grid-cols-[140px_1fr] gap-y-2.5 gap-x-4 text-sm-var m-0">
              <template v-for="row in meta" :key="row.key">
                <dt class="text-c-tx2 font-medium">{{ row.key }}</dt>
                <dd
                  class="m-0 tabular-nums"
                  :class="[row.mono ? 'mono text-xs-var' : '', row.wrap ? 'break-all' : '']"
                >
                  {{ row.value }}
                </dd>
              </template>
            </dl>
          </div>

          <div class="px-4 py-3.5 border-t border-c-border">
            <div class="text-xs-var uppercase tracking-[0.06em] text-c-tx2 font-medium mb-2.5">
              Environment variables
            </div>
            <ul v-if="service.envVars.length" class="flex flex-col gap-1.5 m-0 p-0 list-none">
              <li
                v-for="variable in service.envVars"
                :key="variable"
                class="mono text-xs-var text-c-tx2 bg-c-subtle border border-c-border rounded px-2.5 py-1 select-all"
              >
                {{ variable }}
              </li>
            </ul>
            <div v-else class="text-xs-var text-c-tx3">None declared in the unit file.</div>
          </div>
        </Card>

        <Card class="overflow-clip">
          <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
            <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Actions</h3>
          </div>
          <div class="p-4 flex flex-wrap gap-2">
            <Btn
              variant="success"
              :disabled="service.status === 'active'"
              @click="runServiceAction('start')"
            >
              <LIcon name="play" /> Start
            </Btn>
            <Btn
              variant="danger"
              :disabled="service.status !== 'active'"
              @click="runServiceAction('stop')"
            >
              <LIcon name="square" /> Stop
            </Btn>
            <Btn variant="warn" @click="runServiceAction('restart')">
              <LIcon name="refresh-cw" /> Restart
            </Btn>

            <div class="hidden sm:block w-px bg-c-border mx-1 self-stretch"></div>

            <Btn
              variant="success"
              :disabled="service.autostart === 'enabled'"
              @click="runServiceAction('enable')"
            >
              <LIcon name="circle-check" /> Enable
            </Btn>
            <Btn
              variant="danger"
              :disabled="service.autostart === 'disabled'"
              @click="runServiceAction('disable')"
            >
              <LIcon name="ban" /> Disable
            </Btn>

            <div class="hidden sm:block w-px bg-c-border mx-1 self-stretch"></div>

            <Btn @click="openEditModal"><LIcon name="pencil" /> Edit unit file</Btn>
            <Btn variant="info" @click="viewOutput('status')"><LIcon name="info" /> Status</Btn>
            <Btn variant="info" @click="viewOutput('logs')">
              <LIcon name="scroll-text" /> Logs
            </Btn>
          </div>
        </Card>

        <Card tone="danger" class="overflow-clip">
          <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
            <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em] text-c-danger">
              Danger zone
            </h3>
          </div>
          <div class="p-4 flex items-center justify-between gap-4 flex-wrap">
            <div>
              <p class="m-0 text-sm-var font-medium">Delete this service</p>
              <p class="m-0 text-xs-var text-c-tx2 mt-0.5">
                Stops, disables, and removes the systemd unit file permanently.
              </p>
            </div>
            <Btn variant="danger" @click="deleteService">
              <LIcon name="trash-2" /> Delete service
            </Btn>
          </div>
          <div
            v-if="tunnel"
            class="px-4 pb-4 flex items-center justify-between gap-4 flex-wrap border-t border-c-border"
          >
            <div class="pt-4">
              <p class="m-0 text-sm-var font-medium">
                Delete service and remove the tunnel on Cloudflare
              </p>
              <p class="m-0 text-xs-var text-c-tx2 mt-0.5">
                Also deletes the DNS CNAME for <span class="mono">{{ tunnel.hostname }}</span> and
                the tunnel itself if no other hostnames use it. Requires your API token again.
              </p>
            </div>
            <Btn variant="danger" class="mt-4" @click="openTunnelDelete">
              <LIcon name="cloud-off" /> Delete + Cloudflare cleanup
            </Btn>
          </div>
        </Card>
      </div>

      <div class="flex flex-col gap-3">
        <Card class="overflow-clip">
          <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
            <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Runtime</h3>
          </div>
          <div class="p-4">
            <div class="grid grid-cols-2 gap-x-2 gap-y-3.5">
              <div v-for="stat in runtime" :key="stat.label">
                <div class="text-c-tx2 text-xs-var uppercase tracking-[0.06em] font-medium">
                  {{ stat.label }}
                </div>
                <div class="text-xl font-semibold tracking-[-0.02em] tabular-nums mt-0.5">
                  {{ stat.value
                  }}<span class="text-xs text-c-tx3 font-medium"> {{ stat.unit }}</span>
                </div>
              </div>
            </div>
          </div>
        </Card>
      </div>
    </div>

    <div
      v-if="showTunnelDelete"
      class="fixed inset-0 z-[250] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade"
      @click.self="!tunnelDeleteSubmitting && (showTunnelDelete = false)"
    >
      <div
        class="w-full max-w-[520px] max-h-[90vh] overflow-y-auto bg-c-card border border-c-border rounded-theme-lg shadow-lg animate-pop"
        role="dialog"
        aria-modal="true"
      >
        <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
          <div class="w-7 h-7 rounded-[7px] bg-c-dngsoft text-c-danger grid place-items-center">
            <LIcon name="cloud-off" is="width:14px;height:14px" />
          </div>
          <div>
            <div class="font-semibold text-sm-var">Delete tunnel on Cloudflare</div>
            <div class="text-xs-var text-c-tx2 mono">{{ service.name }}</div>
          </div>
          <Btn
            variant="ghost"
            sm
            square
            class="ml-auto"
            aria-label="Close"
            :disabled="tunnelDeleteSubmitting"
            @click="showTunnelDelete = false"
          >
            <LIcon name="x" />
          </Btn>
        </div>
        <form class="p-4 flex flex-col gap-3.5" @submit="submitTunnelDelete">
          <div class="text-sm-var text-c-tx2">
            This stops the service, removes the CNAME
            <span class="mono">{{ tunnel?.hostname }}</span
            >, drops its ingress rule, deletes the tunnel if nothing else uses it, then removes the
            local unit file. This cannot be undone.
          </div>
          <div class="flex flex-col gap-1">
            <div class="flex items-center justify-between">
              <label for="tun-del-token" class="text-sm-var font-medium text-c-tx">
                Cloudflare API token
              </label>
              <a
                href="https://dash.cloudflare.com/profile/api-tokens"
                target="_blank"
                rel="noopener noreferrer"
                class="text-[11px] text-c-actx hover:underline inline-flex items-center gap-1 font-medium"
              >
                <span>Get token</span>
                <LIcon name="external-link" is="width:11px;height:11px" />
              </a>
            </div>
            <input
              id="tun-del-token"
              v-model="tunnelDeleteToken"
              type="password"
              class="input mono"
              placeholder="Paste API token"
              autocomplete="off"
              required
            />
            <CloudflareTokenHelp note="Used once to delete the tunnel — not stored on the server." />
          </div>
          <div class="flex justify-end gap-2 mt-1">
            <Btn type="button" :disabled="tunnelDeleteSubmitting" @click="showTunnelDelete = false">
              Cancel
            </Btn>
            <Btn type="submit" variant="danger" :disabled="tunnelDeleteSubmitting">
              <LIcon name="trash-2" />
              {{ tunnelDeleteSubmitting ? 'Deleting…' : 'Delete everything' }}
            </Btn>
          </div>
        </form>
      </div>
    </div>

    <div
      v-if="isEditingUnit"
      class="fixed inset-0 z-[250] flex items-center justify-center bg-black/60 backdrop-blur-sm p-4 animate-fade"
      @click.self="isEditingUnit = false"
    >
      <div
        class="w-full max-w-3xl bg-c-card border border-c-border rounded-theme-lg shadow-lg flex flex-col max-h-[85vh] overflow-hidden animate-pop"
      >
        <div
          class="flex items-center justify-between px-5 py-3.5 border-b border-c-border shrink-0 bg-c-elev"
        >
          <div class="flex items-center gap-2">
            <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center">
              <LIcon name="pencil" is="width:14px;height:14px" />
            </div>
            <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em] mono">
              {{ service.name }}.service
            </h3>
          </div>
          <Btn variant="ghost" sm square aria-label="Close" @click="isEditingUnit = false">
            <LIcon name="x" />
          </Btn>
        </div>

        <div class="flex flex-col flex-1 min-h-0">
          <textarea
            v-model="editableUnitContent"
            spellcheck="false"
            class="flex-1 min-h-[360px] bg-zinc-950 mono text-xs text-zinc-300 p-5 resize-none outline-none border-0 leading-relaxed overflow-y-auto"
          ></textarea>

          <div
            class="px-5 py-3.5 border-t border-c-border bg-c-elev flex items-center justify-between shrink-0"
          >
            <span class="text-[10px] text-c-tx3 mono">{{ service.path }}</span>
            <div class="flex gap-2">
              <Btn @click="isEditingUnit = false">Cancel</Btn>
              <Btn variant="primary" @click="saveUnitFile">
                <LIcon name="check" /> Save &amp; restart
              </Btn>
            </div>
          </div>
        </div>
      </div>
    </div>

    <OutputDialog
      v-if="showOutput"
      :title="outputTitle"
      :subtitle="service.name"
      :content="outputContent"
      :download-name="outputFilename"
      ansi
      @close="showOutput = false"
    />
  </section>

  <section v-else class="text-c-tx2 text-sm-var">Service not found.</section>
</template>
