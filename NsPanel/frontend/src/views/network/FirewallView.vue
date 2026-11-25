<script setup lang="ts">
/** UFW: status and default policies, enable/disable, rules with lockout
 *  protection for the SSH and panel ports. */
import { storeToRefs } from 'pinia';
import { computed, ref } from 'vue';

import type { UfwRule } from '@/api/system';
import FirewallRuleDialog from '@/components/network/FirewallRuleDialog.vue';
import { protectionOf, type Protection } from '@/components/network/firewall';
import Alert from '@/components/ui/Alert.vue';
import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import CardHeader from '@/components/ui/CardHeader.vue';
import DataTable from '@/components/ui/DataTable.vue';
import ErrorState from '@/components/ui/ErrorState.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import type { Column, Tone } from '@/components/ui/types';
import { useJobRunner } from '@/composables/useJobs';
import { useRefresh } from '@/composables/useRefresh';
import { useFirewallStore } from '@/stores/misc';
import { useUiStore } from '@/stores/ui';

const ui = useUiStore();
const { run } = useJobRunner();
const { refresh, refreshing } = useRefresh();
const firewallStore = useFirewallStore();
const { firewall, loading, loaded, error } = storeToRefs(firewallStore);

const adding = ref(false);

const ACTION_TONE: Record<string, Tone> = { ALLOW: 'ok', DENY: 'danger', REJECT: 'danger', LIMIT: 'warn' };

interface RuleRow extends UfwRule {
  protection: Protection | null;
}

const rows = computed<RuleRow[]>(() =>
  firewall.value.rules.map((rule) => ({ ...rule, protection: protectionOf(rule, firewall.value) })),
);

const columns: Column<RuleRow>[] = [
  { key: 'num', label: '#', class: 'num text-c-tx3 w-12', sortable: true },
  { key: 'to', label: 'To', sortable: true },
  { key: 'action', label: 'Action', sortable: true },
  { key: 'from_', label: 'From', sortable: true },
  { key: 'is_v6', label: 'IP', hideOnMobile: true, sortValue: (row) => (row.is_v6 ? 6 : 4), sortable: true },
  { key: 'label', label: 'Label', hideOnMobile: true },
  { key: 'actions', label: 'Actions', srOnlyLabel: true, align: 'right' },
];

const accessSummary = computed(() => {
  const ssh = firewall.value.ssh_ports.join(', ') || '22';
  return `SSH ${ssh}/tcp · panel ${firewall.value.panel_port || '—'}/tcp`;
});

const subtitle = computed(() => {
  const state = firewall.value;
  if (!loaded.value) return 'Uncomplicated Firewall (UFW) on this host.';
  if (!state.installed) return 'UFW is not installed — every port is reachable.';
  const count = `${state.rules.length} rule${state.rules.length === 1 ? '' : 's'}`;
  return state.enabled ? `${count} enforced` : `UFW is off — ${count} saved, none enforced`;
});

const POLICY_TONE: Record<string, Tone> = { deny: 'ok', reject: 'ok', allow: 'warn' };

function policies(): { key: string; label: string; value: string }[] {
  const d = firewall.value.defaults;
  return [
    { key: 'incoming', label: 'Incoming', value: d.incoming ?? '' },
    { key: 'outgoing', label: 'Outgoing', value: d.outgoing ?? '' },
    { key: 'routed', label: 'Routed', value: d.routed ?? '' },
  ];
}

function enable(): void {
  const state = firewall.value;
  const ssh = state.ssh_ports.map((port) => `${port}/tcp`).join(', ');
  ui.confirmThen(
    state.installed ? 'Enable the firewall?' : 'Install and enable the firewall?',
    'Before switching UFW on, the panel allows the ports you need to stay connected.',
    () =>
      void run('/api/v1/firewall/install', {}, {
        title: state.installed ? 'Enabling UFW firewall' : 'Installing UFW firewall',
      }),
    {
      confirmLabel: state.installed ? 'Enable firewall' : 'Install and enable',
      details: [
        `Allows SSH on ${ssh}.`,
        `Allows this panel on ${state.panel_port}/tcp.`,
        'Sets the defaults to deny incoming, allow outgoing.',
        ...(state.installed ? [] : ['Installs the ufw package with apt first.']),
        'Any other port stays closed unless a rule below allows it.',
      ],
    },
  );
}

