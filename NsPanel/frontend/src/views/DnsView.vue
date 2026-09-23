<script setup lang="ts">
/** CoreDNS host records — map a domain to an IPv4 address. */
import { storeToRefs } from 'pinia';
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';

import type { DnsRecord } from '@/api/types';
import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import Spinner from '@/components/ui/Spinner.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useDnsStore } from '@/stores/misc';
import { useUiStore } from '@/stores/ui';

const router = useRouter();
const ui = useUiStore();
const { run, reload } = useJobRunner();
const { dns, loading } = storeToRefs(useDnsStore());

const IPV4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;
const DOMAIN =
  /^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/;

const ip = ref('');
const domain = ref('');
/** Domain being edited — the field is locked so the record is replaced, not renamed. */
const editing = ref<string | null>(null);

const canSubmit = computed(
  () => IPV4.test(ip.value.trim()) && DOMAIN.test(domain.value.trim().replace(/\.$/, '')),
);

function resetForm(): void {
  ip.value = '';
  domain.value = '';
  editing.value = null;
}

async function submit(): Promise<void> {
  const address = ip.value.trim();
  const name = domain.value.trim().replace(/\.$/, '').toLowerCase();

  if (!IPV4.test(address)) {
    ui.addToast({ t: 'Invalid IP', d: 'Enter a valid IPv4 address.', k: 'danger' });
    return;
  }
  if (!DOMAIN.test(name)) {
    ui.addToast({ t: 'Invalid domain', d: 'Enter a valid domain name.', k: 'danger' });
    return;
  }

  const result = await run('/api/v1/dns/records', { ip: address, domain: name });
  if (result) resetForm();
}

function edit(record: DnsRecord): void {
  editing.value = record.domain;
  domain.value = record.domain;
  ip.value = record.ip;
}

function remove(record: DnsRecord): void {
  ui.confirmThen(
    'Delete DNS record?',
    `Remove the mapping ${record.domain} → ${record.ip}. Clients will stop resolving it within a few seconds.`,
    () => {
      void run('/api/v1/dns/records/delete', { domain: record.domain });
    },
  );
}

async function refresh(): Promise<void> {
  await reload();
  ui.addToast({ t: 'DNS refreshed', k: 'info' });
}
</script>

<template>
  <section>
    <PageHeader title="DNS">
      <template #subtitle>
        <span class="flex items-center gap-2">
          <template v-if="dns.installed">
            {{ dns.records.length }} record{{ dns.records.length === 1 ? '' : 's' }} · CoreDNS
            <Badge :tone="dns.running ? 'ok' : 'muted'" dot>{{
              dns.running ? 'running' : 'stopped'
            }}</Badge>
          </template>
          <template v-else>Local DNS server (CoreDNS) — map domains to IP addresses.</template>
        </span>
      </template>
      <template v-if="dns.installed">
        <Btn @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
      </template>
    </PageHeader>

    <div
      v-if="loading && !dns.installed && !dns.records.length"
      class="bg-c-elev border border-c-border rounded-theme text-center py-14 px-6"
    >
      <Spinner label="Checking CoreDNS status…" />
    </div>

    <div
      v-else-if="!dns.installed"
      class="bg-c-elev border border-c-border rounded-theme text-center py-14 px-6"
    >
      <div class="w-12 h-12 rounded-xl bg-c-subtle grid place-items-center mx-auto mb-4">
        <LIcon name="network" is="width:22px;height:22px;color:var(--text-3)" />
      </div>
      <div class="text-c-tx font-medium text-[15px] mb-1">CoreDNS is not installed</div>
      <div class="text-sm-var text-c-tx2 mb-5 max-w-md mx-auto">
        Install CoreDNS to manage DNS records. Once installed, you can map domain names to IPv4
        addresses right here.
      </div>
      <Btn variant="primary" @click="router.push('/tools')">
        <LIcon name="download" /> Go to Tools to install CoreDNS
      </Btn>
    </div>

    <template v-else>
      <Card class="p-4 mb-4">
        <div class="flex items-end gap-3 flex-wrap">
          <div class="flex flex-col gap-1">
            <label class="text-[10px] uppercase tracking-[0.05em] text-c-tx3">IPv4 address</label>
            <input
              v-model="ip"
              class="input h-8 w-44 mono"
              type="text"
              autocomplete="off"
              placeholder="192.168.1.10"
              @keyup.enter="submit"
            />
          </div>
          <div class="flex flex-col gap-1 flex-1 min-w-[180px]">
            <label class="text-[10px] uppercase tracking-[0.05em] text-c-tx3">Domain</label>
            <input
              v-model="domain"
              class="input h-8 mono"
              type="text"
              autocomplete="off"
              :readonly="!!editing"
              :placeholder="editing ? '' : 'example.com'"
              @keyup.enter="submit"
            />
          </div>
          <Btn variant="primary" :disabled="!canSubmit" @click="submit">
            <LIcon :name="editing ? 'save' : 'plus'" /> {{ editing ? 'Update' : 'Add record' }}
          </Btn>
          <Btn v-if="editing" variant="ghost" @click="resetForm">Cancel</Btn>
        </div>
      </Card>

      <Card class="overflow-clip">
        <table class="tbl">
          <thead>
            <tr>
              <th>Domain</th>
              <th>IPv4</th>
              <th class="w-px"></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="record in dns.records" :key="record.domain">
              <td>
                <strong class="mono">{{ record.domain }}</strong>
              </td>
              <td class="mono muted">{{ record.ip }}</td>
              <td>
                <div class="flex items-center gap-1 justify-end">
                  <Btn sm square title="Edit" @click="edit(record)"><LIcon name="pencil" /></Btn>
                  <Btn variant="ghost" sm square title="Delete" @click="remove(record)">
                    <LIcon name="trash-2" />
                  </Btn>
                </div>
              </td>
            </tr>
            <tr v-if="!dns.records.length">
              <td colspan="3" class="text-center text-c-tx2 py-8">
                No records yet. Add one above — e.g.
                <span class="mono">192.168.1.10 example.com</span>.
              </td>
            </tr>
          </tbody>
        </table>
      </Card>
    </template>
  </section>
</template>
