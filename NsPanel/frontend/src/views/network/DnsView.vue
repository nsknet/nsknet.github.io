<script setup lang="ts">
/** CoreDNS host records — map a domain to an IPv4 address. */
import { storeToRefs } from 'pinia';
import { computed, reactive, ref } from 'vue';

import type { DnsRecord } from '@/api/types';
import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import CardHeader from '@/components/ui/CardHeader.vue';
import DataTable from '@/components/ui/DataTable.vue';
import EmptyState from '@/components/ui/EmptyState.vue';
import ErrorState from '@/components/ui/ErrorState.vue';
import Field from '@/components/ui/Field.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import Skeleton from '@/components/ui/Skeleton.vue';
import type { Column } from '@/components/ui/types';
import { useJobRunner } from '@/composables/useJobs';
import { useRefresh } from '@/composables/useRefresh';
import { useDnsStore } from '@/stores/misc';
import { useUiStore } from '@/stores/ui';
import { ipv4 } from '@/utils/validate';

const ui = useUiStore();
const { run } = useJobRunner();
const { refresh, refreshing } = useRefresh();
const dnsStore = useDnsStore();
const { dns, loading, loaded, error } = storeToRefs(dnsStore);

/** features/dns.py _DOMAIN_RE: one or more labels; a bare host name is fine. */
const DNS_NAME =
  /^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/;

const form = reactive({ ip: '', domain: '' });
/** Domain being edited — the field is locked so the record is replaced, not renamed. */
const editing = ref<string | null>(null);
const submitted = ref(false);
const touched = reactive({ ip: false, domain: false });
const pending = ref(false);
const domainInput = ref<HTMLInputElement | null>(null);
const ipInput = ref<HTMLInputElement | null>(null);

const normalizedDomain = computed(() => form.domain.trim().replace(/\.$/, '').toLowerCase());
const ipError = computed(() => (form.ip.trim() ? ipv4(form.ip) : 'Enter the IPv4 address to resolve to.'));
const domainError = computed(() => {
  if (!normalizedDomain.value) return 'Enter a domain, e.g. app.lan or example.com.';
  return DNS_NAME.test(normalizedDomain.value)
    ? ''
    : 'Letters, digits and hyphens, labels separated by dots.';
});
const replaces = computed(() =>
  !editing.value ? dns.value.records.find((record) => record.domain === normalizedDomain.value) : undefined,
);

const show = (key: 'ip' | 'domain', message: string) => (submitted.value || touched[key] ? message : '');

const columns: Column<DnsRecord>[] = [
  { key: 'domain', label: 'Domain', sortable: true, class: 'mono font-medium' },
  {
    key: 'ip',
    label: 'IPv4 address',
    sortable: true,
    class: 'mono text-c-tx2',
    sortValue: (r) =>
      r.ip
        .split('.')
        .map((p) => p.padStart(3, '0'))
        .join('.'),
  },
  { key: 'actions', label: 'Actions', srOnlyLabel: true, align: 'right' },
];

function resetForm(): void {
  form.ip = '';
  form.domain = '';
  editing.value = null;
  submitted.value = false;
  touched.ip = false;
  touched.domain = false;
}

async function submit(): Promise<void> {
  submitted.value = true;
  if (ipError.value || domainError.value) return;
  pending.value = true;
  const result = await run('/api/v1/dns/records', { ip: form.ip.trim(), domain: normalizedDomain.value });
  pending.value = false;
  if (result) resetForm();
}

function edit(record: DnsRecord): void {
  editing.value = record.domain;
  form.domain = record.domain;
  form.ip = record.ip;
  submitted.value = false;
  ipInput.value?.focus();
  ipInput.value?.select();
}

function cancelEdit(): void {
  resetForm();
  domainInput.value?.focus();
}

function remove(record: DnsRecord): void {
  ui.confirmThen(
    `Delete ${record.domain}?`,
    `Remove the mapping ${record.domain} → ${record.ip}. Clients stop resolving it within a few seconds.`,
    () => void run('/api/v1/dns/records/delete', { domain: record.domain }),
    { danger: true, confirmLabel: 'Delete record' },
  );
}
</script>

