import { MOCK, appState, navigate, addToast, runJobAction, fetchSamples, confirmThen } from '../store.js';

const { ref, computed, onMounted, nextTick } = Vue;

const IPV4_RE = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;
const DOMAIN_RE = /^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/;

export const DNS = {
  name: 'ScreenDNS',
  setup() {
    const ip = ref('');
    const domain = ref('');
    const editing = ref(null); // domain currently being edited (locks the field)

    const dns = computed(() => MOCK.dns);

    const canSubmit = computed(() =>
      IPV4_RE.test(ip.value.trim()) && DOMAIN_RE.test(domain.value.trim().replace(/\.$/, ''))
    );

    function resetForm() {
      ip.value = '';
      domain.value = '';
      editing.value = null;
    }

    async function submit() {
      const ipv = ip.value.trim();
      const dom = domain.value.trim().replace(/\.$/, '').toLowerCase();
      if (!IPV4_RE.test(ipv)) {
        addToast({ t: 'Invalid IP', d: 'Enter a valid IPv4 address.', k: 'danger' });
        return;
      }
      if (!DOMAIN_RE.test(dom)) {
        addToast({ t: 'Invalid domain', d: 'Enter a valid domain name.', k: 'danger' });
        return;
      }
      const res = await runJobAction(
        '/api/v1/dns/records',
        { ip: ipv, domain: dom },
        '',
        resetForm
      );
      if (res) resetForm();
    }

    function edit(rec) {
      editing.value = rec.domain;
      domain.value = rec.domain;
      ip.value = rec.ip;
      nextTick(() => window.lucide?.createIcons());
    }

    function remove(rec) {
      confirmThen(
        `Delete DNS record?`,
        `Remove the mapping ${rec.domain} → ${rec.ip}. Clients will stop resolving it within a few seconds.`,
        () => runJobAction('/api/v1/dns/records/delete', { domain: rec.domain }, '')
      );
    }

    async function refresh() {
      await fetchSamples('', ['dns']);
      addToast({ t: 'DNS refreshed', k: 'info' });
    }

    onMounted(() => nextTick(() => window.lucide?.createIcons()));

    return { MOCK, appState, dns, ip, domain, editing, canSubmit, submit, edit, remove, refresh, resetForm, navigate };
  },
  template: `
    <section>
      <div class="flex items-end justify-between gap-6 mb-6">
        <div>
          <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">DNS</h1>
          <div class="text-sm-var text-c-tx2 flex items-center gap-2">
            <template v-if="dns.installed">
              {{ dns.records.length }} record{{ dns.records.length === 1 ? '' : 's' }} · CoreDNS
              <badge :tone="dns.running ? 'ok' : 'muted'" dot>{{ dns.running ? 'running' : 'stopped' }}</badge>
            </template>
            <template v-else>Local DNS server (CoreDNS) — map domains to IP addresses.</template>
          </div>
        </div>
        <div v-if="dns.installed" class="flex gap-2">
          <btn @click="refresh"><l-icon name="refresh-cw" /> Refresh</btn>
        </div>
      </div>

      <!-- Loading state: first fetch in flight, nothing known yet -->
      <div v-if="appState.fetching.dns && !dns.installed && !dns.records.length" class="bg-c-elev border border-c-border rounded-theme text-center py-14 px-6">
        <svg class="animate-spin h-6 w-6 text-c-accent mx-auto mb-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
        </svg>
        <div class="text-sm-var text-c-tx2">Checking CoreDNS status…</div>
      </div>

      <!-- Empty state: CoreDNS not installed -->
      <div v-else-if="!dns.installed" class="bg-c-elev border border-c-border rounded-theme text-center py-14 px-6">
        <div class="w-12 h-12 rounded-xl bg-c-subtle grid place-items-center mx-auto mb-4">
          <l-icon name="network" is="width:22px;height:22px;color:var(--text-3)" />
        </div>
        <div class="text-c-tx font-medium text-[15px] mb-1">CoreDNS is not installed</div>
        <div class="text-sm-var text-c-tx2 mb-5 max-w-md mx-auto">
          Please install CoreDNS to manage DNS records. Once installed, you can map
          domain names to IPv4 addresses right here.
        </div>
        <btn variant="primary" @click="navigate('tools')">
          <l-icon name="download" /> Go to Tools to install CoreDNS
        </btn>
      </div>

      <!-- Installed: record management -->
      <template v-else>
        <!-- Add / edit form -->
        <div class="bg-c-bg border border-c-border rounded-theme p-4 mb-4">
          <div class="flex items-end gap-3 flex-wrap">
            <div class="flex flex-col gap-1">
              <label class="text-[10px] uppercase tracking-[0.05em] text-c-tx3">IPv4 address</label>
              <input class="input h-8 w-44 mono" type="text" name="dns-ip" autocomplete="off"
                placeholder="192.168.1.10" v-model="ip" @keyup.enter="submit" />
            </div>
            <div class="flex flex-col gap-1 flex-1 min-w-[180px]">
              <label class="text-[10px] uppercase tracking-[0.05em] text-c-tx3">Domain</label>
              <input class="input h-8 mono" type="text" name="dns-domain" autocomplete="off"
                :readonly="!!editing" :placeholder="editing ? '' : 'example.com'" v-model="domain" @keyup.enter="submit" />
            </div>
            <btn variant="primary" :disabled="!canSubmit" @click="submit">
              <l-icon :name="editing ? 'save' : 'plus'" /> {{ editing ? 'Update' : 'Add record' }}
            </btn>
            <btn v-if="editing" variant="ghost" @click="resetForm">Cancel</btn>
          </div>
        </div>

        <!-- Records table -->
        <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
          <table class="tbl">
            <thead><tr><th>Domain</th><th>IPv4</th><th class="w-px"></th></tr></thead>
            <tbody>
              <tr v-for="r in dns.records" :key="r.domain">
                <td><strong class="mono">{{ r.domain }}</strong></td>
                <td class="mono muted">{{ r.ip }}</td>
                <td>
                  <div class="flex items-center gap-1 justify-end">
                    <btn sm square title="Edit" @click="edit(r)"><l-icon name="pencil" /></btn>
                    <btn variant="ghost" sm square title="Delete" @click="remove(r)"><l-icon name="trash-2" /></btn>
                  </div>
                </td>
              </tr>
              <tr v-if="!dns.records.length">
                <td colspan="3" class="text-center text-c-tx2 py-8">
                  No records yet. Add one above — e.g. <span class="mono">192.168.1.10 example.com</span>.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </template>
    </section>
  `,
};
