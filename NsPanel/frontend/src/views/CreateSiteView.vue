<script setup lang="ts">
/** The create-site form: access channel, backend type, and per-type fields. */
import { computed, ref, watch } from 'vue';
import { useRouter } from 'vue-router';

import Btn from '@/components/ui/Btn.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import { useJobRunner } from '@/composables/useJobs';

const router = useRouter();
const { run } = useJobRunner();

const channel = ref<'domain' | 'port'>('domain');
const backend = ref<'static' | 'proxy' | 'dotnet'>('proxy');
const autoSsl = ref(false);

const domain = ref('');
const port = ref('7842');
const siteName = ref('');
const proxy = ref('http://127.0.0.1:5555');
const dll = ref('');
const internal = ref('5021');
const env = ref('Production');

const ENVIRONMENTS = ['Production', 'Development', 'Test', 'Demo', 'Staging'];

const CHANNELS = [
  {
    key: 'domain' as const,
    icon: 'globe',
    label: 'Domain',
    hint: 'Bind by hostname (HTTP host header).',
  },
  { key: 'port' as const, icon: 'plug', label: 'Port', hint: 'Expose on a public port number.' },
];

const BACKENDS = [
  { key: 'static' as const, icon: 'file-code', label: 'Static', hint: 'Serve files from /publish.' },
  {
    key: 'proxy' as const,
    icon: 'arrow-right-left',
    label: 'Proxy',
    hint: 'Forward to an upstream URL.',
  },
  {
    key: 'dotnet' as const,
    icon: 'hexagon',
    label: '.NET Core',
    hint: 'Run a Kestrel service behind Nginx.',
  },
];

const resolvedName = computed(() => (channel.value === 'domain' ? domain.value : siteName.value));

// Suggest a DLL name from the domain the first time .NET is picked.
watch(backend, (value) => {
  if (value === 'dotnet' && !dll.value) {
    dll.value = domain.value.split('.')[0].replace(/[^a-z0-9_-]/gi, '') || 'app';
  }
});

function randomPort(target: 'port' | 'internal'): void {
  const value = String(Math.floor(Math.random() * (49999 - 5000)) + 5000);
  if (target === 'port') port.value = value;
  else internal.value = value;
}

function cleanDll(): void {
  dll.value = dll.value.replace(/\.dll$/i, '');
}

function submit(event: Event): void {
  event.preventDefault();
  const name = resolvedName.value;
  void run(
    '/api/v1/sites/create',
    {
      access_kind: channel.value,
      access_value: channel.value === 'domain' ? domain.value : port.value,
      backend_type: backend.value,
      name,
      proxy_target: proxy.value,
      dll_name: dll.value,
      internal_port: internal.value,
      aspnetcore_env: env.value,
      auto_ssl: channel.value === 'domain' && autoSsl.value ? 'true' : 'false',
    },
    { title: `Creating site ${name}`, onDone: () => router.push(`/sites/${name}`) },
  );
}

const cardClass = (selected: boolean) => [
  'flex flex-col gap-1 py-3 px-3.5 border rounded-theme-sm cursor-pointer transition-colors',
  selected
    ? 'border-c-accent bg-[color-mix(in_oklab,var(--accent)_6%,var(--bg))]'
    : 'border-c-border bg-c-bg hover:border-c-bstrong',
];

const iconStyle = (selected: boolean) =>
  `width:14px;height:14px;color:${selected ? 'var(--accent)' : 'var(--text-2)'}`;
</script>

