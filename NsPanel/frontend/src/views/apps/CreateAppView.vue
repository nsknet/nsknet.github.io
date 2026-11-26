<script setup lang="ts">
/** New app: a site (static, reverse proxy, .NET), a systemd service or a
 *  Cloudflare tunnel. Pick the kind, fill in the form; errors show inline under
 *  each field, and a successful job opens the new app's page. */
import { storeToRefs } from 'pinia';
import { computed, nextTick, reactive, ref, watch } from 'vue';
import { RouterLink, useRouter } from 'vue-router';

import ChoiceCards from '@/components/apps/ChoiceCards.vue';
import CloudflareTokenHelp from '@/components/CloudflareTokenHelp.vue';
import Alert from '@/components/ui/Alert.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import CardHeader from '@/components/ui/CardHeader.vue';
import Field from '@/components/ui/Field.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import PasswordField from '@/components/ui/PasswordField.vue';
import SubnetPicker from '@/components/ui/SubnetPicker.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useQueryRef } from '@/composables/useQueryRef';
import { useServicesStore } from '@/stores/services';
import { useSitesStore } from '@/stores/sites';
import { useSystemStore } from '@/stores/system';
import { useToolsStore } from '@/stores/tools';
import { apiPath } from '@/utils/format';
import { ANY_IP } from '@/utils/secrets';
import * as v from '@/utils/validate';

const router = useRouter();
const { run } = useJobRunner();
const sitesStore = useSitesStore();
const servicesStore = useServicesStore();
const toolsStore = useToolsStore();
const { host } = storeToRefs(useSystemStore());

// ── Which kind of app ─────────────────────────────────────────────────────
const KINDS = ['static', 'proxy', 'dotnet', 'service', 'tunnel'] as const;
type Kind = (typeof KINDS)[number];
const kind = useQueryRef<Kind>('kind', 'proxy', KINDS);
const kindModel = computed<string>({ get: () => kind.value, set: (value) => (kind.value = value as Kind) });

const KIND_OPTIONS = [
  { value: 'static', label: 'Static site', hint: 'nginx serves files from a folder.', icon: 'file-code' },
  { value: 'proxy', label: 'Reverse proxy', hint: 'nginx forwards to a URL.', icon: 'arrow-right-left' },
  { value: 'dotnet', label: '.NET site', hint: 'A Kestrel app behind nginx.', icon: 'hexagon' },
  { value: 'service', label: 'Systemd service', hint: 'Any long-running command.', icon: 'server' },
  { value: 'tunnel', label: 'Cloudflare tunnel', hint: 'Publish a local URL via Cloudflare.', icon: 'cloud' },
];

const isSite = computed(() => kind.value === 'static' || kind.value === 'proxy' || kind.value === 'dotnet');

// ── Shared form plumbing ──────────────────────────────────────────────────
const formEl = ref<HTMLFormElement | null>(null);
const touched = reactive<Record<string, boolean>>({});
const submitted = ref(false);
const pending = ref(false);

function touch(field: string): void {
  touched[field] = true;
}

/** The error to show under a field: only once it was left or the form was submitted. */
function shown(errors: Record<string, string>, field: string): string {
  return touched[field] || submitted.value ? (errors[field] ?? '') : '';
}

function hasErrors(errors: Record<string, string>): boolean {
  return Object.values(errors).some(Boolean);
}

async function focusFirstError(): Promise<void> {
  await nextTick();
  formEl.value?.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus();
}

// ── Ports already taken ───────────────────────────────────────────────────
const portOwners = computed(() => {
  const owners = new Map<number, string>();
  for (const owner of sitesStore.portOwners) owners.set(owner.port, owner.role);
  for (const tool of toolsStore.tools) {
    if (!tool.installed || !tool.ports) continue;
    for (const part of tool.ports.split(',')) {
      const port = Number(part.trim());
      if (port && !owners.has(port)) owners.set(port, `${tool.name}`);
    }
  }
  return owners;
});