function disable(): void {
  ui.confirmThen(
    'Disable the firewall?',
    'UFW stops filtering traffic. Your rules are kept and come back when you enable it again.',
    () => void run('/api/v1/firewall/disable', {}, { title: 'Disabling UFW firewall' }),
    {
      danger: true,
      confirmLabel: 'Disable firewall',
      typeToConfirm: 'disable',
      details: [
        'Every port with a listening service becomes reachable from any network.',
        'Databases, admin tools and internal services may be exposed.',
      ],
    },
  );
}

function deleteRule(rule: RuleRow): void {
  const spec = `${rule.action} ${rule.to} from ${rule.from_}`;
  const go = async () => {
    const result = await run(
      '/api/v1/firewall/delete-port',
      // The spec lets the backend refuse (409) if UFW renumbered the rules
      // since this list was loaded, instead of deleting the wrong one.
      { rule_num: rule.num, to: rule.to, action: rule.action, from: rule.from_ },
      { title: `Deleting firewall rule #${rule.num}` },
    );
    if (!result) {
      // Most likely a 409: the list was stale. Show the current rules.
      await firewallStore.load({ silent: true });
      ui.addToast({ t: 'Rule list reloaded', d: 'Check the rule again before deleting it.', k: 'info' });
    }
  };

  const protection = rule.protection;
  if (!protection) {
    ui.confirmThen(`Delete rule #${rule.num}?`, `Remove ${spec}.`, () => void go(), {
      danger: true,
      confirmLabel: 'Delete rule',
    });
    return;
  }
  ui.confirmThen(
    `Delete a rule for ${protection.what}?`,
    `Remove ${spec}. ${protection.reason}`,
    () => void go(),
    {
      danger: true,
      confirmLabel: 'Delete rule',
      typeToConfirm: String(protection.port),
      details: [
        `You may lose access to ${protection.what}.`,
        `Your address: ${firewall.value.client_ip || 'unknown'}.`,
        firewall.value.enabled
          ? 'The change applies immediately.'
          : 'UFW is off now, but the change applies as soon as it is enabled.',
      ],
    },
  );
}
</script>