<template>
  <section>
    <div class="mb-2">
      <Btn variant="ghost" sm @click="router.push('/sites')">
        <LIcon name="arrow-left" /> Sites
      </Btn>
    </div>
    <PageHeader title="Create site">
      <template #subtitle>
        Provision a new Nginx virtual host. The form runs a script and opens the live output
        stream.
      </template>
    </PageHeader>

    <form class="grid gap-[22px] max-w-3xl" @submit="submit">
      <div class="flex flex-col gap-1.5">
        <label class="text-sm-var font-medium text-c-tx">Access channel</label>
        <div class="grid grid-cols-2 gap-2">
          <div
            v-for="option in CHANNELS"
            :key="option.key"
            :class="cardClass(channel === option.key)"
            @click="channel = option.key"
          >
            <div class="flex items-center gap-2 text-sm-var font-medium">
              <LIcon :name="option.icon" :is="iconStyle(channel === option.key)" />
              {{ option.label }}
            </div>
            <div class="text-xs-var text-c-tx2">{{ option.hint }}</div>
          </div>
        </div>
      </div>

      <div v-if="channel === 'domain'" class="flex flex-col gap-1.5">
        <label for="i-domain" class="text-sm-var font-medium text-c-tx">Domain</label>
        <input id="i-domain" v-model="domain" class="input mono" placeholder="example.com" />
        <div class="text-xs-var text-c-tx2">
          Used as the logical site identifier and the Nginx
          <span class="mono">server_name</span>.
        </div>
      </div>

      <label
        v-if="channel === 'domain'"
        :class="[
          'flex items-start gap-3 py-3 px-3.5 border rounded-theme-sm cursor-pointer transition-colors select-none',
          autoSsl
            ? 'border-c-accent bg-[color-mix(in_oklab,var(--accent)_6%,var(--bg))]'
            : 'border-c-border bg-c-bg hover:border-c-bstrong',
        ]"
      >
        <input
          v-model="autoSsl"
          type="checkbox"
          class="mt-0.5 w-4 h-4 accent-c-accent rounded shrink-0"
        />
        <span class="flex flex-col gap-1">
          <span class="flex items-center gap-2 text-sm-var font-medium">
            <LIcon name="lock" :is="iconStyle(autoSsl)" /> Auto-register SSL certificate
          </span>
          <span class="text-xs-var text-c-tx2">
            Issues a free Let's Encrypt certificate via certbot (ACME) right after the site is
            created, enables HTTPS with an HTTP→HTTPS redirect, and links the cert into
            <span class="mono">sites/&lt;domain&gt;/ssl/</span>. The domain's DNS must already point
            to this server.
          </span>
        </span>
      </label>

      <template v-if="channel === 'port'">
        <div class="flex flex-col gap-1.5">
          <label for="i-port" class="text-sm-var font-medium text-c-tx">External port</label>
          <div class="flex gap-1.5">
            <input id="i-port" v-model="port" class="input mono" placeholder="5000–49999" />
            <Btn type="button" @click="randomPort('port')"><LIcon name="dices" /> Random</Btn>
          </div>
        </div>
        <div class="flex flex-col gap-1.5">
          <label for="i-name" class="text-sm-var font-medium text-c-tx">Site name</label>
          <input id="i-name" v-model="siteName" class="input mono" placeholder="my-internal-app" />
          <div class="text-xs-var text-c-tx2">
            Alphanumerics, dots, dashes, underscores. Used for paths and service names.
          </div>
        </div>
      </template>

      <div class="flex flex-col gap-1.5">
        <label class="text-sm-var font-medium text-c-tx">Backend architecture</label>
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-2">
          <div
            v-for="option in BACKENDS"
            :key="option.key"
            :class="cardClass(backend === option.key)"
            @click="backend = option.key"
          >
            <div class="flex items-center gap-2 text-sm-var font-medium">
              <LIcon :name="option.icon" :is="iconStyle(backend === option.key)" />
              {{ option.label }}
            </div>
            <div class="text-xs-var text-c-tx2">{{ option.hint }}</div>
          </div>
        </div>
      </div>

      <div v-if="backend === 'proxy'" class="flex flex-col gap-1.5">
        <label for="i-proxy" class="text-sm-var font-medium text-c-tx">Proxy target</label>
        <input id="i-proxy" v-model="proxy" class="input mono" />
        <div class="text-xs-var text-c-tx2">
          Translates to <span class="mono">proxy_pass</span> in the Nginx site config.
        </div>
      </div>

      <template v-if="backend === 'dotnet'">
        <div class="flex flex-col gap-1.5">
          <label for="i-dll" class="text-sm-var font-medium text-c-tx">DLL file</label>
          <input
            id="i-dll"
            v-model="dll"
            class="input mono"
            placeholder="AcmeApp.dll"
            @blur="cleanDll"
          />
          <div class="text-xs-var text-c-tx2">
            The <span class="mono">.dll</span> suffix is stripped on blur.
          </div>
        </div>
        <div class="flex flex-col gap-1.5">
          <label for="i-internal" class="text-sm-var font-medium text-c-tx">
            Internal Kestrel port
          </label>
          <div class="flex gap-1.5">
            <input id="i-internal" v-model="internal" class="input mono" />
            <Btn type="button" @click="randomPort('internal')"><LIcon name="dices" /> Random</Btn>
          </div>
          <div class="text-xs-var text-c-tx2">
            Bound by your app. Nginx proxies traffic into this port.
          </div>
        </div>
        <div class="flex flex-col gap-1.5">
          <label for="i-env" class="text-sm-var font-medium text-c-tx">
            ASPNETCORE_ENVIRONMENT
          </label>
          <select id="i-env" v-model="env" class="input">
            <option v-for="value in ENVIRONMENTS" :key="value">{{ value }}</option>
          </select>
        </div>
      </template>

      <div class="flex justify-end gap-2 mt-2">
        <Btn type="button" @click="router.push('/sites')">Cancel</Btn>
        <Btn type="submit" variant="primary"><LIcon name="rocket" /> Create site</Btn>
      </div>
    </form>
  </section>
</template>
