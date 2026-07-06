import { navigate, runJobAction } from '../store.js';

const { ref, computed, onMounted, nextTick, watch } = Vue;

export const CreateSite = {
  name: 'ScreenCreateSite',
  setup() {
    const channel = ref('domain');
    const backend = ref('proxy');

    const autoSsl  = ref(false);

    const domain   = ref('app.acme.io');
    const port     = ref('7842');
    const siteName = ref('');
    const proxy    = ref('http://127.0.0.1:5555');
    const dll      = ref('');
    const internal = ref('5021');
    const env      = ref('Production');

    const showDomain = computed(() => channel.value === 'domain');
    const showPort   = computed(() => channel.value === 'port');
    const showProxy  = computed(() => backend.value === 'proxy');
    const showDotnet = computed(() => backend.value === 'dotnet');

    watch(backend, (v) => {
      if (v === 'dotnet' && !dll.value) {
        const base = domain.value.split('.')[0].replace(/[^a-z0-9_-]/gi, '') || 'app';
        dll.value = base;
      }
    });

    function randomPort(target) {
      const p = Math.floor(Math.random() * (49999 - 5000)) + 5000;
      if (target === 'port') port.value = String(p);
      else internal.value = String(p);
    }

    function cleanDll() {
      dll.value = dll.value.replace(/\.dll$/i, '');
    }

    function submit(e) {
      e.preventDefault();
      const resolvedName = channel.value === 'domain' ? domain.value : siteName.value;
      runJobAction('/api/v1/sites/create', {
        access_kind: channel.value,
        access_value: channel.value === 'domain' ? domain.value : port.value,
        backend_type: backend.value,
        name: resolvedName,
        proxy_target: proxy.value,
        dll_name: dll.value,
        internal_port: internal.value,
        aspnetcore_env: env.value,
        auto_ssl: channel.value === 'domain' && autoSsl.value ? 'true' : 'false',
      }, `Creating site ${resolvedName}`, () => {
        setTimeout(() => navigate('site-detail', { selectedSiteSlug: resolvedName }), 500);
      });
    }

    onMounted(() => nextTick(() => window.lucide?.createIcons()));

    return {
      channel, backend, domain, port, siteName, proxy, dll, internal, env, autoSsl,
      showDomain, showPort, showProxy, showDotnet,
      randomPort, cleanDll, submit, navigate,
    };
  },
  template: `
    <section>
      <div class="flex items-end justify-between gap-6 mb-6">
        <div>
          <div class="flex items-center gap-2 mb-2">
            <btn variant="ghost" sm @click="navigate('sites')">
              <l-icon name="arrow-left" /> Sites
            </btn>
          </div>
          <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">Create site</h1>
          <div class="text-sm-var text-c-tx2">Provision a new Nginx virtual host. The form submits a script and opens the live output stream.</div>
        </div>
      </div>

      <form class="grid gap-[22px] max-w-3xl" @submit="submit">

        <div class="flex flex-col gap-1.5">
          <label class="text-sm-var font-medium text-c-tx">Access channel</label>
          <div class="grid grid-cols-2 gap-2">
            <div :class="['flex flex-col gap-1 py-3 px-3.5 border rounded-theme-sm cursor-pointer transition-colors', channel === 'domain' ? 'border-c-accent bg-[color-mix(in_oklab,var(--accent)_6%,var(--bg))]' : 'border-c-border bg-c-bg hover:border-c-bstrong']" @click="channel = 'domain'">
              <div class="flex items-center gap-2 text-sm-var font-medium"><l-icon name="globe" :is="'width:14px;height:14px;color:' + (channel === 'domain' ? 'var(--accent)' : 'var(--text-2)')" /> Domain</div>
              <div class="text-xs-var text-c-tx2">Bind by hostname (HTTP host header).</div>
            </div>
            <div :class="['flex flex-col gap-1 py-3 px-3.5 border rounded-theme-sm cursor-pointer transition-colors', channel === 'port' ? 'border-c-accent bg-[color-mix(in_oklab,var(--accent)_6%,var(--bg))]' : 'border-c-border bg-c-bg hover:border-c-bstrong']" @click="channel = 'port'">
              <div class="flex items-center gap-2 text-sm-var font-medium"><l-icon name="plug" :is="'width:14px;height:14px;color:' + (channel === 'port' ? 'var(--accent)' : 'var(--text-2)')" /> Port</div>
              <div class="text-xs-var text-c-tx2">Expose on a public port number.</div>
            </div>
          </div>
        </div>

        <div v-if="showDomain" class="flex flex-col gap-1.5">
          <label for="i-domain" class="text-sm-var font-medium text-c-tx">Domain</label>
          <input id="i-domain" class="input mono" placeholder="example.com" v-model="domain" />
          <div class="text-xs-var text-c-tx2">Used as the logical site identifier and the Nginx <span class="mono">server_name</span>.</div>
        </div>

        <label v-if="showDomain" :class="['flex items-start gap-3 py-3 px-3.5 border rounded-theme-sm cursor-pointer transition-colors select-none', autoSsl ? 'border-c-accent bg-[color-mix(in_oklab,var(--accent)_6%,var(--bg))]' : 'border-c-border bg-c-bg hover:border-c-bstrong']">
          <input type="checkbox" v-model="autoSsl" class="mt-0.5 w-4 h-4 accent-c-accent rounded shrink-0" />
          <span class="flex flex-col gap-1">
            <span class="flex items-center gap-2 text-sm-var font-medium"><l-icon name="lock" :is="'width:14px;height:14px;color:' + (autoSsl ? 'var(--accent)' : 'var(--text-2)')" /> Auto-register SSL certificate</span>
            <span class="text-xs-var text-c-tx2">Issues a free Let's Encrypt certificate via certbot (ACME) right after the site is created, enables HTTPS with an HTTP→HTTPS redirect, and links the cert into <span class="mono">sites/&lt;domain&gt;/ssl/</span>. The domain's DNS must already point to this server.</span>
          </span>
        </label>

        <template v-if="showPort">
          <div class="flex flex-col gap-1.5">
            <label for="i-port" class="text-sm-var font-medium text-c-tx">External port</label>
            <div class="flex gap-1.5">
              <input id="i-port" class="input mono" placeholder="5000–49999" v-model="port" />
              <btn type="button" @click="randomPort('port')">
                <l-icon name="dices" /> Random
              </btn>
            </div>
          </div>
          <div class="flex flex-col gap-1.5">
            <label for="i-name" class="text-sm-var font-medium text-c-tx">Site name</label>
            <input id="i-name" class="input mono" placeholder="my-internal-app" v-model="siteName" />
            <div class="text-xs-var text-c-tx2">Alphanumerics, dots, dashes, underscores. Used for paths and service names.</div>
          </div>
        </template>

        <div class="flex flex-col gap-1.5">
          <label class="text-sm-var font-medium text-c-tx">Backend architecture</label>
          <div class="grid grid-cols-3 gap-2">
            <div :class="['flex flex-col gap-1 py-3 px-3.5 border rounded-theme-sm cursor-pointer transition-colors', backend === 'static' ? 'border-c-accent bg-[color-mix(in_oklab,var(--accent)_6%,var(--bg))]' : 'border-c-border bg-c-bg hover:border-c-bstrong']" @click="backend = 'static'">
              <div class="flex items-center gap-2 text-sm-var font-medium"><l-icon name="file-code" :is="'width:14px;height:14px;color:' + (backend === 'static' ? 'var(--accent)' : 'var(--text-2)')" /> Static</div>
              <div class="text-xs-var text-c-tx2">Serve files from <span class="mono">/publish</span>.</div>
            </div>
            <div :class="['flex flex-col gap-1 py-3 px-3.5 border rounded-theme-sm cursor-pointer transition-colors', backend === 'proxy' ? 'border-c-accent bg-[color-mix(in_oklab,var(--accent)_6%,var(--bg))]' : 'border-c-border bg-c-bg hover:border-c-bstrong']" @click="backend = 'proxy'">
              <div class="flex items-center gap-2 text-sm-var font-medium"><l-icon name="arrow-right-left" :is="'width:14px;height:14px;color:' + (backend === 'proxy' ? 'var(--accent)' : 'var(--text-2)')" /> Proxy</div>
              <div class="text-xs-var text-c-tx2">Forward to an upstream URL.</div>
            </div>
            <div :class="['flex flex-col gap-1 py-3 px-3.5 border rounded-theme-sm cursor-pointer transition-colors', backend === 'dotnet' ? 'border-c-accent bg-[color-mix(in_oklab,var(--accent)_6%,var(--bg))]' : 'border-c-border bg-c-bg hover:border-c-bstrong']" @click="backend = 'dotnet'">
              <div class="flex items-center gap-2 text-sm-var font-medium"><l-icon name="hexagon" :is="'width:14px;height:14px;color:' + (backend === 'dotnet' ? 'var(--accent)' : 'var(--text-2)')" /> .NET Core</div>
              <div class="text-xs-var text-c-tx2">Run a Kestrel service behind Nginx.</div>
            </div>
          </div>
        </div>

        <div v-if="showProxy" class="flex flex-col gap-1.5">
          <label for="i-proxy" class="text-sm-var font-medium text-c-tx">Proxy target</label>
          <input id="i-proxy" class="input mono" v-model="proxy" />
          <div class="text-xs-var text-c-tx2">Translates to <span class="mono">proxy_pass</span> in the Nginx site config.</div>
        </div>

        <template v-if="showDotnet">
          <div class="flex flex-col gap-1.5">
            <label for="i-dll" class="text-sm-var font-medium text-c-tx">DLL file</label>
            <input id="i-dll" class="input mono" placeholder="AcmeApp.dll" v-model="dll" @blur="cleanDll" />
            <div class="text-xs-var text-c-tx2">The <span class="mono">.dll</span> suffix is stripped on blur.</div>
          </div>
          <div class="flex flex-col gap-1.5">
            <label for="i-internal" class="text-sm-var font-medium text-c-tx">Internal Kestrel port</label>
            <div class="flex gap-1.5">
              <input id="i-internal" class="input mono" v-model="internal" />
              <btn type="button" @click="randomPort('internal')">
                <l-icon name="dices" /> Random
              </btn>
            </div>
            <div class="text-xs-var text-c-tx2">Bound by your app. Nginx proxies traffic into this port.</div>
          </div>
          <div class="flex flex-col gap-1.5">
            <label for="i-env" class="text-sm-var font-medium text-c-tx">ASPNETCORE_ENVIRONMENT</label>
            <select id="i-env" class="input" v-model="env">
              <option>Production</option>
              <option>Development</option>
              <option>Test</option>
              <option>Demo</option>
              <option>Staging</option>
            </select>
          </div>
        </template>

        <div class="flex justify-end gap-2 mt-2">
          <btn type="button" @click="navigate('sites')">Cancel</btn>
          <btn type="submit" variant="primary">
            <l-icon name="rocket" /> Create site
          </btn>
        </div>
      </form>
    </section>
  `,
};