<template>
  <section>
    <PageHeader title="DNS">
      <template #subtitle>
        <span class="inline-flex flex-wrap items-center gap-2">
          <template v-if="dns.installed">
            CoreDNS{{ dns.version ? ` ${dns.version}` : '' }} · {{ dns.records.length }} record{{
              dns.records.length === 1 ? '' : 's'
            }}
            <Badge :tone="dns.running ? 'ok' : 'danger'" dot>{{ dns.running ? 'running' : 'stopped' }}</Badge>
          </template>
          <template v-else>Local DNS server (CoreDNS): map domain names to IPv4 addresses.</template>
        </span>
      </template>
      <Btn :loading="refreshing" @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
    </PageHeader>

    <Card v-if="loading && !loaded" class="p-4"><Skeleton :count="3" /></Card>

    <Card v-else-if="error && !loaded">
      <ErrorState :message="error" @retry="dnsStore.load()" />
    </Card>

    <Card v-else-if="!dns.installed">
      <EmptyState icon="globe" title="CoreDNS is not installed">
        <p class="m-0 mb-4 max-w-md mx-auto">
          Install CoreDNS from Tools to answer DNS queries for your LAN. Records you add here are written to
          <span class="mono">/etc/coredns/hosts</span>.
        </p>
        <Btn variant="primary" @click="$router.push('/tools')"> <LIcon name="package" /> Open Tools </Btn>
      </EmptyState>
    </Card>

    <template v-else>
      <Card class="mb-4 overflow-clip">
        <CardHeader :title="editing ? `Edit ${editing}` : 'Add record'" :icon="editing ? 'pencil' : 'plus'" />
        <form
          class="p-4 flex flex-col md:flex-row md:items-start gap-3 md:gap-4"
          novalidate
          @submit.prevent="submit"
        >
          <Field
            v-slot="f"
            label="Domain"
            class="flex-1"
            required
            :error="show('domain', domainError)"
            :help="
              editing
                ? 'To rename, delete the record and add a new one.'
                : 'A host name (nas) or a full domain (nas.home.lan).'
            "
          >
            <input
              :id="f.id"
              ref="domainInput"
              v-model="form.domain"
              class="input mono"
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
              placeholder="app.example.lan"
              :readonly="!!editing"
              :aria-describedby="f.describedBy"
              :aria-invalid="f.invalid"
              @blur="touched.domain = true"
            />
          </Field>
          <Field v-slot="f" label="IPv4 address" class="md:w-56" required :error="show('ip', ipError)">
            <input
              :id="f.id"
              ref="ipInput"
              v-model="form.ip"
              class="input mono"
              inputmode="decimal"
              autocomplete="off"
              spellcheck="false"
              placeholder="192.168.1.10"
              :aria-describedby="f.describedBy"
              :aria-invalid="f.invalid"
              @blur="touched.ip = true"
            />
          </Field>
          <div class="flex flex-wrap gap-2 md:pt-[26px]">
            <Btn type="submit" variant="primary" :loading="pending">
              <LIcon :name="editing ? 'check' : 'plus'" />
              {{ editing ? 'Save' : replaces ? 'Replace' : 'Add record' }}
            </Btn>
            <Btn v-if="editing" variant="ghost" :disabled="pending" @click="cancelEdit">Cancel</Btn>
          </div>
        </form>
        <p v-if="replaces" class="m-0 px-4 pb-3 -mt-1 text-xs-var text-c-warn" role="status">
          {{ replaces.domain }} already points to <span class="mono">{{ replaces.ip }}</span>; saving replaces
          it.
        </p>
      </Card>

      <Card class="overflow-clip">
        <CardHeader title="Records" icon="list" :subtitle="dns.hosts_file" />
        <DataTable
          :columns="columns"
          :rows="dns.records"
          row-key="domain"
          label="DNS records"
          :loading="loading"
          :error="error"
          sort-key="domain"
          empty-icon="globe"
          empty-title="No records yet"
          empty-hint="Add one above, e.g. app.example.lan → 192.168.1.10."
          @retry="dnsStore.load()"
        >
          <template #cell-actions="{ row }">
            <div class="flex items-center gap-1 justify-end">
              <Btn sm square :aria-label="`Edit ${row.domain}`" title="Edit" @click="edit(row)">
                <LIcon name="pencil" />
              </Btn>
              <Btn
                variant="danger"
                sm
                square
                :aria-label="`Delete ${row.domain}`"
                title="Delete"
                @click="remove(row)"
              >
                <LIcon name="trash-2" />
              </Btn>
            </div>
          </template>
        </DataTable>
      </Card>
    </template>
  </section>
</template>