function portError(value: string, other?: { value: string; label: string }): string {
  const rule = v.port(value, { min: 1024, max: 65535 });
  if (rule) return rule;
  const port = Number(value.trim());
  const owner = portOwners.value.get(port);
  if (owner) return `Port ${port} is already used (${owner}).`;
  if (other && other.value.trim() && Number(other.value.trim()) === port) {
    return `Port ${port} is already the ${other.label}.`;
  }
  return '';
}

function freePort(exclude: string[] = []): string {
  const taken = new Set([...portOwners.value.keys(), ...exclude.map(Number)]);
  for (let tries = 0; tries < 200; tries++) {
    const port = 5000 + Math.floor(Math.random() * 45000);
    if (!taken.has(port)) return String(port);
  }
  return '';
}

// ── Site (static, proxy, .NET) ────────────────────────────────────────────
const ENVIRONMENTS = ['Production', 'Staging', 'Development', 'Test', 'Demo'];
const PROXY_TARGET = /^https?:\/\/[a-zA-Z0-9.\-:/]+$/;
const DLL = /^[a-zA-Z0-9._-]+$/;
const PRIVATE_SUBNETS = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'];

const site = reactive({
  accessKind: 'domain' as 'domain' | 'port',
  domain: '',
  autoSsl: false,
  sslEmail: '',
  port: '',
  name: '',
  subnets: Object.fromEntries(PRIVATE_SUBNETS.map((cidr) => [cidr, true])) as Record<string, boolean>,
  proxyTarget: 'http://127.0.0.1:5000',
  dll: '',
  internalPort: '',
  aspEnv: 'Production',
});

const ACCESS_OPTIONS = [
  { value: 'domain', label: 'Domain', hint: 'Served by hostname, e.g. app.example.com.', icon: 'globe' },
  { value: 'port', label: 'Port', hint: 'Served on its own port of this server.', icon: 'plug' },
];
const accessModel = computed<string>({
  get: () => site.accessKind,
  set: (value) => (site.accessKind = value as 'domain' | 'port'),
});

const siteName = computed(() => (site.accessKind === 'domain' ? site.domain.trim() : site.name.trim()));
const selectedSubnets = computed(() => Object.keys(site.subnets).filter((cidr) => site.subnets[cidr]));

function siteExists(name: string): string {
  return name && sitesStore.bySlug(name) ? `A site named ${name} already exists.` : '';
}

const siteErrors = computed<Record<string, string>>(() => {
  const errors: Record<string, string> = {};
  if (site.accessKind === 'domain') {
    errors.domain = v.first(
      v.required(site.domain, 'Domain'),
      v.domain(site.domain),
      siteExists(site.domain.trim()),
    );
    if (site.autoSsl) errors.sslEmail = v.email(site.sslEmail);
  } else {
    errors.port = portError(
      site.port,
      kind.value === 'dotnet' ? { value: site.internalPort, label: 'internal port' } : undefined,
    );
    errors.name = v.first(v.name(site.name, 'Site name'), siteExists(site.name.trim()));
    errors.subnets = selectedSubnets.value.length ? '' : 'Pick at least one network, or Any IP.';
  }
  if (kind.value === 'proxy') {
    errors.proxyTarget = v.first(
      v.required(site.proxyTarget, 'Proxy target'),
      PROXY_TARGET.test(site.proxyTarget.trim())
        ? ''
        : 'Use http(s)://host:port, e.g. http://127.0.0.1:5000.',
    );
  }
  if (kind.value === 'dotnet') {
    const dll = site.dll.trim().replace(/\.dll$/i, '');
    errors.dll = v.first(
      v.required(dll, 'DLL name'),
      DLL.test(dll) ? '' : 'Letters, digits, . _ - only, e.g. MyApp.dll.',
    );
    errors.internalPort = portError(
      site.internalPort,
      site.accessKind === 'port' ? { value: site.port, label: 'public port' } : undefined,
    );
  }
  return errors;
});

