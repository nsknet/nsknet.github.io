<script setup lang="ts">
/** Panel-managed systemd units, plus the two creation dialogs (unit, tunnel). */
import { storeToRefs } from 'pinia';
import { computed, reactive, ref } from 'vue';
import { useRouter } from 'vue-router';

import type { Service } from '@/api/types';
import CloudflareTokenHelp from '@/components/CloudflareTokenHelp.vue';
import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import Skeleton from '@/components/ui/Skeleton.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useServicesStore } from '@/stores/services';
import { useSystemStore } from '@/stores/system';
import { useUiStore } from '@/stores/ui';

const router = useRouter();
const ui = useUiStore();
const system = useSystemStore();
const { run, reload } = useJobRunner();
const { services, loading } = storeToRefs(useServicesStore());
const { host } = storeToRefs(system);

// Public hostname: lowercase, at least two labels, no wildcard/underscore.
// Mirrors HOSTNAME_RE in features/cloudflare_tunnel.py (the backend is authoritative).
const TUNNEL_HOST =
  /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

const showCreate = ref(false);
const showTunnel = ref(false);
const tunnelSubmitting = ref(false);

const form = reactive({
  name: '',
  description: '',
  working_dir: '',
  command: '',
  user: 'root',
  env_vars: '',
});
const tunnelForm = reactive({ api_token: '', hostname: '', url: '' });

/** First non-loopback address, offered as a sample URL in the tunnel dialog. */
const urlChips = computed(() => {
  const lan = host.value.network.find((entry) => entry.ip && !entry.ip.startsWith('127.'));
  return lan ? ['http://localhost:5000', `http://${lan.ip}:5000`] : ['http://localhost:5000'];
});

function isTunnel(service: Service): boolean {
  return !!service.tunnel || service.name.startsWith('cloudflared.');
}

async function refresh(): Promise<void> {
  await reload();
  ui.addToast({ t: 'Services refreshed', k: 'info' });
}

function openCreate(): void {
  Object.assign(form, {
    name: '',
    description: '',
    working_dir: '',
    command: '',
    user: 'root',
    env_vars: '',
  });
  showCreate.value = true;
}

function submitCreate(event: Event): void {
  event.preventDefault();
  if (!form.name.trim() || !form.working_dir.trim() || !form.command.trim()) {
    ui.addToast({
      t: 'Validation error',
      d: 'Name, directory, and command are required.',
      k: 'warn',
    });
    return;
  }
  showCreate.value = false;
  void run(
    '/api/v1/services/create',
    {
      name: form.name.trim(),
      description: form.description.trim(),
      working_dir: form.working_dir.trim(),
      command: form.command.trim(),
      user: form.user.trim() || 'root',
      env_vars: form.env_vars.trim(),
    },
    { title: `Registering service ${form.name.trim()}` },
  );
}

function openTunnel(): void {
  Object.assign(tunnelForm, { api_token: '', hostname: '', url: '' });
  showTunnel.value = true;
  // The sample-URL chip needs the host's interfaces.
  if (!host.value.network.length) void system.load();
}

async function submitTunnel(event: Event): Promise<void> {
  event.preventDefault();
  const token = tunnelForm.api_token.trim();
  const hostname = tunnelForm.hostname
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\//, '')
    .replace(/\/+$/, '')
    .replace(/\.$/, '');
  const url = tunnelForm.url.trim();

  if (!token) {
    ui.addToast({ t: 'Validation error', d: 'Cloudflare API token is required.', k: 'warn' });
    return;
  }
  if (!TUNNEL_HOST.test(hostname)) {
    ui.addToast({
      t: 'Invalid hostname',
      d: 'Enter a public hostname such as app.example.com.',
      k: 'warn',
    });
    return;
  }
  if (!url) {
    ui.addToast({ t: 'Validation error', d: 'Local service URL is required.', k: 'warn' });
    return;
  }

  tunnelSubmitting.value = true;
  try {
    const result = await run(
      '/api/v1/services/tunnels/create',
      { api_token: token, hostname, url },
      { title: `Creating tunnel ${hostname}` },
    );
    if (result) showTunnel.value = false;
  } finally {
    tunnelSubmitting.value = false;
  }
}
</script>

