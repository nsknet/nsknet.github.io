<script setup lang="ts">
/** UFW rules: list, add and delete. */
import { storeToRefs } from 'pinia';
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue';

import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import LIcon from '@/components/ui/LIcon.vue';
import Spinner from '@/components/ui/Spinner.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useFirewallStore } from '@/stores/misc';
import { useUiStore } from '@/stores/ui';

const ui = useUiStore();
const { run, reload } = useJobRunner();
const { firewall, loading } = storeToRefs(useFirewallStore());

const ACTION_CLS: Record<string, string> = {
  allow: 'bg-c-oksoft text-c-ok',
  deny: 'bg-c-dngsoft text-c-danger',
  limit: 'bg-c-warnsoft text-c-warn',
  reject: 'bg-c-dngsoft text-c-danger',
};

const SOURCES = [
  { label: 'Anywhere', value: 'Anywhere' },
  { label: 'Class A · 10.0.0.0/8', value: '10.0.0.0/8' },
  { label: 'Class B · 172.16.0.0/12', value: '172.16.0.0/12' },
  { label: 'Class C · 192.168.0.0/16', value: '192.168.0.0/16' },
  { label: 'Custom…', value: '__custom' },
];

const showAdd = ref(false);
const form = reactive({ port: '', desc: '', action: 'ALLOW', source: 'Anywhere', custom: '' });

const ruleCount = computed(() => {
  const rules = firewall.value.rules;
  const v6 = rules.filter((rule) => rule.v6).length;
  return `${rules.length} rules · ${rules.length - v6} v4 · ${v6} v6`;
});

async function refresh(): Promise<void> {
  await reload();
  ui.addToast({ t: 'Rules refreshed', k: 'info' });
}

function openAdd(): void {
  Object.assign(form, { port: '', desc: '', action: 'ALLOW', source: 'Anywhere', custom: '' });
  showAdd.value = true;
}

function submitAdd(event: Event): void {
  event.preventDefault();
  const port = form.port.trim();
  if (!port) {
    ui.addToast({ t: 'Enter a port or service', k: 'warn' });
    return;
  }

  const source = form.source === '__custom' ? form.custom.trim() : form.source;
  if (form.source === '__custom' && !source) {
    ui.addToast({ t: 'Enter a custom source IP/CIDR', k: 'warn' });
    return;
  }

  showAdd.value = false;
  void run(
    '/api/v1/firewall/add-port',
    { port, action: form.action, source, comment: form.desc.trim() },
    { title: `Adding rule: ${form.action} ${port} from ${source}` },
  );
}

function deleteRule(index: number): void {
  const rule = firewall.value.rules.find((candidate) => candidate.idx === index);
  if (!rule) return;
  ui.confirmThen(
    'Delete rule?',
    `This removes rule #${index} (${rule.action} ${rule.port} from ${rule.from}). It cannot be undone from the UI.`,
    () => {
      void run(
        '/api/v1/firewall/delete-port',
        { rule_num: index },
        { title: `Deleting firewall rule #${index}` },
      );
    },
  );
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key === 'Escape') showAdd.value = false;
}

onMounted(() => document.addEventListener('keydown', onKeydown));
onUnmounted(() => document.removeEventListener('keydown', onKeydown));
</script>