async function submitSite(): Promise<void> {
  submitted.value = true;
  if (hasErrors(siteErrors.value)) return focusFirstError();

  const name = siteName.value;
  const isPort = site.accessKind === 'port';
  const subnets = selectedSubnets.value.includes(ANY_IP) ? ANY_IP : selectedSubnets.value.join(',');
  pending.value = true;
  try {
    await run(
      '/api/v1/sites/create',
      {
        access_kind: site.accessKind,
        access_value: isPort ? site.port.trim() : site.domain.trim(),
        backend_type: kind.value,
        name,
        proxy_target: kind.value === 'proxy' ? site.proxyTarget.trim() : '',
        dll_name: kind.value === 'dotnet' ? site.dll.trim().replace(/\.dll$/i, '') : '',
        internal_port: kind.value === 'dotnet' ? site.internalPort.trim() : '',
        aspnetcore_env: site.aspEnv,
        auto_ssl: !isPort && site.autoSsl ? 'true' : 'false',
        ssl_email: !isPort && site.autoSsl ? site.sslEmail.trim() : '',
        allowed_subnets: isPort ? subnets : '',
      },
      { title: `Creating site ${name}`, onSuccess: () => void router.push(apiPath`/apps/site/${name}`) },
    );
  } finally {
    pending.value = false;
  }
}

// ── Systemd service ───────────────────────────────────────────────────────
const UNIX_USER = /^[a-z_][a-z0-9_-]{0,31}\$?$/;
const ENV_LINE = /^[A-Za-z_][A-Za-z0-9_]*=[^\r\n]*$/;

const service = reactive({
  name: '',
  description: '',
  workingDir: '',
  command: '',
  user: 'root',
  envVars: '',
});

function singleLine(value: string, what: string): string {
  return /[\r\n]/.test(value) ? `${what} must be a single line.` : '';
}

const serviceErrors = computed<Record<string, string>>(() => {
  const name = service.name.trim();
  const envProblem = service.envVars
    .split('\n')
    .map((line, index) => ({ line: line.trim(), number: index + 1 }))
    .find(({ line }) => line && !ENV_LINE.test(line));
  return {
    name: v.first(
      v.name(service.name, 'Service name'),
      name && servicesStore.byName(name) ? `A service named ${name} already exists.` : '',
    ),
    description: singleLine(service.description, 'Description'),
    workingDir: v.first(
      v.required(service.workingDir, 'Working directory'),
      service.workingDir.trim().startsWith('/') ? '' : 'Use an absolute path, e.g. /var/www/services/worker.',
    ),
    command: v.required(service.command, 'Command'),
    user: UNIX_USER.test(service.user.trim() || 'root') ? '' : 'Not a valid Unix user name, e.g. www-data.',
    envVars: envProblem ? `Line ${envProblem.number}: expected KEY=value.` : '',
  };
});

async function submitService(): Promise<void> {
  submitted.value = true;
  if (hasErrors(serviceErrors.value)) return focusFirstError();
  const name = service.name.trim();
  pending.value = true;
  try {
    await run(
      '/api/v1/services/create',
      {
        name,
        description: service.description.trim(),
        working_dir: service.workingDir.trim(),
        command: service.command.trim(),
        user: service.user.trim() || 'root',
        env_vars: service.envVars
          .split('\n')
          .map((line) => line.trim())
          .filter(Boolean)
          .join('\n'),
      },
      {
        title: `Registering service ${name}`,
        onSuccess: () => void router.push(apiPath`/apps/service/${name}`),
      },
    );
  } finally {
    pending.value = false;
  }
}

// ── Cloudflare tunnel ─────────────────────────────────────────────────────
// Mirrors HOSTNAME_RE in features/cloudflare_tunnel.py (the backend is authoritative).
const TUNNEL_HOST =
  /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

const tunnel = reactive({ token: '', hostname: '', url: '' });

