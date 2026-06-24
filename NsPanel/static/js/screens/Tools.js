import { MOCK, appState, addToast, runJobAction, fetchSamples, openInstallDialog, confirmThen } from '../store.js';

const { ref, computed, onMounted, nextTick } = Vue;

export const Tools = {
  name: 'ScreenTools',
  setup() {
    const filter = ref('all');
    const search = ref('');

    const installedCount = computed(() => MOCK.tools.filter((t) => t.installed).length);

    const filtered = computed(() => {
      const q = search.value.toLowerCase();
      return MOCK.tools.filter((t) => {
        if (filter.value === 'installed'     && !t.installed) return false;
        if (filter.value === 'not-installed' &&  t.installed) return false;
        if (q && !(t.name.toLowerCase().includes(q) || (t.desc || '').toLowerCase().includes(q))) return false;
        return true;
      });
    });

    function diagRows(t) {
      const rows = [...(t.diag || [])];
      if (t.ports)   rows.push(['Ports', t.ports]);
      if (t.version) rows.push(['Version', t.version]);
      return rows;
    }

    async function recheck(t) {
      await fetchSamples();
      addToast({ t: 'Tool status updated', d: `Checked ${t.name} state.`, k: 'info' });
    }

    async function recheckAll() {
      await fetchSamples();
      addToast({ t: 'Tool statuses refreshed', k: 'info' });
    }

    function install(t, opts = {}) {
      const reinstall = !!opts.reinstall;
      const run = (payload = {}) => {
        if (reinstall) payload.reinstall = 'true';
        return runJobAction(
          `/api/v1/tools/${t.id}/install`,
          payload,
          `${reinstall ? 'Re-installing' : 'Installing'} ${t.name}`
        );
      };

      // Tools that need a password, open a firewall port, or declare custom
      // install params get a config dialog first; everything else installs
      // straight away.
      if (t.requiresPassword || t.firewallPorts?.length || t.installParams?.length) {
        openInstallDialog(t, run);
      } else {
        run();
      }
    }

    function reinstall(t) {
      confirmThen(
        `Re-install ${t.name}?`,
        'Re-runs the installer: re-applies packages and configuration. Existing data is kept, but credentials/config may be regenerated.',
        () => install(t, { reinstall: true })
      );
    }

    function uninstall(t) {
      confirmThen(
        `Uninstall ${t.name}?`,
        'Stops the service and removes its packages. For databases the data directory is deleted too. This cannot be undone.',
        () => runJobAction(`/api/v1/tools/${t.id}/uninstall`, {}, `Uninstalling ${t.name}`)
      );
    }

    function changePassword(t) {
      openInstallDialog(
        t,
        (payload) => runJobAction(`/api/v1/tools/${t.id}/change-password`, payload, `Changing ${t.name} password`),
        { mode: 'password' }
      );
    }

    onMounted(() => nextTick(() => window.lucide?.createIcons()));

    return { MOCK, appState, filter, search, installedCount, filtered, diagRows, recheck, recheckAll, install, reinstall, uninstall, changePassword, addToast };
  },
  template: `
    <section>
      <div class="flex items-end justify-between gap-6 mb-6">
        <div>
          <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">Tools</h1>
          <div class="text-sm-var text-c-tx2">
            {{ installedCount }} of {{ MOCK.tools.length }} tools installed. One-click provisioning, live health.
          </div>
        </div>
        <div class="flex gap-2">
          <btn @click="recheckAll">
            <l-icon name="refresh-cw" /> Re-check all
          </btn>
        </div>
      </div>

      <div class="flex items-center gap-2 mb-3 flex-wrap">
        <div class="relative flex-1 max-w-xs">
          <l-icon name="search" is="position:absolute;left:10px;top:50%;transform:translateY(-50%);pointer-events:none;color:var(--text-3);width:14px;height:14px" />
          <input class="input h-8 pl-[30px]" type="search" name="tool-filter" autocomplete="off" placeholder="Filter tools…" v-model="search" />
        </div>
        <button v-for="f in ['all','installed','not-installed']" :key="f"
          :class="['h-7 px-2.5 rounded-full border text-xs-var mono cursor-pointer inline-flex items-center gap-1 transition-colors', filter === f ? 'bg-c-tx text-c-txinv border-c-tx' : 'bg-c-bg text-c-tx2 border-c-border hover:text-c-tx hover:border-c-bstrong']" @click="filter = f">
          {{ f === 'all' ? 'All' : f === 'installed' ? 'Installed' : 'Not installed' }}
        </button>
      </div>

      <div v-if="appState.fetching.tools && !MOCK.tools.length" class="text-center py-12 px-6 text-c-tx2" style="grid-column:1/-1">
        <svg class="animate-spin h-6 w-6 text-c-accent mx-auto mb-3" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
        </svg>
        <div class="text-c-tx font-medium text-sm-var">Loading tools…</div>
      </div>

      <div v-else-if="!filtered.length" class="text-center py-12 px-6 text-c-tx2" style="grid-column:1/-1">
        <div class="w-11 h-11 rounded-xl bg-c-subtle grid place-items-center mx-auto mb-3"><l-icon name="search-x" is="width:20px;height:20px;color:var(--text-3)" /></div>
        <div class="text-c-tx font-medium text-sm-var mb-1">No matches</div>
        <div class="text-xs-var">Adjust the filters or search query.</div>
      </div>

      <div class="grid gap-3" style="grid-template-columns:repeat(auto-fill,minmax(320px,1fr))">
        <template v-for="t in filtered" :key="t.id">

          <!-- Installed tool -->
          <div v-if="t.installed" class="flex flex-col gap-3 p-[18px] bg-c-bg border border-c-border rounded-theme transition-colors hover:border-c-bstrong">
            <div class="flex items-start gap-3">
              <div class="w-10 h-10 rounded-[9px] bg-c-subtle flex items-center justify-center shrink-0 overflow-hidden p-1.5 select-none">
                <img v-if="t.logo.endsWith('.png')" :src="t.logo" class="w-full h-full object-contain" />
                <span v-else class="text-[13px] font-bold mono tracking-[-0.02em]" :style="{ color: t.color }">{{ t.logo }}</span>
              </div>
              <div class="flex-1 min-w-0">
                <div class="flex items-center justify-between gap-2 min-w-0">
                  <div class="font-semibold text-[15px] tracking-[-0.01em] truncate" :title="t.name">{{ t.name }}</div>
                  <status-badge :status="t.state" />
                </div>
                <div class="text-xs-var text-c-tx2 mt-0.5 leading-normal">{{ t.desc }}</div>
              </div>
            </div>
            <div class="grid gap-x-3.5 gap-y-1.5 text-xs-var pt-2.5 border-t border-c-border" style="grid-template-columns:auto 1fr">
              <template v-for="r in diagRows(t)" :key="r[0]">
                <div class="text-c-tx3 uppercase tracking-[0.05em] text-[10px] pt-0.5">{{ r[0] }}</div>
                <div class="text-c-tx mono text-xs-var tabular-nums">{{ r[1] }}</div>
              </template>
            </div>
            <div class="flex items-center gap-1.5 mt-auto pt-1">
              <btn sm @click="recheck(t)">
                <l-icon name="refresh-cw" /> Re-check
              </btn>
              <span class="flex-1"></span>
              <btn sm square @click="reinstall(t)" title="Re-install (re-run installer)">
                <l-icon name="rotate-cw" />
              </btn>
              <btn v-if="t.canChangePassword" sm square @click="changePassword(t)" title="Change password">
                <l-icon name="key-round" />
              </btn>
              <btn v-if="t.canUninstall" variant="ghost" sm square @click="uninstall(t)" title="Uninstall">
                <l-icon name="trash-2" />
              </btn>
            </div>
          </div>

          <!-- Not installed tool -->
          <div v-else class="flex flex-col gap-3 p-[18px] bg-c-elev border border-c-border rounded-theme transition-colors hover:border-c-bstrong">
            <div class="flex items-start gap-3">
              <div class="w-10 h-10 rounded-[9px] bg-c-subtle flex items-center justify-center shrink-0 overflow-hidden p-1.5 opacity-70 select-none">
                <img v-if="t.logo.endsWith('.png')" :src="t.logo" class="w-full h-full object-contain" />
                <span v-else class="text-[13px] font-bold mono tracking-[-0.02em]" :style="{ color: t.color }">{{ t.logo }}</span>
              </div>
              <div class="flex-1 min-w-0">
                <div class="flex items-center justify-between gap-2 min-w-0">
                  <div class="font-semibold text-[15px] tracking-[-0.01em] truncate" :title="t.name">{{ t.name }}</div>
                  <status-badge status="not installed" />
                </div>
                <div class="text-xs-var text-c-tx2 mt-0.5 leading-normal">{{ t.desc }}</div>
              </div>
            </div>
            <div v-if="t.requiresPassword || (t.firewallPorts && t.firewallPorts.length)" class="flex flex-wrap gap-1.5">
              <span v-if="t.requiresPassword" class="inline-flex items-center gap-1 text-[10px] text-c-tx3 mono uppercase tracking-[0.05em] px-1.5 py-0.5 bg-c-subtle border border-c-border rounded">
                <l-icon name="key-round" is="width:11px;height:11px" /> password
              </span>
              <span v-if="t.firewallPorts && t.firewallPorts.length" class="inline-flex items-center gap-1 text-[10px] text-c-tx3 mono uppercase tracking-[0.05em] px-1.5 py-0.5 bg-c-subtle border border-c-border rounded">
                <l-icon name="shield" is="width:11px;height:11px" /> port {{ t.firewallPorts.join(', ') }}
              </span>
            </div>
            <div class="flex gap-1.5 mt-auto pt-1">
              <btn variant="primary" sm @click="install(t)">
                <l-icon name="download" /> Install
              </btn>
              <span class="flex-1"></span>
              <btn variant="ghost" sm @click="recheck(t)">
                <l-icon name="refresh-cw" /> Re-check
              </btn>
            </div>
          </div>

        </template>
      </div>
    </section>
  `,
};
