import { MOCK, appState, navigate, addToast, runJobAction } from '../store.js';
import { ansiToHtml } from '../utils.js';

const { computed, ref, onMounted, nextTick } = Vue;

export const SiteDetail = {
  name: 'ScreenSiteDetail',
  setup() {
    const site = computed(() =>
      MOCK.sites.find((x) => x.slug === appState.selectedSiteSlug) || MOCK.sites[0] || {}
    );

    const showConfig = ref(false);
    const configContent = ref('');
    const showLogs = ref(false);
    const logsContent = ref('');
    const configWordWrap = ref(false);
    const logsWordWrap = ref(true);

    const meta = computed(() => {
      const s = site.value;
      const rows = [
        { k: 'Type',    v: s.type === 'dotnet' ? '.NET Core (Kestrel)' : s.type === 'proxy' ? 'Reverse proxy' : s.type === 'static' ? 'Static files' : '—', mono: false },
        { k: 'Created', v: s.created || '—', mono: false },
        { k: 'Access',  v: s.access || '—', mono: true },
      ];
      if (s.type === 'dotnet') {
        rows.push({ k: 'DLL',           v: s.dll || '—',          mono: true });
        rows.push({ k: 'Internal port', v: String(s.internalPort || '—'), mono: true });
        rows.push({ k: 'Environment',   v: s.env || '—',          mono: true });
      }
      if (s.type === 'proxy') {
        rows.push({ k: 'Proxy target', v: s.proxyTarget || '—', mono: true });
      }
      return rows;
    });

    const paths = computed(() => {
      const s = site.value;
      const rows = [
        { k: 'Web root',    v: s.webRoot    || (s.slug ? `/var/www/nginx/sites/${s.slug}/publish` : '—') },
        { k: 'Nginx vhost', v: s.configPath || (s.slug ? `/etc/nginx/sites-available/${s.slug}.conf` : '—') },
      ];
      if (s.type === 'dotnet') {
        rows.push({ k: 'systemd unit', v: s.unitPath || `/etc/systemd/system/site-${s.slug}.service` });
      }
      return rows;
    });

    const runtime = computed(() => {
      const s = site.value;
      return [
        { lbl: 'Memory', val: s.mem != null ? s.mem.toFixed(1) : '—', unit: 'MB' },
        { lbl: 'CPU',    val: s.cpu != null ? s.cpu.toFixed(1) : '—', unit: '%' },
        { lbl: 'Uptime', val: s.status === 'running' ? '2d 14h 32m' : '—', unit: '', full: true },
      ];
    });

    const recentEvents = [
      { t: '2h ago',    k: 'ok',   msg: 'service restarted manually' },
      { t: 'yesterday', k: 'info', msg: 'config reloaded' },
      { t: '3d ago',    k: 'info', msg: 'site created' },
    ];

    async function viewConfig() {
      try {
        const r = await fetch(`/api/v1/sites/${site.value.name}/config`);
        if (r.ok) {
          const res = await r.json();
          configContent.value = res.config;
          showConfig.value = true;
          addToast({ t: 'Config loaded', k: 'info' });
        } else {
          addToast({ t: 'Failed to fetch config', k: 'danger' });
        }
      } catch (e) {
        addToast({ t: 'Network error', d: e.message, k: 'danger' });
      }
    }

    async function viewLogs() {
      try {
        const r = await fetch(`/api/v1/sites/${site.value.name}/logs`);
        if (r.ok) {
          const res = await r.json();
          logsContent.value = res.logs;
          showLogs.value = true;
          addToast({ t: 'Logs loaded', k: 'info' });
        } else {
          addToast({ t: 'Failed to fetch logs', k: 'danger' });
        }
      } catch (e) {
        addToast({ t: 'Network error', d: e.message, k: 'danger' });
      }
    }

    async function clipboardCopy(text) {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
      } else {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.setAttribute('readonly', '');
        ta.style.position = 'fixed';
        ta.style.top = '-9999px';
        document.body.appendChild(ta);
        ta.select();
        const ok = document.execCommand('copy');
        document.body.removeChild(ta);
        if (!ok) throw new Error('Clipboard not available');
      }
    }

    async function copyConfig() {
      try {
        await clipboardCopy(configContent.value || '');
        addToast({ t: 'Configuration copied to clipboard', k: 'info' });
      } catch (err) {
        addToast({ t: 'Failed to copy config', d: err.message, k: 'danger' });
      }
    }

    async function copyLogsText() {
      try {
        await clipboardCopy(logsContent.value || '');
        addToast({ t: 'Logs copied to clipboard', k: 'info' });
      } catch (err) {
        addToast({ t: 'Failed to copy logs', d: err.message, k: 'danger' });
      }
    }

    function downloadLogs() {
      const pad = (n) => String(n).padStart(2, '0');
      const safe = (s) => String(s || '').replace(/[^a-zA-Z0-9._-]/g, '_');
      const name = site.value.name || site.value.slug || 'site';
      const host = (MOCK.host?.hostname && MOCK.host.hostname !== 'Loading...') ? MOCK.host.hostname : 'server';
      const d = new Date();
      const ts = `${pad(d.getMonth() + 1)}-${pad(d.getDate())}-${d.getFullYear()}-${pad(d.getHours())}-${pad(d.getMinutes())}-${pad(d.getSeconds())}`;
      const filename = `${safe(host)}-${safe(name)}-${ts}.log`;
      const blob = new Blob([logsContent.value || ''], { type: 'text/plain;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
      addToast({ t: 'Log downloaded', d: filename, k: 'ok' });
    }

    const formattedLogs = computed(() => ansiToHtml(logsContent.value));

    onMounted(() => nextTick(() => window.lucide?.createIcons()));

    return {
      site, meta, paths, runtime, recentEvents,
      showConfig, configContent, showLogs, logsContent,
      navigate, addToast, runJobAction, viewConfig, viewLogs,
      configWordWrap, logsWordWrap, copyConfig, copyLogsText, downloadLogs,
      formattedLogs
    };
  },
  template: `
    <section>
      <div class="flex flex-col lg:flex-row lg:items-end lg:justify-between gap-4 mb-6">
        <div>
          <div class="flex items-center gap-2 mb-2">
            <btn variant="ghost" sm @click="navigate('sites')">
              <l-icon name="arrow-left" /> Sites
            </btn>
          </div>
          <div class="flex items-center gap-3">
            <h1 class="text-[22px] font-semibold tracking-[-0.02em]">{{ site.name }}</h1>
            <status-badge :status="site.status" />
            <type-chip :type="site.type" />
          </div>
          <div class="text-sm-var text-c-tx2 mono mt-1">{{ site.access }}</div>
        </div>
        <div class="flex flex-wrap gap-2 w-full lg:w-auto">
          <btn variant="success" @click="runJobAction('/api/v1/sites/' + site.name + '/reload-nginx', {}, 'Reloading Nginx')">
            <l-icon name="refresh-cw" /> Reload Nginx
          </btn>
          <btn variant="warn" v-if="site.type === 'dotnet'" @click="runJobAction('/api/v1/sites/' + site.name + '/restart', {}, 'Restarting service')">
            <l-icon name="rotate-ccw" /> Restart service
          </btn>
          <btn variant="info" @click="viewConfig">
            <l-icon name="file-text" /> Show config
          </btn>
          <btn variant="info" @click="viewLogs">
            <l-icon name="terminal" /> Tail logs
          </btn>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-[2fr_1fr] gap-3">
        <div class="flex flex-col gap-3">
          <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
            <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border"><h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Configuration</h3><span class="text-xs-var text-c-tx3 mono">YAML metadata</span></div>
            <div class="p-4">
              <dl class="grid grid-cols-1 sm:grid-cols-[140px_1fr] gap-y-2 gap-x-4 text-sm-var m-0">
                <template v-for="m in meta" :key="m.k">
                  <dt class="text-c-tx2">{{ m.k }}</dt>
                  <dd class="m-0 tabular-nums" :class="m.mono ? 'mono text-xs-var' : ''">{{ m.v }}</dd>
                </template>
              </dl>
            </div>
          </div>
          <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
            <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border"><h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Filesystem</h3></div>
            <div class="p-4">
              <dl class="grid grid-cols-1 sm:grid-cols-[140px_1fr] gap-y-2 gap-x-4 text-sm-var m-0">
                <template v-for="p in paths" :key="p.k">
                  <dt class="text-c-tx2">{{ p.k }}</dt>
                  <dd class="m-0 mono text-xs-var">{{ p.v }}</dd>
                </template>
              </dl>
            </div>
          </div>
        </div>

        <div class="flex flex-col gap-3">
          <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
            <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
              <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Runtime</h3>
              <span class="text-xs-var text-c-tx3 mono">{{ site.pid ? 'PID ' + site.pid : '' }}</span>
            </div>
            <div class="p-4">
              <div class="grid grid-cols-2 gap-x-2 gap-y-3.5">
                <div v-for="r in runtime" :key="r.lbl" :class="r.full ? 'col-span-2' : ''">
                  <div class="text-c-tx2 text-xs-var uppercase tracking-[0.06em]">{{ r.lbl }}</div>
                  <div class="text-xl font-semibold tracking-[-0.02em] tabular-nums">
                    {{ r.val }}<span v-if="r.unit" class="text-xs text-c-tx3 font-medium"> {{ r.unit }}</span>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
            <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border"><h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Recent events</h3></div>
            <div class="p-4">
              <div class="flex flex-col gap-2.5">
                <div v-for="e in recentEvents" :key="e.t" class="flex items-center gap-2.5 text-sm-var">
                  <span class="inline-flex items-center gap-1.5 h-[18px] px-1.5 rounded-full text-[11px] font-medium" :class="e.k === 'ok' ? 'bg-c-oksoft text-c-ok' : 'bg-c-infosoft text-c-info'">
                    <span class="w-1.5 h-1.5 rounded-full bg-current"></span>{{ e.k === 'ok' ? 'done' : 'info' }}
                  </span>
                  <span>{{ e.msg }}</span>
                  <span class="flex-1"></span>
                  <span class="text-c-tx2 mono text-xs-var">{{ e.t }}</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Config viewer dialog -->
      <div v-if="showConfig" class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px]" @click.self="showConfig = false">
        <div class="flex flex-col w-full max-w-4xl max-h-[80vh] bg-c-bg border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop" role="dialog" aria-modal="true">
          <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
            <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center"><l-icon name="file-text" is="width:14px;height:14px" /></div>
            <div>
              <div class="font-semibold text-sm-var">Nginx Configuration</div>
              <div class="text-xs-var text-c-tx2 mono">{{ site.configPath || 'Configuration' }}</div>
            </div>
            <div class="ml-auto flex items-center gap-2 mr-2">
              <btn variant="ghost" sm @click="copyConfig" class="text-xs-var h-7 px-2">
                <l-icon name="copy" is="width:13px;height:13px;margin-right:4px;" /> Copy
              </btn>
              <label class="flex items-center gap-1.5 text-xs-var cursor-pointer select-none px-2 h-7 bg-c-subtle hover:bg-c-hover rounded-theme border border-c-border text-c-tx2 hover:text-c-tx">
                <input type="checkbox" v-model="configWordWrap" class="w-3 h-3 accent-c-accent rounded" />
                <span>Word Wrap</span>
              </label>
            </div>
            <btn variant="ghost" sm square class="ml-auto" @click="showConfig = false" aria-label="Close">
              <l-icon name="x" />
            </btn>
          </div>
          <div :class="['term overflow-auto font-mono text-xs-var p-4 bg-c-elev text-c-tx leading-relaxed select-text', configWordWrap ? 'whitespace-pre-wrap' : 'whitespace-pre']" style="height:480px; word-break: break-all;">
            {{ configContent }}
          </div>
        </div>
      </div>

      <!-- Log viewer dialog -->
      <div v-if="showLogs" class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px]" @click.self="showLogs = false">
        <div class="flex flex-col w-full max-w-4xl max-h-[80vh] bg-c-bg border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop" role="dialog" aria-modal="true">
          <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
            <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center"><l-icon name="terminal" is="width:14px;height:14px" /></div>
            <div>
              <div class="font-semibold text-sm-var">Subprocess Logs</div>
              <div class="text-xs-var text-c-tx2">Tail of recent site stdout & stderr</div>
            </div>
            <div class="ml-auto flex items-center gap-2 mr-2">
              <btn variant="ghost" sm @click="copyLogsText" class="text-xs-var h-7 px-2">
                <l-icon name="copy" is="width:13px;height:13px;margin-right:4px;" /> Copy
              </btn>
              <btn variant="ghost" sm @click="downloadLogs" class="text-xs-var h-7 px-2">
                <l-icon name="download" is="width:13px;height:13px;margin-right:4px;" /> Download
              </btn>
              <label class="flex items-center gap-1.5 text-xs-var cursor-pointer select-none px-2 h-7 bg-c-subtle hover:bg-c-hover rounded-theme border border-c-border text-c-tx2 hover:text-c-tx">
                <input type="checkbox" v-model="logsWordWrap" class="w-3 h-3 accent-c-accent rounded" />
                <span>Word Wrap</span>
              </label>
            </div>
            <btn variant="ghost" sm square class="ml-auto" @click="showLogs = false" aria-label="Close">
              <l-icon name="x" />
            </btn>
          </div>
          <div :class="['term overflow-auto font-mono text-xs-var p-4 bg-c-elev text-c-tx leading-relaxed select-text', logsWordWrap ? 'whitespace-pre-wrap' : 'whitespace-pre']" style="height:480px; word-break: break-all;" v-html="formattedLogs"></div>
        </div>
      </div>
    </section>
  `,
};