<template>
  <section>
    <div class="flex items-end justify-between gap-6 mb-6">
      <div>
        <div class="flex items-center gap-3 mb-1">
          <h1 class="text-[22px] font-semibold tracking-[-0.02em]">Firewall</h1>
          <Badge :tone="firewall.active ? 'ok' : 'danger'" :dot="firewall.active">
            {{ firewall.active ? 'UFW active' : 'UFW inactive' }}
          </Badge>
        </div>
        <div class="text-sm-var text-c-tx2">
          Default: deny incoming, allow outgoing. SSH (22) auto-allowed.
        </div>
      </div>
      <div class="flex gap-2">
        <Btn @click="refresh"><LIcon name="refresh-cw" /> Refresh rules</Btn>
        <Btn variant="primary" @click="openAdd"><LIcon name="plus" /> Add rule</Btn>
      </div>
    </div>

    <div
      class="flex items-center gap-2.5 px-3.5 py-2.5 rounded-theme bg-c-infosoft text-c-info text-sm-var mb-4 border border-transparent"
    >
      <LIcon name="info" is="width:16px;height:16px;flex-shrink:0" />
      <div>
        <strong>{{ firewall.rules.length }} rules</strong> active — including IPv6 duplicates.
        Deletions are confirmed and streamed.
      </div>
    </div>

    <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
      <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
        <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Allowed ports</h3>
        <span class="text-xs-var text-c-tx3 mono">{{ ruleCount }}</span>
      </div>
      <table class="tbl">
        <thead>
          <tr>
            <th style="width: 56px">#</th>
            <th>Port / service</th>
            <th>Action</th>
            <th>Source</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="loading && !firewall.rules.length">
            <td colspan="5" class="muted" style="text-align: center; padding: 32px 0">
              <Spinner label="Loading rules…" />
            </td>
          </tr>
          <tr v-else-if="!firewall.rules.length">
            <td colspan="5" class="muted" style="text-align: center; padding: 32px 0">
              No rules found — UFW may be inactive. Use <strong>Add rule</strong> to allow a port.
            </td>
          </tr>
          <tr v-for="rule in firewall.rules" :key="`${rule.idx}-${rule.v6}`">
            <td class="num muted">{{ rule.idx }}</td>
            <td>
              <span class="mono"
                ><strong>{{ rule.port }}</strong></span
              >
              <span
                v-if="rule.v6"
                class="mono text-[10px] font-medium tracking-[0.05em] px-[5px] py-px rounded-[4px] bg-c-subtle text-c-tx3 ml-1.5 border border-c-border"
                >v6</span
              >
              <div v-if="rule.label" class="text-xs-var text-c-tx3 mt-0.5">{{ rule.label }}</div>
            </td>
            <td>
              <span
                class="inline-flex items-center gap-1 h-[22px] px-2 mono text-xs-var font-semibold tracking-[0.04em] rounded-[5px]"
                :class="ACTION_CLS[rule.action.toLowerCase()]"
                >{{ rule.action }}</span
              >
            </td>
            <td class="mono muted">{{ rule.from }}</td>
            <td>
              <Btn variant="danger" sm square title="Delete rule" @click="deleteRule(rule.idx)">
                <LIcon name="trash-2" />
              </Btn>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <div
      v-if="showAdd"
      class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade"
      @click.self="showAdd = false"
    >
      <div
        class="w-full max-w-[460px] bg-c-bg border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop"
        role="dialog"
        aria-modal="true"
      >
        <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
          <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center">
            <LIcon name="shield-plus" is="width:14px;height:14px" />
          </div>
          <div>
            <div class="font-semibold text-sm-var">Add firewall rule</div>
            <div class="text-xs-var text-c-tx2">Applied to both IPv4 and IPv6.</div>
          </div>
          <Btn variant="ghost" sm square class="ml-auto" aria-label="Close" @click="showAdd = false">
            <LIcon name="x" />
          </Btn>
        </div>

        <form class="p-4 flex flex-col gap-3.5" @submit="submitAdd">
          <div class="flex flex-col gap-1.5">
            <label for="fw-port" class="text-sm-var font-medium text-c-tx">Port / protocol</label>
            <input
              id="fw-port"
              v-model="form.port"
              class="input mono"
              placeholder="80, 443/tcp, 8000:8100/tcp"
            />
            <div class="text-xs-var text-c-tx2">
              Single port, <span class="mono">443/tcp</span>, or range
              <span class="mono">8000:8100/tcp</span>.
            </div>
          </div>

          <div class="flex flex-col gap-1.5">
            <label for="fw-desc" class="text-sm-var font-medium text-c-tx">
              Description <span class="text-c-tx3 font-normal">· optional</span>
            </label>
            <input id="fw-desc" v-model="form.desc" class="input" placeholder="e.g. HTTPS" />
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="text-sm-var font-medium text-c-tx">Action</label>
            <div class="inline-flex w-fit gap-0.5 p-0.5 rounded-theme-sm bg-c-subtle">
              <button
                v-for="action in ['ALLOW', 'DENY', 'LIMIT']"
                :key="action"
                type="button"
                :class="[
                  'px-3 h-7 rounded-[5px] mono text-xs-var font-semibold tracking-[0.04em] transition-colors',
                  form.action === action
                    ? `bg-c-bg shadow-sm ${ACTION_CLS[action.toLowerCase()]}`
                    : 'text-c-tx2 hover:text-c-tx',
                ]"
                @click="form.action = action"
              >
                {{ action }}
              </button>
            </div>
          </div>

          <div class="flex flex-col gap-1.5">
            <label for="fw-src" class="text-sm-var font-medium text-c-tx">Source</label>
            <select id="fw-src" v-model="form.source" class="input">
              <option v-for="source in SOURCES" :key="source.value" :value="source.value">
                {{ source.label }}
              </option>
            </select>
            <input
              v-if="form.source === '__custom'"
              v-model="form.custom"
              class="input mono"
              placeholder="e.g. 203.0.113.0/24"
            />
          </div>

          <div class="flex justify-end gap-2 mt-1">
            <Btn type="button" @click="showAdd = false">Cancel</Btn>
            <Btn type="submit" variant="primary"><LIcon name="plus" /> Add rule</Btn>
          </div>
        </form>
      </div>
    </div>
  </section>
</template>