const tunnelHost = computed(() =>
  tunnel.hostname
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\//, '')
    .replace(/\/+$/, '')
    .replace(/\.$/, ''),
);

const cloudflared = computed(() => toolsStore.tools.find((tool) => tool.id === 'cloudflared'));
const cloudflaredMissing = computed(() => toolsStore.loaded && !cloudflared.value?.installed);

const urlSamples = computed(() => {
  const lan = host.value.network.find((entry) => entry.ip && !entry.ip.startsWith('127.'));
  return lan ? ['http://localhost:5000', `http://${lan.ip}:5000`] : ['http://localhost:5000'];
});

const tunnelErrors = computed<Record<string, string>>(() => {
  const hostname = tunnelHost.value;
  return {
    token: v.required(tunnel.token, 'Cloudflare API token'),
    hostname: v.first(
      v.required(hostname, 'Hostname'),
      TUNNEL_HOST.test(hostname) ? '' : 'Enter a public hostname such as app.example.com.',
      servicesStore.byName(`cloudflared.${hostname}`) ? `A tunnel for ${hostname} already exists.` : '',
    ),
    url: v.first(
      v.required(tunnel.url, 'Local URL'),
      /\s/.test(tunnel.url.trim()) ? 'No spaces: a port (5000), host:port or http(s)://host:port.' : '',
    ),
  };
});

async function submitTunnel(): Promise<void> {
  submitted.value = true;
  if (hasErrors(tunnelErrors.value)) return focusFirstError();
  const hostname = tunnelHost.value;
  pending.value = true;
  try {
    await run(
      '/api/v1/services/tunnels/create',
      { api_token: tunnel.token.trim(), hostname, url: tunnel.url.trim() },
      {
        title: `Creating tunnel ${hostname}`,
        onSuccess: () => void router.push(apiPath`/apps/service/${`cloudflared.${hostname}`}`),
      },
    );
  } finally {
    pending.value = false;
  }
}

// ── Submit ────────────────────────────────────────────────────────────────
function submit(): void {
  if (pending.value) return;
  if (isSite.value) void submitSite();
  else if (kind.value === 'service') void submitService();
  else void submitTunnel();
}

const submitLabel = computed(() => {
  if (isSite.value) return 'Create site';
  return kind.value === 'service' ? 'Register & start' : 'Create tunnel';
});

/** Switching kind (by the cards or the URL) starts validation afresh; the fields themselves are kept. */
watch([kind, () => site.accessKind], () => {
  submitted.value = false;
  for (const key of Object.keys(touched)) delete touched[key];
});
</script>