<template>
  <section>
    <PageHeader title="Firewall" :subtitle="subtitle">
      <Btn :loading="refreshing" @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
      <Btn variant="primary" :disabled="!firewall.installed" @click="adding = true">
        <LIcon name="plus" /> Add rule
      </Btn>
    </PageHeader>

    <ErrorState v-if="error && !loaded" :message="error" @retry="firewallStore.load()" />

    <template v-else>
      <Card class="mb-4 overflow-clip">
        <CardHeader title="Status" icon="shield">
          <template v-if="loaded">
            <Btn v-if="firewall.installed && firewall.enabled" variant="danger" sm @click="disable">
              <LIcon name="shield-off" /> Disable
            </Btn>
            <Btn v-else variant="primary" sm @click="enable">
              <LIcon name="shield-check" /> {{ firewall.installed ? 'Enable' : 'Install and enable' }}
            </Btn>
          </template>
        </CardHeader>
        <div class="p-4 grid grid-cols-1 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] gap-4">
          <div class="flex flex-col gap-2.5 min-w-0">
            <div v-if="!loaded" class="skeleton h-5 w-40"></div>
            <div v-else class="flex flex-wrap items-center gap-2">
              <Badge v-if="!firewall.installed" tone="danger" dot>Not installed</Badge>
              <Badge v-else-if="firewall.enabled" tone="ok" dot>Active</Badge>
              <Badge v-else tone="danger" dot>Inactive</Badge>
              <span class="text-sm-var text-c-tx2">
                {{
                  !firewall.installed
                    ? 'No packet filter is running.'
                    : firewall.enabled
                      ? 'Rules below are enforced.'
                      : 'Rules below are saved but not enforced.'
                }}
              </span>
            </div>
            <p class="m-0 text-xs-var text-c-tx2">
              Kept open for you: <span class="mono">{{ accessSummary }}</span>
              <template v-if="firewall.client_ip">
                · you connect from <span class="mono">{{ firewall.client_ip }}</span></template
              >
            </p>
          </div>
          <dl class="m-0 grid grid-cols-3 gap-2">
            <div
              v-for="policy in policies()"
              :key="policy.key"
              class="rounded-theme border border-c-border bg-c-elev px-3 py-2 min-w-0"
            >
              <dt class="text-xs-var text-c-tx2">{{ policy.label }}</dt>
              <dd class="m-0 mt-1">
                <Badge v-if="policy.value" :tone="POLICY_TONE[policy.value] ?? 'neutral'">{{ policy.value }}</Badge>
                <span v-else class="text-c-tx3 text-sm-var">—</span>
              </dd>
            </div>
          </dl>
        </div>
      </Card>

      <Alert
        v-if="loaded && firewall.installed && !firewall.enabled && firewall.rules.length"
        tone="warn"
        title="Rules are not enforced"
        class="mb-4"
      >
        UFW is off, so every port is reachable. Enable it to apply the rules below.
      </Alert>

      <Card class="overflow-clip">
        <CardHeader title="Rules" icon="list" :subtitle="loaded ? `${firewall.rules.length} total, IPv4 and IPv6` : ''" />
        <DataTable
          :columns="columns"
          :rows="rows"
          :row-key="(row) => `${row.num}-${row.to}-${row.from_}`"
          label="Firewall rules"
          :loading="loading"
          :error="error"
          sort-key="num"
          empty-icon="shield"
          :empty-title="firewall.installed ? 'No rules yet' : 'UFW is not installed'"
          :empty-hint="
            firewall.installed
              ? 'Use Add rule to open a port.'
              : 'Install and enable it from the Status card above.'
          "
          @retry="firewallStore.load()"
        >
          <template #cell-to="{ row }">
            <span class="inline-flex items-center gap-1.5">
              <span v-if="row.protection" class="inline-flex shrink-0 text-c-warn" :title="row.protection.reason">
                <LIcon name="lock" is="width:13px;height:13px" />
                <span class="sr-only">Protected: {{ row.protection.reason }}</span>
              </span>
              <span class="mono font-medium">{{ row.to.replace(' (v6)', '') }}</span>
            </span>
          </template>
          <template #cell-action="{ row }">
            <span class="inline-flex items-center gap-1.5">
              <Badge :tone="ACTION_TONE[row.action] ?? 'neutral'">{{ row.action }}</Badge>
              <span v-if="row.direction && row.direction !== 'IN'" class="text-xs-var text-c-tx2">{{
                row.direction
              }}</span>
            </span>
          </template>
          <template #cell-from_="{ row }">
            <span class="mono text-c-tx2">{{ row.from_.replace(' (v6)', '') }}</span>
          </template>
          <template #cell-is_v6="{ row }">
            <Badge :tone="row.is_v6 ? 'muted' : 'neutral'">{{ row.is_v6 ? 'v6' : 'v4' }}</Badge>
          </template>
          <template #cell-label="{ row }">
            <span class="text-c-tx2">{{ row.label || '—' }}</span>
          </template>
          <template #cell-actions="{ row }">
            <Btn
              variant="danger"
              sm
              square
              :aria-label="`Delete rule ${row.num}: ${row.action} ${row.to} from ${row.from_}`"
              :title="row.protection ? `Protected — ${row.protection.reason}` : 'Delete rule'"
              @click="deleteRule(row)"
            >
              <LIcon name="trash-2" />
            </Btn>
          </template>
        </DataTable>
      </Card>
    </template>

    <FirewallRuleDialog v-if="adding" :state="firewall" @close="adding = false" />
  </section>
</template>