<template>
  <section>
    <PageHeader title="Services">
      <template #subtitle>
        {{ services.length }} custom systemd services in
        <span class="mono">/var/www/services/</span>
      </template>
      <Btn @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
      <Btn @click="openTunnel"><LIcon name="cloud" /> New tunnel</Btn>
      <Btn variant="primary" @click="openCreate"><LIcon name="plus" /> New service</Btn>
    </PageHeader>

    <Card class="overflow-clip">
      <table class="tbl">
        <thead>
          <tr>
            <th>Name</th>
            <th>Status</th>
            <th>Autostart</th>
            <th>Mem (MB)</th>
            <th>CPU (%)</th>
            <th>Description</th>
            <th>Last edit</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="loading && !services.length">
            <td colspan="8" style="padding: 0; height: auto"><Skeleton :count="4" /></td>
          </tr>
          <tr v-else-if="!services.length">
            <td colspan="8" class="muted" style="text-align: center; padding: 32px 0">
              No custom services yet — use <strong>New service</strong> to register one.
            </td>
          </tr>
          <tr
            v-for="service in services"
            :key="service.name"
            class="row-click"
            @click="router.push(`/services/${service.name}`)"
          >
            <td>
              <div class="flex items-center gap-2">
                <strong>{{ service.name }}</strong>
                <Badge v-if="isTunnel(service)" tone="accent">tunnel</Badge>
              </div>
              <!-- Tunnel units carry the tunnel token in ExecStart — show the route instead. -->
              <div class="text-xs-var text-c-tx3 mt-0.5 mono">
                {{
                  service.tunnel
                    ? `${service.tunnel.hostname} → ${service.tunnel.service_url}`
                    : service.cmd
                }}
              </div>
            </td>
            <td><StatusBadge :status="service.status" /></td>
            <td><StatusBadge :status="service.autostart" /></td>
            <td class="num">{{ service.mem != null ? service.mem.toFixed(1) : '—' }}</td>
            <td class="num">{{ service.cpu != null ? service.cpu.toFixed(1) : '—' }}</td>
            <td class="muted" style="white-space: normal">{{ service.desc }}</td>
            <td class="muted">{{ service.modified }}</td>
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

    <div
      v-if="showCreate"
      class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade"
      @click.self="showCreate = false"
    >
      <div
        class="w-full max-w-[480px] bg-c-card border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop"
        role="dialog"
        aria-modal="true"
      >
        <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
          <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center">
            <LIcon name="server" is="width:14px;height:14px" />
          </div>
          <div>
            <div class="font-semibold text-sm-var">Register new systemd service</div>
            <div class="text-xs-var text-c-tx2">Unit file written to /var/www/services/</div>
          </div>
          <Btn
            variant="ghost"
            sm
            square
            class="ml-auto"
            aria-label="Close"
            @click="showCreate = false"
          >
            <LIcon name="x" />
          </Btn>
        </div>

        <form class="p-4 flex flex-col gap-3.5 animate-fade" @submit="submitCreate">
          <div class="flex flex-col gap-1">
            <label for="svc-name" class="text-sm-var font-medium text-c-tx">Service name</label>
            <input
              id="svc-name"
              v-model="form.name"
              class="input mono"
              placeholder="e.g. queue-worker"
              required
            />
            <div class="text-[10px] text-c-tx2">
              Used as the systemd service name (no spaces).
            </div>
          </div>

          <div class="flex flex-col gap-1">
            <label for="svc-desc" class="text-sm-var font-medium text-c-tx">Description</label>
            <input
              id="svc-desc"
              v-model="form.description"
              class="input"
              placeholder="e.g. Background task processing queue"
            />
          </div>

          <div class="flex flex-col gap-1">
            <label for="svc-dir" class="text-sm-var font-medium text-c-tx">Working directory</label>
            <input
              id="svc-dir"
              v-model="form.working_dir"
              class="input mono"
              placeholder="e.g. /var/www/services/queue-worker"
              required
            />
          </div>

          <div class="flex flex-col gap-1">
            <label for="svc-cmd" class="text-sm-var font-medium text-c-tx">ExecStart command</label>
            <input
              id="svc-cmd"
              v-model="form.command"
              class="input mono"
              placeholder="e.g. /usr/bin/dotnet App.dll"
              required
            />
          </div>

          <div class="flex flex-col gap-1">
            <label for="svc-user" class="text-sm-var font-medium text-c-tx">Execution user</label>
            <input id="svc-user" v-model="form.user" class="input mono" placeholder="root" />
          </div>

          <div class="flex flex-col gap-1">
            <label for="svc-env" class="text-sm-var font-medium text-c-tx">
              Environment variables <span class="text-c-tx3 font-normal">· one per line</span>
            </label>
            <textarea
              id="svc-env"
              v-model="form.env_vars"
              class="input mono h-16 py-1.5 resize-none leading-normal"
              placeholder="NODE_ENV=production&#10;PORT=5000"
            ></textarea>
          </div>

          <div class="flex justify-end gap-2 mt-1 shrink-0">
            <Btn type="button" @click="showCreate = false">Cancel</Btn>
            <Btn type="submit" variant="primary"><LIcon name="rocket" /> Register &amp; start</Btn>
          </div>
        </form>
      </div>
    </div>

    <div
      v-if="showTunnel"
      class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade"
      @click.self="!tunnelSubmitting && (showTunnel = false)"
    >
      <div
        class="w-full max-w-[520px] max-h-[90vh] overflow-y-auto bg-c-card border border-c-border rounded-theme-lg shadow-lg animate-pop"
        role="dialog"
        aria-modal="true"
      >
        <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
          <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center">
            <LIcon name="cloud" is="width:14px;height:14px" />
          </div>
          <div>
            <div class="font-semibold text-sm-var">Create Cloudflare Tunnel</div>
            <div class="text-xs-var text-c-tx2">
              Registers <span class="mono">cloudflared.&lt;hostname&gt;</span> as a systemd service
            </div>
          </div>
          <Btn
            variant="ghost"
            sm
            square
            class="ml-auto"
            aria-label="Close"
            :disabled="tunnelSubmitting"
            @click="showTunnel = false"
          >
            <LIcon name="x" />
          </Btn>
        </div>

        <form class="p-4 flex flex-col gap-3.5 animate-fade" @submit="submitTunnel">
          <div class="flex flex-col gap-1">
            <div class="flex items-center justify-between">
              <label for="tun-token" class="text-sm-var font-medium text-c-tx">
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
              id="tun-token"
              v-model="tunnelForm.api_token"
              type="password"
              class="input mono"
              placeholder="Paste API token"
              autocomplete="off"
              required
            />
            <CloudflareTokenHelp note="Used once to create the tunnel — not stored on the server." />
          </div>

          <div class="flex flex-col gap-1">
            <label for="tun-host" class="text-sm-var font-medium text-c-tx">Hostname</label>
            <input
              id="tun-host"
              v-model="tunnelForm.hostname"
              class="input mono"
              placeholder="dev.example.com"
              autocomplete="off"
              required
            />
            <div class="text-[10px] text-c-tx2">
              Must belong to a zone on this Cloudflare account. An existing DNS record for this name
              will be replaced.
            </div>
          </div>

          <div class="flex flex-col gap-1">
            <label for="tun-url" class="text-sm-var font-medium text-c-tx">Local service URL</label>
            <input
              id="tun-url"
              v-model="tunnelForm.url"
              class="input mono"
              placeholder="http://localhost:5000"
              autocomplete="off"
              required
            />
            <div class="flex items-center gap-1.5 flex-wrap mt-0.5">
              <span class="text-[10px] text-c-tx3">Samples:</span>
              <button
                v-for="chip in urlChips"
                :key="chip"
                type="button"
                class="text-[10px] mono px-2 py-0.5 rounded-full border border-c-border bg-c-subtle text-c-tx2 hover:text-c-tx hover:bg-c-hover transition-colors"
                @click="tunnelForm.url = chip"
              >
                {{ chip }}
              </button>
            </div>
            <div class="text-[10px] text-c-tx2">
              Accepts a bare port (5000), host:port, or a full http/https URL.
            </div>
          </div>

          <div class="flex justify-end gap-2 mt-1 shrink-0">
            <Btn type="button" :disabled="tunnelSubmitting" @click="showTunnel = false">Cancel</Btn>
            <Btn type="submit" variant="primary" :disabled="tunnelSubmitting">
              <LIcon v-if="!tunnelSubmitting" name="cloud" />
              {{ tunnelSubmitting ? 'Creating…' : 'Create & start' }}
            </Btn>
          </div>
        </form>
      </div>
    </div>
  </section>
</template>
