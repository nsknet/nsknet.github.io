import { MOCK, appState, addToast } from '../store.js';

const { ref, computed, onMounted, nextTick } = Vue;

const NS_KEYS = ['all', 'service', 'site', 'nginx', 'firewall', 'system', 'tool'];

const NS_CLS = {
  service:  'bg-c-infosoft text-c-info',
  site:     'bg-[color-mix(in_oklab,#8b5cf6_12%,transparent)] text-[#8b5cf6]',
  nginx:    'bg-[color-mix(in_oklab,#16a34a_12%,transparent)] text-[#16a34a]',
  firewall: 'bg-c-dngsoft text-c-danger',
  system:   'bg-c-warnsoft text-c-warn',
  tool:     'bg-c-acsoft text-c-accent',
};

export const Logs = {
  name: 'ScreenLogs',
  setup() {
    const ns     = ref('all');
    const search = ref('');

    const filtered = computed(() => {
      const q = search.value.toLowerCase();
      return MOCK.audit.filter((row) => {
        if (ns.value !== 'all' && !row.a.startsWith(ns.value + '.')) return false;
        if (q) {
          const hay = (row.a + ' ' + JSON.stringify(row.d)).toLowerCase();
          if (!hay.includes(q)) return false;
        }
        return true;
      });
    });

    const countLabel = computed(() =>
      filtered.value.length === MOCK.audit.length
        ? String(MOCK.audit.length)
        : `${filtered.value.length} of ${MOCK.audit.length}`
    );

    function nsFor(a) { return a.split('.')[0]; }

    function detailParts(d) {
      return Object.entries(d).map(([k, v]) => ({
        k, v: typeof v === 'string' ? v : JSON.stringify(v),
      }));
    }

    onMounted(() => nextTick(() => window.lucide?.createIcons()));

    return { MOCK, appState, ns, search, filtered, countLabel, NS_KEYS, NS_CLS, nsFor, detailParts, addToast };
  },
  template: `
    <section>
      <div class="flex items-end justify-between gap-6 mb-6">
        <div>
          <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">Audit logs</h1>
          <div class="text-sm-var text-c-tx2">
            {{ countLabel }} entries · tailing <span class="mono">/var/log/nspanel/audit.log</span>
          </div>
        </div>
        <div class="flex gap-2">
          <btn @click="addToast({ t: 'Export started', d: 'audit.log download would begin.', k: 'ok' })">
            <l-icon name="download" /> Export
          </btn>
          <btn @click="addToast({ t: 'Logs refreshed', k: 'info' })">
            <l-icon name="refresh-cw" /> Refresh
          </btn>
        </div>
      </div>

      <div class="flex items-center gap-2 mb-3 flex-wrap">
        <div class="relative flex-1 max-w-xs">
          <l-icon name="search" is="position:absolute;left:10px;top:50%;transform:translateY(-50%);pointer-events:none;color:var(--text-3);width:14px;height:14px" />
          <input class="input h-8 pl-[30px]" placeholder="Search action or detail…" v-model="search" />
        </div>
        <button v-for="k in NS_KEYS" :key="k"
          :class="['h-7 px-2.5 rounded-full border text-xs-var mono cursor-pointer inline-flex items-center gap-1 transition-colors', ns === k ? 'bg-c-tx text-c-txinv border-c-tx' : 'bg-c-bg text-c-tx2 border-c-border hover:text-c-tx hover:border-c-bstrong']" @click="ns = k">
          {{ k === 'all' ? 'all' : k + '.*' }}
        </button>
      </div>

      <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
        <table class="tbl">
          <thead><tr>
            <th style="width:180px">Timestamp (UTC)</th>
            <th style="width:160px">Action</th>
            <th>Detail</th>
          </tr></thead>
          <tbody>
            <tr v-if="appState.fetching.logs && !MOCK.audit.length">
              <td colspan="3">
                <div class="text-center py-8 px-6 text-c-tx2">
                  <span class="inline-flex items-center gap-2">
                    <svg class="animate-spin h-3.5 w-3.5 text-c-accent" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                      <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                    </svg>
                    Loading logs…
                  </span>
                </div>
              </td>
            </tr>
            <tr v-else-if="!filtered.length">
              <td colspan="3">
                <div class="text-center py-8 px-6 text-c-tx2">
                  <div class="w-11 h-11 rounded-xl bg-c-subtle grid place-items-center mx-auto mb-3"><l-icon name="search-x" is="width:20px;height:20px;color:var(--text-3)" /></div>
                  <div class="text-c-tx font-medium text-sm-var">No matching entries</div>
                </div>
              </td>
            </tr>
            <tr v-for="row in filtered" :key="row.t + row.a">
              <td class="mono muted text-xs-var">{{ row.t }}</td>
              <td><span class="inline-flex items-center gap-1.5 h-[22px] px-2 mono text-xs-var font-medium rounded-[5px] tracking-[-0.005em]" :class="NS_CLS[nsFor(row.a)]"><span class="w-[5px] h-[5px] rounded-full bg-current"></span>{{ row.a }}</span></td>
              <td class="mono text-xs-var text-c-tx2 break-words" style="white-space:normal">
                <template v-for="(part, i) in detailParts(row.d)" :key="part.k">
                  <span v-if="i > 0" class="text-c-tx3 mx-0.5"> · </span>
                  <span class="text-c-tx3">{{ part.k }}</span>=<span class="text-c-tx">{{ part.v }}</span>
                </template>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
  `,
};
