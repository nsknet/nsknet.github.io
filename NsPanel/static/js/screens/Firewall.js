import { MOCK, appState, addToast, runJobAction, confirmThen, fetchSamples } from '../store.js';

const { ref, reactive, computed, onMounted, onUnmounted, nextTick } = Vue;

const ACTION_CLS = {
  allow: 'bg-c-oksoft text-c-ok',
  deny:  'bg-c-dngsoft text-c-danger',
  limit: 'bg-c-warnsoft text-c-warn',
};

const SOURCES = [
  { label: 'Anywhere',                 value: 'Anywhere' },
  { label: 'Class A · 10.0.0.0/8',     value: '10.0.0.0/8' },
  { label: 'Class B · 172.16.0.0/12',  value: '172.16.0.0/12' },
  { label: 'Class C · 192.168.0.0/16', value: '192.168.0.0/16' },
  { label: 'Custom…',                  value: '__custom' },
];

export const Firewall = {
  name: 'ScreenFirewall',
  setup() {
    const showAdd = ref(false);
    const form = reactive({ port: '', desc: '', action: 'ALLOW', source: 'Anywhere', custom: '' });

    const ruleCount = computed(() => {
      const r = MOCK.firewall.rules;
      return `${r.length} rules · ${r.filter((x) => !x.v6).length} v4 · ${r.filter((x) => x.v6).length} v6`;
    });

    async function refresh() {
      await fetchSamples();
      addToast({ t: 'Rules refreshed', k: 'info' });
    }

    function openAdd() {
      Object.assign(form, { port: '', desc: '', action: 'ALLOW', source: 'Anywhere', custom: '' });
      showAdd.value = true;
    }

    function submitAdd(e) {
      if (e) e.preventDefault();
      const port = form.port.trim();
      if (!port) { addToast({ t: 'Enter a port or service', k: 'warn' }); return; }
      
      const action = form.action;
      const source = form.source === '__custom' ? form.custom.trim() : form.source;
      const comment = form.desc.trim();

      if (form.source === '__custom' && !source) {
        addToast({ t: 'Enter a custom source IP/CIDR', k: 'warn' });
        return;
      }

      showAdd.value = false;
      runJobAction(
        '/api/v1/firewall/add-port',
        { port, action, source, comment },
        `Adding rule: ${action} ${port} from ${source}`
      );
    }

    function deleteRule(idx) {
      const r = MOCK.firewall.rules.find((x) => x.idx === idx);
      if (!r) return;
      confirmThen(
        'Delete rule?',
        `This removes rule #${idx} (${r.action} ${r.port} from ${r.from}). It cannot be undone from the UI.`,
        () => runJobAction('/api/v1/firewall/delete-port', { rule_num: idx }, `Deleting firewall rule #${idx}`)
      );
    }

    function onKeydown(e) { if (e.key === 'Escape') showAdd.value = false; }
    onMounted(() => { document.addEventListener('keydown', onKeydown); nextTick(() => window.lucide?.createIcons()); });
    onUnmounted(() => document.removeEventListener('keydown', onKeydown));

    return { MOCK, appState, showAdd, form, SOURCES, ruleCount, refresh, openAdd, submitAdd, deleteRule, ACTION_CLS };
  },
  template: `
    <section>
      <div class="flex items-end justify-between gap-6 mb-6">
        <div>
          <div class="flex items-center gap-3 mb-1">
            <h1 class="text-[22px] font-semibold tracking-[-0.02em]">Firewall</h1>
            <badge :tone="MOCK.firewall.active ? 'ok' : 'danger'" :dot="MOCK.firewall.active">
              {{ MOCK.firewall.active ? 'UFW active' : 'UFW inactive' }}
            </badge>
          </div>
          <div class="text-sm-var text-c-tx2">Default: deny incoming, allow outgoing. SSH (22) auto-allowed.</div>
        </div>
        <div class="flex gap-2">
          <btn @click="refresh">
            <l-icon name="refresh-cw" /> Refresh rules
          </btn>
          <btn variant="primary" @click="openAdd">
            <l-icon name="plus" /> Add rule
          </btn>
        </div>
      </div>

      <div class="flex items-center gap-2.5 px-3.5 py-2.5 rounded-theme bg-c-infosoft text-c-info text-sm-var mb-4 border border-transparent">
        <l-icon name="info" is="width:16px;height:16px;flex-shrink:0" />
        <div><strong>{{ MOCK.firewall.rules.length }} rules</strong> active — including IPv6 duplicates. Deletions are confirmed and streamed.</div>
      </div>

      <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
        <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
          <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Allowed ports</h3>
          <span class="text-xs-var text-c-tx3 mono">{{ ruleCount }}</span>
        </div>
        <table class="tbl">
          <thead><tr>
            <th style="width:56px">#</th>
            <th>Port / service</th>
            <th>Action</th>
            <th>Source</th>
            <th></th>
          </tr></thead>
          <tbody>
            <tr v-if="appState.fetching.firewall && !MOCK.firewall.rules.length">
              <td colspan="5" class="muted" style="text-align:center; padding:32px 0">
                <span class="inline-flex items-center gap-2 text-c-tx2">
                  <svg class="animate-spin h-3.5 w-3.5 text-c-accent" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                  </svg>
                  Loading rules…
                </span>
              </td>
            </tr>
            <tr v-else-if="!MOCK.firewall.rules.length">
              <td colspan="5" class="muted" style="text-align:center; padding:32px 0">
                No rules found — UFW may be inactive. Use <strong>Add rule</strong> to allow a port.
              </td>
            </tr>
            <tr v-for="r in MOCK.firewall.rules" :key="r.idx">
              <td class="num muted">{{ r.idx }}</td>
              <td>
                <span class="mono"><strong>{{ r.port }}</strong></span>
                <span v-if="r.v6" class="mono text-[10px] font-medium tracking-[0.05em] px-[5px] py-px rounded-[4px] bg-c-subtle text-c-tx3 ml-1.5 border border-c-border">v6</span>
                <div v-if="r.label" class="text-xs-var text-c-tx3 mt-0.5">{{ r.label }}</div>
              </td>
              <td><span class="inline-flex items-center gap-1 h-[22px] px-2 mono text-xs-var font-semibold tracking-[0.04em] rounded-[5px]" :class="ACTION_CLS[r.action.toLowerCase()]">{{ r.action }}</span></td>
              <td class="mono muted">{{ r.from }}</td>
              <td>
                <btn variant="danger" sm square title="Delete rule" @click="deleteRule(r.idx)">
                  <l-icon name="trash-2" />
                </btn>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- Add rule dialog -->
      <div v-if="showAdd" class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade" @click.self="showAdd = false">
        <div class="w-full max-w-[460px] bg-c-bg border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop" role="dialog" aria-modal="true">
          <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
            <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center"><l-icon name="shield-plus" is="width:14px;height:14px" /></div>
            <div>
              <div class="font-semibold text-sm-var">Add firewall rule</div>
              <div class="text-xs-var text-c-tx2">Applied to both IPv4 and IPv6.</div>
            </div>
            <btn variant="ghost" sm square class="ml-auto" @click="showAdd = false" aria-label="Close">
              <l-icon name="x" />
            </btn>
          </div>

          <form class="p-4 flex flex-col gap-3.5" @submit="submitAdd">
            <div class="flex flex-col gap-1.5">
              <label for="fw-port" class="text-sm-var font-medium text-c-tx">Port / protocol</label>
              <input id="fw-port" class="input mono" placeholder="80, 443/tcp, 8000:8100/tcp" v-model="form.port" autofocus />
              <div class="text-xs-var text-c-tx2">Single port, <span class="mono">443/tcp</span>, or range <span class="mono">8000:8100/tcp</span>.</div>
            </div>

            <div class="flex flex-col gap-1.5">
              <label for="fw-desc" class="text-sm-var font-medium text-c-tx">Description <span class="text-c-tx3 font-normal">· optional</span></label>
              <input id="fw-desc" class="input" placeholder="e.g. HTTPS" v-model="form.desc" />
            </div>

            <div class="flex flex-col gap-1.5">
              <label class="text-sm-var font-medium text-c-tx">Action</label>
              <div class="inline-flex w-fit gap-0.5 p-0.5 rounded-theme-sm bg-c-subtle">
                <button v-for="a in ['ALLOW','DENY','LIMIT']" :key="a" type="button"
                  :class="['px-3 h-7 rounded-[5px] mono text-xs-var font-semibold tracking-[0.04em] transition-colors', form.action === a ? 'bg-c-bg shadow-sm ' + ACTION_CLS[a.toLowerCase()] : 'text-c-tx2 hover:text-c-tx']"
                  @click="form.action = a">{{ a }}</button>
              </div>
            </div>

            <div class="flex flex-col gap-1.5">
              <label for="fw-src" class="text-sm-var font-medium text-c-tx">Source</label>
              <select id="fw-src" class="input" v-model="form.source">
                <option v-for="s in SOURCES" :key="s.value" :value="s.value">{{ s.label }}</option>
              </select>
              <input v-if="form.source === '__custom'" class="input mono" placeholder="e.g. 203.0.113.0/24" v-model="form.custom" />
            </div>

            <div class="flex justify-end gap-2 mt-1">
              <btn type="button" @click="showAdd = false">Cancel</btn>
              <btn type="submit" variant="primary">
                <l-icon name="plus" /> Add rule
              </btn>
            </div>
          </form>
        </div>
      </div>
    </section>
  `,
};
