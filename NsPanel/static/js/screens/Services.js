import { MOCK, appState, addToast, navigate, fetchSamples, runJobAction } from '../store.js';

const { onMounted, nextTick, ref, reactive, computed } = Vue;

// Public hostname: lowercase, at least two labels, no wildcard/underscore.
// Mirrors HOSTNAME_RE in features/cloudflare_tunnel.py (backend is authoritative).
const TUNNEL_HOST_RE = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

export const TOKEN_HELP = `https://dash.cloudflare.com/profile/api-tokens -> API Tokens -> Create Token -> Create Custom Token
Permissions:
  Account > Cloudflare Tunnel: Edit
  Zone > DNS: Edit
  Zone > Zone: Read`;

export const Services = {
  name: 'ScreenServices',
  setup() {
    const showCreate = ref(false);
    const showTunnel = ref(false);
    const tunnelSubmitting = ref(false);
    const tunnelForm = reactive({ api_token: '', hostname: '', url: '' });

    // First non-loopback address of the host, for the LAN sample URL chip.
    const lanIp = computed(() => {
      const n = (MOCK.host.network || []).find((x) => x.ip && !x.ip.startsWith('127.'));
      return n ? n.ip : '';
    });
    const urlChips = computed(() => {
      const chips = ['http://localhost:5000'];
      if (lanIp.value) chips.push(`http://${lanIp.value}:5000`);
      return chips;
    });

    function isTunnel(s) {
      return !!s.tunnel || (s.name || '').startsWith('cloudflared.');
    }

    function openTunnel() {
      Object.assign(tunnelForm, { api_token: '', hostname: '', url: '' });
      showTunnel.value = true;
      // The LAN chip needs the host's interfaces; normally loaded on first paint.
      if (!(MOCK.host.network || []).length) fetchSamples('', ['system']);
      nextTick(() => window.lucide?.createIcons());
    }

    function fillUrl(chip) {
      tunnelForm.url = chip;
    }

    async function submitTunnel(e) {
      if (e) e.preventDefault();
      const token = tunnelForm.api_token.trim();
      const hostname = tunnelForm.hostname.trim().toLowerCase().replace(/^https?:\/\//, '').replace(/\/+$/, '').replace(/\.$/, '');
      const url = tunnelForm.url.trim();
      if (!token) {
        addToast({ t: 'Validation error', d: 'Cloudflare API token is required.', k: 'warn' });
        return;
      }
      if (!TUNNEL_HOST_RE.test(hostname)) {
        addToast({ t: 'Invalid hostname', d: 'Enter a public hostname such as app.example.com.', k: 'warn' });
        return;
      }
      if (!url) {
        addToast({ t: 'Validation error', d: 'Local service URL is required.', k: 'warn' });
        return;
      }
      tunnelSubmitting.value = true;
      try {
        // runJobAction toasts the backend's [stage] error on failure and opens
        // the live-output overlay on success.
        const res = await runJobAction(
          '/api/v1/services/tunnels/create',
          { api_token: token, hostname, url },
          `Creating tunnel ${hostname}`
        );
        if (res) showTunnel.value = false;
      } finally {
        tunnelSubmitting.value = false;
      }
    }
    const form = reactive({
      name: '',
      description: '',
      working_dir: '',
      command: '',
      user: 'root',
      env_vars: ''
    });

    async function refresh() {
      await fetchSamples();
      addToast({ t: 'Services refreshed', k: 'info' });
    }

    function openCreate() {
      Object.assign(form, {
        name: '',
        description: '',
        working_dir: '',
        command: '',
        user: 'root',
        env_vars: ''
      });
      showCreate.value = true;
    }

    function submitCreate(e) {
      if (e) e.preventDefault();
      if (!form.name.trim() || !form.working_dir.trim() || !form.command.trim()) {
        addToast({ t: 'Validation error', d: 'Name, directory, and command are required.', k: 'warn' });
        return;
      }
      showCreate.value = false;
      runJobAction('/api/v1/services/create', {
        name: form.name.trim(),
        description: form.description.trim(),
        working_dir: form.working_dir.trim(),
        command: form.command.trim(),
        user: form.user.trim() || 'root',
        env_vars: form.env_vars.trim()
      }, `Registering service ${form.name.trim()}`);
    }

    onMounted(() => nextTick(() => window.lucide?.createIcons()));

    return {
      MOCK, appState, refresh, openCreate, showCreate, form, submitCreate, addToast, navigate,
      showTunnel, tunnelSubmitting, tunnelForm, urlChips, isTunnel, openTunnel, fillUrl, submitTunnel,
      TOKEN_HELP,
    };
  },
  template: `
    <section>
      <div class="flex items-end justify-between gap-6 mb-6">
        <div>
          <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">Services</h1>
          <div class="text-sm-var text-c-tx2">
            {{ MOCK.services.length }} custom systemd services in <span class="mono">/var/www/services/</span>
          </div>
        </div>
        <div class="flex gap-2">
          <btn @click="refresh">
            <l-icon name="refresh-cw" /> Refresh
          </btn>
          <btn @click="openTunnel">
            <l-icon name="cloud" /> New tunnel
          </btn>
          <btn variant="primary" @click="openCreate">
            <l-icon name="plus" /> New service
          </btn>
        </div>
      </div>

      <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
        <table class="tbl">
          <thead><tr>
            <th>Name</th><th>Status</th><th>Autostart</th>
            <th>Mem (MB)</th><th>CPU (%)</th><th>Description</th><th>Last edit</th><th></th>
          </tr></thead>
          <tbody>
            <!-- Loading state: fetch in flight and nothing to show yet -->
            <tr v-if="appState.fetching.services && !MOCK.services.length">
              <td colspan="8" class="muted" style="text-align:center; padding:32px 0">
                <span class="inline-flex items-center gap-2 text-c-tx2">
                  <svg class="animate-spin h-3.5 w-3.5 text-c-accent" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                  </svg>
                  Loading services…
                </span>
              </td>
            </tr>
            <!-- Empty state: loaded, but genuinely no services -->
            <tr v-else-if="!MOCK.services.length">
              <td colspan="8" class="muted" style="text-align:center; padding:32px 0">
                No custom services yet — use <strong>New service</strong> to register one.
              </td>
            </tr>
            <tr v-for="s in MOCK.services" :key="s.name" class="row-click"
              @click="navigate('service-detail', { selectedServiceName: s.name })">
              <td>
                <div class="flex items-center gap-2">
                  <strong>{{ s.name }}</strong>
                  <badge v-if="isTunnel(s)" tone="accent">tunnel</badge>
                </div>
                <!-- Tunnel units carry the tunnel token in ExecStart — show the route instead -->
                <div class="text-xs-var text-c-tx3 mt-0.5 mono">{{ s.tunnel ? s.tunnel.hostname + ' → ' + s.tunnel.service_url : s.cmd }}</div>
              </td>
              <td><status-badge :status="s.status" /></td>
              <td><status-badge :status="s.autostart" /></td>
              <td class="num">{{ s.mem != null ? s.mem.toFixed(1) : '—' }}</td>
              <td class="num">{{ s.cpu != null ? s.cpu.toFixed(1) : '—' }}</td>
              <td class="muted" style="white-space:normal">{{ s.desc }}</td>
              <td class="muted">{{ s.modified }}</td>
              <td><l-icon name="chevron-right" is="width:14px;height:14px;color:var(--text-3)" /></td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- Create Service Dialog -->
      <div v-if="showCreate" class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade" @click.self="showCreate = false">
        <div class="w-full max-w-[480px] bg-c-bg border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop" role="dialog" aria-modal="true">
          <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
            <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center"><l-icon name="server" is="width:14px;height:14px" /></div>
            <div>
              <div class="font-semibold text-sm-var">Register new systemd service</div>
              <div class="text-xs-var text-c-tx2">Configured under /etc/systemd/system/</div>
            </div>
            <btn variant="ghost" sm square class="ml-auto" @click="showCreate = false" aria-label="Close">
              <l-icon name="x" />
            </btn>
          </div>

          <form class="p-4 flex flex-col gap-3.5 animate-fade" @submit="submitCreate">
            <div class="flex flex-col gap-1">
              <label for="svc-name" class="text-sm-var font-medium text-c-tx">Service name</label>
              <input id="svc-name" class="input mono" placeholder="e.g. queue-worker" v-model="form.name" required autofocus />
              <div class="text-[10px] text-c-tx2">Used as the systemd service name (no spaces).</div>
            </div>

            <div class="flex flex-col gap-1">
              <label for="svc-desc" class="text-sm-var font-medium text-c-tx">Description</label>
              <input id="svc-desc" class="input" placeholder="e.g. Background task processing queue" v-model="form.description" />
            </div>

            <div class="flex flex-col gap-1">
              <label for="svc-dir" class="text-sm-var font-medium text-c-tx">Working directory</label>
              <input id="svc-dir" class="input mono" placeholder="e.g. /var/www/services/queue-worker" v-model="form.working_dir" required />
            </div>

            <div class="flex flex-col gap-1">
              <label for="svc-cmd" class="text-sm-var font-medium text-c-tx">ExecStart command</label>
              <input id="svc-cmd" class="input mono" placeholder="e.g. /usr/bin/dotnet App.dll" v-model="form.command" required />
            </div>

            <div class="flex flex-col gap-1">
              <label for="svc-user" class="text-sm-var font-medium text-c-tx">Execution user</label>
              <input id="svc-user" class="input mono" placeholder="root" v-model="form.user" />
            </div>

            <div class="flex flex-col gap-1">
              <label for="svc-env" class="text-sm-var font-medium text-c-tx">Environment variables <span class="text-c-tx3 font-normal">· one per line</span></label>
              <textarea id="svc-env" class="input mono h-16 py-1.5 resize-none leading-normal font-mono" placeholder="NODE_ENV=production&#10;PORT=5000" v-model="form.env_vars"></textarea>
            </div>

            <div class="flex justify-end gap-2 mt-1 shrink-0">
              <btn type="button" @click="showCreate = false">Cancel</btn>
              <btn type="submit" variant="primary">
                <l-icon name="rocket" /> Register & Start
              </btn>
            </div>
          </form>
        </div>
      </div>

      <!-- Create Cloudflare Tunnel Dialog -->
      <div v-if="showTunnel" class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade" @click.self="!tunnelSubmitting && (showTunnel = false)">
        <div class="w-full max-w-[520px] max-h-[90vh] overflow-y-auto bg-c-bg border border-c-border rounded-theme-lg shadow-lg animate-pop" role="dialog" aria-modal="true">
          <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
            <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center"><l-icon name="cloud" is="width:14px;height:14px" /></div>
            <div>
              <div class="font-semibold text-sm-var">Create Cloudflare Tunnel</div>
              <div class="text-xs-var text-c-tx2">Registers <span class="mono">cloudflared.&lt;hostname&gt;</span> as a systemd service</div>
            </div>
            <btn variant="ghost" sm square class="ml-auto" @click="showTunnel = false" aria-label="Close" :disabled="tunnelSubmitting">
              <l-icon name="x" />
            </btn>
          </div>

          <form class="p-4 flex flex-col gap-3.5 animate-fade" @submit="submitTunnel">
            <div class="flex flex-col gap-1">
              <label for="tun-token" class="text-sm-var font-medium text-c-tx">Cloudflare API token</label>
              <input id="tun-token" type="password" class="input mono" placeholder="Paste API token" v-model="tunnelForm.api_token" autocomplete="off" required autofocus />
              <pre class="m-0 mt-1 px-2.5 py-2 text-[10px] leading-snug text-c-tx2 bg-c-subtle border border-c-border rounded font-mono whitespace-pre-wrap break-all">{{ TOKEN_HELP }}</pre>
              <div class="text-[10px] text-c-tx3">Used once to create the tunnel — not stored on the server.</div>
            </div>

            <div class="flex flex-col gap-1">
              <label for="tun-host" class="text-sm-var font-medium text-c-tx">Hostname</label>
              <input id="tun-host" class="input mono" placeholder="dev.example.com" v-model="tunnelForm.hostname" autocomplete="off" required />
              <div class="text-[10px] text-c-tx2">Must belong to a zone on this Cloudflare account. An existing DNS record for this name will be replaced.</div>
            </div>

            <div class="flex flex-col gap-1">
              <label for="tun-url" class="text-sm-var font-medium text-c-tx">Local service URL</label>
              <input id="tun-url" class="input mono" placeholder="http://localhost:5000" v-model="tunnelForm.url" autocomplete="off" required />
              <div class="flex items-center gap-1.5 flex-wrap mt-0.5">
                <span class="text-[10px] text-c-tx3">Samples:</span>
                <button v-for="c in urlChips" :key="c" type="button"
                  class="text-[10px] mono px-2 py-0.5 rounded-full border border-c-border bg-c-subtle text-c-tx2 hover:text-c-tx hover:bg-c-hover transition-colors"
                  @click="fillUrl(c)">{{ c }}</button>
              </div>
              <div class="text-[10px] text-c-tx2">Accepts a bare port (5000), host:port, or a full http/https URL.</div>
            </div>

            <div class="flex justify-end gap-2 mt-1 shrink-0">
              <btn type="button" @click="showTunnel = false" :disabled="tunnelSubmitting">Cancel</btn>
              <btn type="submit" variant="primary" :disabled="tunnelSubmitting">
                <svg v-if="tunnelSubmitting" class="animate-spin h-3.5 w-3.5" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                  <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                </svg>
                <l-icon v-else name="cloud" />
                {{ tunnelSubmitting ? 'Creating…' : 'Create & Start' }}
              </btn>
            </div>
          </form>
        </div>
      </div>
    </section>
  `,
};
