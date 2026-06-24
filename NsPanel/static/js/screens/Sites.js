import { MOCK, appState, navigate, openSite, addToast, fetchSamples } from '../store.js';

const { computed, onMounted, nextTick } = Vue;

export const Sites = {
  name: 'ScreenSites',
  setup() {
    async function refresh() {
      await fetchSamples();
      addToast({ t: 'Sites refreshed', k: 'info' });
    }

    onMounted(() => nextTick(() => window.lucide?.createIcons()));

    return { MOCK, appState, navigate, openSite, refresh };
  },
  template: `
    <section>
      <div class="flex items-end justify-between gap-6 mb-6">
        <div>
          <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">Sites</h1>
          <div class="text-sm-var text-c-tx2">
            {{ MOCK.sites.length }} virtual hosts ·
            Nginx <badge tone="ok" dot>active</badge>
          </div>
        </div>
        <div class="flex gap-2">
          <btn @click="refresh">
            <l-icon name="refresh-cw" /> Refresh
          </btn>
          <btn variant="primary" @click="navigate('create-site')">
            <l-icon name="plus" /> Create site
          </btn>
        </div>
      </div>

      <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
        <table class="tbl">
          <thead><tr>
            <th>Name</th><th>Type</th><th>Access</th><th>Status</th>
            <th class="num">PID</th><th>Mem (MB)</th><th>CPU (%)</th><th>Modified</th><th></th>
          </tr></thead>
          <tbody>
            <tr v-if="appState.fetching.sites && !MOCK.sites.length">
              <td colspan="9" class="muted" style="text-align:center; padding:32px 0">
                <span class="inline-flex items-center gap-2 text-c-tx2">
                  <svg class="animate-spin h-3.5 w-3.5 text-c-accent" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                  </svg>
                  Loading sites…
                </span>
              </td>
            </tr>
            <tr v-else-if="!MOCK.sites.length">
              <td colspan="9" class="muted" style="text-align:center; padding:32px 0">
                No sites yet — use <strong>Create site</strong> to add one.
              </td>
            </tr>
            <tr v-for="s in MOCK.sites" :key="s.slug" class="row-click" @click="openSite(s.slug)">
              <td><strong>{{ s.name }}</strong></td>
              <td><type-chip :type="s.type" /></td>
              <td class="mono muted">{{ s.access }}</td>
              <td><status-badge :status="s.status" /></td>
              <td class="num muted">{{ s.pid || '—' }}</td>
              <td class="num">{{ s.mem != null ? s.mem.toFixed(1) : '—' }}</td>
              <td class="num">{{ s.cpu != null ? s.cpu.toFixed(1) : '—' }}</td>
              <td class="muted">{{ s.modified }}</td>
              <td><l-icon name="chevron-right" is="width:14px;height:14px;color:var(--text-3)" /></td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
  `,
};