<template>
  <section class="max-w-3xl">
    <PageHeader
      title="New app"
      subtitle="Each app is created by a job; its live output opens when you submit."
    />

    <form ref="formEl" class="flex flex-col gap-4" novalidate @submit.prevent="submit">
      <Card class="p-4">
        <ChoiceCards
          v-model="kindModel"
          legend="What are you creating?"
          :options="KIND_OPTIONS"
          grid="grid-cols-1 sm:grid-cols-2 lg:grid-cols-3"
        />
      </Card>

      <!-- ── Site ───────────────────────────────────────────────────── -->
      <template v-if="isSite">
        <Card>
          <CardHeader title="Access" icon="globe" />
          <div class="p-4 flex flex-col gap-4">
            <ChoiceCards v-model="accessModel" legend="How is it reached?" :options="ACCESS_OPTIONS" />

            <template v-if="site.accessKind === 'domain'">
              <Field
                v-slot="f"
                label="Domain"
                required
                :error="shown(siteErrors, 'domain')"
                help="Also the site's name. Its DNS should point to this server."
              >
                <input
                  :id="f.id"
                  v-model="site.domain"
                  class="input mono"
                  placeholder="app.example.com"
                  autocomplete="off"
                  autocapitalize="off"
                  spellcheck="false"
                  :aria-describedby="f.describedBy"
                  :aria-invalid="f.invalid"
                  @blur="touch('domain')"
                />
              </Field>

              <label class="flex items-start gap-2.5 cursor-pointer select-none">
                <input
                  v-model="site.autoSsl"
                  type="checkbox"
                  class="mt-0.5 w-4 h-4 accent-c-accent shrink-0"
                />
                <span class="flex flex-col gap-0.5">
                  <span class="text-sm-var font-medium">Get an SSL certificate (Let's Encrypt)</span>
                  <span class="text-xs-var text-c-tx2">
                    Runs certbot right after the site is created and redirects HTTP to HTTPS. The domain's DNS
                    must already point here, and port 80 must be reachable from the internet.
                  </span>
                </span>
              </label>

              <Field
                v-if="site.autoSsl"
                v-slot="f"
                label="E-mail for expiry notices"
                :error="shown(siteErrors, 'sslEmail')"
                help="Optional. Let's Encrypt writes here before a certificate expires."
              >
                <input
                  :id="f.id"
                  v-model="site.sslEmail"
                  type="email"
                  class="input"
                  placeholder="admin@example.com"
                  autocomplete="email"
                  :aria-describedby="f.describedBy"
                  :aria-invalid="f.invalid"
                  @blur="touch('sslEmail')"
                />
              </Field>
            </template>

            <template v-else>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <Field
                  v-slot="f"
                  label="Site name"
                  required
                  :error="shown(siteErrors, 'name')"
                  help="Letters, digits, . _ - — used for folders and the unit name."
                >
                  <input
                    :id="f.id"
                    v-model="site.name"
                    class="input mono"
                    placeholder="internal-app"
                    autocomplete="off"
                    autocapitalize="off"
                    spellcheck="false"
                    :aria-describedby="f.describedBy"
                    :aria-invalid="f.invalid"
                    @blur="touch('name')"
                  />
                </Field>
                <Field
                  v-slot="f"
                  label="Port"
                  required
                  :error="shown(siteErrors, 'port')"
                  help="1024–65535, not used by another app."
                >
                  <div class="flex gap-1.5">
                    <input
                      :id="f.id"
                      v-model="site.port"
                      class="input mono tabular-nums"
                      inputmode="numeric"
                      placeholder="8080"
                      autocomplete="off"
                      :aria-describedby="f.describedBy"
                      :aria-invalid="f.invalid"
                      @blur="touch('port')"
                    />
                    <Btn @click="((site.port = freePort([site.internalPort])), touch('port'))">
                      <LIcon name="dices" /> Free port
                    </Btn>
                  </div>
                </Field>
              </div>
              <div>
                <SubnetPicker v-model="site.subnets" legend="Open the port to" />
                <p
                  v-if="shown(siteErrors, 'subnets')"
                  class="m-0 mt-1.5 text-xs-var text-c-danger"
                  role="alert"
                >
                  {{ siteErrors.subnets }}
                </p>
              </div>
            </template>
          </div>
        </Card>

        <Card v-if="kind === 'proxy'">
          <CardHeader title="Upstream" icon="arrow-right-left" />
          <div class="p-4">
            <Field
              v-slot="f"
              label="Proxy target"
              required
              :error="shown(siteErrors, 'proxyTarget')"
              help="Where nginx forwards requests (proxy_pass)."
            >
              <input
                :id="f.id"
                v-model="site.proxyTarget"
                class="input mono"
                placeholder="http://127.0.0.1:5000"
                autocomplete="off"
                spellcheck="false"
                :aria-describedby="f.describedBy"
                :aria-invalid="f.invalid"
                @blur="touch('proxyTarget')"
              />
            </Field>
          </div>
        </Card>

        <Card v-if="kind === 'dotnet'">
          <CardHeader title=".NET app" icon="hexagon" />
          <div class="p-4 grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Field
              v-slot="f"
              label="DLL name"
              required
              :error="shown(siteErrors, 'dll')"
              help="The app's entry assembly; a sample app is deployed until you upload yours."
              class="sm:col-span-2"
            >
              <input
                :id="f.id"
                v-model="site.dll"
                class="input mono"
                placeholder="MyApp.dll"
                autocomplete="off"
                spellcheck="false"
                :aria-describedby="f.describedBy"
                :aria-invalid="f.invalid"
                @blur="touch('dll')"
              />
            </Field>
            <Field
              v-slot="f"
              label="Internal port"
              required
              :error="shown(siteErrors, 'internalPort')"
              help="Kestrel listens here; nginx proxies to it."
            >
              <div class="flex gap-1.5">
                <input
                  :id="f.id"
                  v-model="site.internalPort"
                  class="input mono tabular-nums"
                  inputmode="numeric"
                  placeholder="5021"
                  autocomplete="off"
                  :aria-describedby="f.describedBy"
                  :aria-invalid="f.invalid"
                  @blur="touch('internalPort')"
                />
                <Btn @click="((site.internalPort = freePort([site.port])), touch('internalPort'))">
                  <LIcon name="dices" /> Free port
                </Btn>
              </div>
            </Field>
            <Field v-slot="f" label="ASPNETCORE_ENVIRONMENT">
              <select :id="f.id" v-model="site.aspEnv" class="input" :aria-describedby="f.describedBy">
                <option v-for="value in ENVIRONMENTS" :key="value" :value="value">{{ value }}</option>
              </select>
            </Field>
          </div>
        </Card>
      </template>

      <!-- ── Systemd service ────────────────────────────────────────── -->
      <Card v-else-if="kind === 'service'">
        <CardHeader title="Service" icon="server" subtitle="Unit file in /var/www/services/" />
        <div class="p-4 grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Field
            v-slot="f"
            label="Name"
            required
            :error="shown(serviceErrors, 'name')"
            help="The systemd unit name, e.g. queue-worker."
          >
            <input
              :id="f.id"
              v-model="service.name"
              class="input mono"
              placeholder="queue-worker"
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
              :aria-describedby="f.describedBy"
              :aria-invalid="f.invalid"
              @blur="touch('name')"
            />
          </Field>
          <Field
            v-slot="f"
            label="Run as user"
            :error="shown(serviceErrors, 'user')"
            help="Defaults to root."
          >
            <input
              :id="f.id"
              v-model="service.user"
              class="input mono"
              placeholder="root"
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
              :aria-describedby="f.describedBy"
              :aria-invalid="f.invalid"
              @blur="touch('user')"
            />
          </Field>
          <Field
            v-slot="f"
            label="Description"
            :error="shown(serviceErrors, 'description')"
            class="sm:col-span-2"
          >
            <input
              :id="f.id"
              v-model="service.description"
              class="input"
              placeholder="Background job processor"
              autocomplete="off"
              :aria-describedby="f.describedBy"
              :aria-invalid="f.invalid"
              @blur="touch('description')"
            />
          </Field>
          <Field
            v-slot="f"
            label="Working directory"
            required
            :error="shown(serviceErrors, 'workingDir')"
            class="sm:col-span-2"
          >
            <input
              :id="f.id"
              v-model="service.workingDir"
              class="input mono"
              placeholder="/var/www/services/queue-worker"
              autocomplete="off"
              spellcheck="false"
              :aria-describedby="f.describedBy"
              :aria-invalid="f.invalid"
              @blur="touch('workingDir')"
            />
          </Field>
          <Field
            v-slot="f"
            label="Command"
            required
            :error="shown(serviceErrors, 'command')"
            help="ExecStart: use absolute paths, e.g. /usr/bin/dotnet Worker.dll."
            class="sm:col-span-2"
          >
            <input
              :id="f.id"
              v-model="service.command"
              class="input mono"
              placeholder="/usr/bin/node server.js"
              autocomplete="off"
              spellcheck="false"
              :aria-describedby="f.describedBy"
              :aria-invalid="f.invalid"
              @blur="touch('command')"
            />
          </Field>
          <Field
            v-slot="f"
            label="Environment variables"
            :error="shown(serviceErrors, 'envVars')"
            help="One KEY=value per line."
            class="sm:col-span-2"
          >
            <textarea
              :id="f.id"
              v-model="service.envVars"
              class="input mono"
              rows="4"
              :placeholder="'NODE_ENV=production\nPORT=5000'"
              spellcheck="false"
              :aria-describedby="f.describedBy"
              :aria-invalid="f.invalid"
              @blur="touch('envVars')"
            ></textarea>
          </Field>
        </div>
      </Card>

      <!-- ── Cloudflare tunnel ──────────────────────────────────────── -->
      <Card v-else>
        <CardHeader title="Cloudflare tunnel" icon="cloud" subtitle="Runs as cloudflared.<hostname>" />
        <div class="p-4 flex flex-col gap-4">
          <Alert v-if="cloudflaredMissing" tone="warn" title="cloudflared is not installed">
            Install it on the Tools screen first.
            <template #action>
              <Btn sm @click="router.push({ path: '/tools', query: { q: 'cloudflared' } })">Open Tools</Btn>
            </template>
          </Alert>

          <Field v-slot="f" label="Cloudflare API token" required :error="shown(tunnelErrors, 'token')">
            <PasswordField
              :id="f.id"
              v-model="tunnel.token"
              autocomplete="off"
              placeholder="Paste the API token"
              :described-by="f.describedBy"
              :invalid="f.invalid"
              @focusout="touch('token')"
            />
          </Field>
          <CloudflareTokenHelp note="Used once to create the tunnel — not stored on the server." />

          <Field
            v-slot="f"
            label="Public hostname"
            required
            :error="shown(tunnelErrors, 'hostname')"
            help="Must be in a zone of this Cloudflare account. An existing DNS record for it is replaced."
          >
            <input
              :id="f.id"
              v-model="tunnel.hostname"
              class="input mono"
              placeholder="app.example.com"
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
              :aria-describedby="f.describedBy"
              :aria-invalid="f.invalid"
              @blur="touch('hostname')"
            />
          </Field>

          <Field
            v-slot="f"
            label="Local URL"
            required
            :error="shown(tunnelErrors, 'url')"
            help="A port (5000), host:port, or a full http(s) URL on this server's network."
          >
            <input
              :id="f.id"
              v-model="tunnel.url"
              class="input mono"
              placeholder="http://localhost:5000"
              autocomplete="off"
              spellcheck="false"
              :aria-describedby="f.describedBy"
              :aria-invalid="f.invalid"
              @blur="touch('url')"
            />
          </Field>
          <div class="flex flex-wrap items-center gap-1.5 -mt-2">
            <span class="text-xs-var text-c-tx3">Examples:</span>
            <button
              v-for="sample in urlSamples"
              :key="sample"
              type="button"
              class="mono text-xs-var px-2 py-0.5 rounded-full border border-c-border bg-c-subtle text-c-tx2 hover:text-c-tx hover:bg-c-hover"
              @click="((tunnel.url = sample), touch('url'))"
            >
              {{ sample }}
            </button>
          </div>
        </div>
      </Card>

      <div class="flex flex-wrap justify-end gap-2">
        <Btn @click="router.push('/apps')">Cancel</Btn>
        <Btn
          type="submit"
          variant="primary"
          :loading="pending"
          :disabled="kind === 'tunnel' && cloudflaredMissing"
        >
          <LIcon v-if="!pending" name="rocket" /> {{ submitLabel }}
        </Btn>
      </div>
    </form>

    <p class="mt-4 text-xs-var text-c-tx3">
      Looking for databases or other software? Install them from
      <RouterLink to="/tools" class="text-c-actx underline underline-offset-2">Tools</RouterLink>.
    </p>
  </section>
</template>
