<script setup lang="ts">
/** What the service runs, what it could roll back to, and the update check
 *  (commits waiting on the branch, their CI state, Update / Update anyway). */
import { computed, onMounted, ref } from 'vue';

import type { PanelServiceStatus } from '@/api/types';
import Alert from '@/components/ui/Alert.vue';
import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import CardHeader from '@/components/ui/CardHeader.vue';
import KeyValueList from '@/components/ui/KeyValueList.vue';
import LIcon from '@/components/ui/LIcon.vue';
import type { KeyValueItem } from '@/components/ui/types';
import { usePanelStore } from '@/stores/panel';
import { useUiStore } from '@/stores/ui';
import { ago, fmtDate } from '@/utils/format';

const props = defineProps<{ status: PanelServiceStatus; disabled?: boolean }>();
const emit = defineEmits<{ restart: []; rollback: []; update: [force: boolean] }>();

const ui = useUiStore();
const panelStore = usePanelStore();

/** An update check older than this is redone when the card opens. */
const RECHECK_MS = 15 * 60 * 1000;

const update = computed(() => props.status.update);
const hasUpdate = computed(() => !!update.value && !update.value.stale && update.value.behind > 0);
const otherCommits = computed(() => {
  const u = update.value;
  return u ? Math.max(0, u.total_behind - u.behind) : 0;
});

/** Pulled but not restarted: the process runs older code than the service has on disk. */
const restartPending = computed(() => {
  const s = props.status;
  return s.is_self && !!s.running_commit && !!s.installed_commit && s.running_commit.hash !== s.installed_commit.hash;
});

const CI_LABELS: Record<string, string> = {
  success: 'CI passed',
  failure: 'CI failed',
  pending: 'CI running',
  none: 'No CI runs',
  unknown: 'CI status unknown',
};
const ciState = computed(() => update.value?.ci?.state ?? null);
/** The server refuses a plain update while CI is red or running. */
const ciBlocks = computed(() => ciState.value === 'failure' || ciState.value === 'pending');
const ciTone = computed(() => (ciState.value === 'success' ? 'ok' : ciBlocks.value ? 'warn' : 'muted'));
const ciIcon = computed(() => (ciState.value === 'success' ? 'circle-check' : ciBlocks.value ? 'triangle-alert' : 'info'));

const items = computed<KeyValueItem[]>(() => {
  const s = props.status;
  const rows: KeyValueItem[] = [
    { key: 'installed', label: 'Installed' },
    { key: 'date', label: 'Commit date', value: fmtDate(s.installed_commit?.date) },
    { key: 'updated', label: 'Last updated', value: fmtDate(s.updated_at) },
  ];
  if (s.previous_commit) rows.push({ key: 'previous', label: 'Previous' });
  return rows;
});

const checking = ref(false);

async function checkNow(quiet = false): Promise<void> {
  if (checking.value) return;
  checking.value = true;
  try {
    await panelStore.checkUpdates();
    if (!quiet) {
      const u = props.status.update;
      ui.addToast(
        u?.error
          ? { t: 'Update check failed', d: u.error, k: 'danger' }
          : u?.behind
            ? { t: `${u.behind} new commit${u.behind > 1 ? 's' : ''}`, k: 'info' }
            : { t: 'Up to date', k: 'ok' },
      );
    }
  } catch (error) {
    if (!quiet) {
      ui.addToast({
        t: 'Update check failed',
        d: error instanceof Error ? error.message : String(error),
        k: 'danger',
      });
    }
  } finally {
    checking.value = false;
  }
}

// Recheck when the card opens if the last check is missing, stale or old.
onMounted(() => {
  const u = props.status.update;
  const age = u ? Date.now() - Date.parse(u.checked_at) : Infinity;
  if (!u || u.stale || !(age < RECHECK_MS)) void checkNow(true);
});
</script>

<template>
  <Card class="overflow-clip flex flex-col">
    <CardHeader title="Version" icon="git-merge">
      <span class="mono text-xs-var text-c-tx3">{{ status.branch }}</span>
    </CardHeader>
    <div class="p-4 flex flex-col gap-3">
      <KeyValueList :items="items" label-width="110px">
        <template #value-installed>
          <span v-if="status.installed_commit" class="min-w-0">
            <span class="mono text-xs-var select-all" :title="status.installed_commit.hash">{{
              status.installed_commit.short
            }}</span>
            <span class="text-c-tx2"> · {{ status.installed_commit.subject }}</span>
          </span>
          <span v-else class="text-c-tx3">unknown</span>
        </template>
        <template #value-previous>
          <span class="flex flex-wrap items-center gap-x-2 gap-y-1 min-w-0">
            <span class="mono text-xs-var" :title="status.previous_commit?.hash">{{ status.previous_commit?.short }}</span>
            <span class="text-c-tx2 text-xs-var min-w-0 break-words">{{ status.previous_commit?.subject }}</span>
            <Btn v-if="status.can_rollback" sm :disabled="disabled" @click="emit('rollback')">
              <LIcon name="rotate-ccw" /> Roll back
            </Btn>
          </span>
        </template>
      </KeyValueList>

      <Alert v-if="status.last_rollback" tone="danger" title="Rolled back automatically">
        {{ ago(status.last_rollback.at) }} ({{ fmtDate(status.last_rollback.at) }}): release
        <span class="mono">{{ status.last_rollback.from.slice(0, 7) }}</span> did not come up —
        {{ status.last_rollback.reason }}.
      </Alert>

      <Alert v-if="restartPending" tone="warn" title="Restart pending">
        Running <span class="mono">{{ status.running_commit?.short }}</span>, but
        <span class="mono">{{ status.installed_commit?.short }}</span> is on disk.
        <template #action>
          <Btn sm variant="warn" :disabled="disabled" @click="emit('restart')">Restart</Btn>
        </template>
      </Alert>
    </div>

    <section class="px-4 pb-4 pt-3 border-t border-c-border flex flex-col gap-2.5" aria-labelledby="panel-updates-title">
      <div class="flex flex-wrap items-center gap-2">
        <h3 id="panel-updates-title" class="m-0 text-xs-var font-semibold uppercase tracking-[0.06em] text-c-tx2">
          Updates
        </h3>
        <span role="status" class="inline-flex">
          <Badge v-if="checking" tone="muted">checking…</Badge>
          <Badge v-else-if="update?.error" tone="danger">check failed</Badge>
          <Badge v-else-if="hasUpdate" tone="info">
            {{ update?.behind }} new commit{{ (update?.behind ?? 0) > 1 ? 's' : '' }}
          </Badge>
          <Badge v-else-if="update && !update.stale" tone="ok">up to date</Badge>
        </span>
        <span class="ml-auto text-xs-var text-c-tx3">checked {{ ago(update?.checked_at) }}</span>
        <Btn sm variant="ghost" :loading="checking" @click="checkNow()">
          <LIcon name="refresh-cw" /> Check now
        </Btn>
      </div>

      <p v-if="update?.error" class="m-0 text-xs-var text-c-danger mono break-all">{{ update.error }}</p>
      <ul v-else-if="hasUpdate" class="m-0 p-0 list-none flex flex-col gap-1">
        <li v-for="commit in update?.commits" :key="commit.hash" class="flex items-baseline gap-2 text-xs-var min-w-0">
          <span class="mono text-c-tx3 shrink-0">{{ commit.short }}</span>
          <span class="flex-1 min-w-0 truncate" :title="commit.subject">{{ commit.subject }}</span>
          <span class="hidden sm:inline text-c-tx3 tabular-nums shrink-0">{{ fmtDate(commit.date) }}</span>
        </li>
      </ul>
      <p v-else-if="update && !update.stale" class="m-0 text-xs-var text-c-tx2">
        Latest on {{ status.branch }}: <span class="mono">{{ update.remote_commit?.short ?? '—' }}</span>
        <template v-if="otherCommits">
          · {{ otherCommits }} newer commit{{ otherCommits > 1 ? 's' : '' }} outside the panel, no update needed
        </template>
      </p>

      <div v-if="hasUpdate" class="flex flex-wrap items-center gap-2 pt-1">
        <Badge v-if="ciState" :tone="ciTone">
          <LIcon :name="ciIcon" is="width:12px;height:12px" />
          <a
            v-if="update?.ci?.url"
            :href="update.ci.url"
            target="_blank"
            rel="noopener"
            class="underline underline-offset-2"
            >{{ CI_LABELS[ciState] }}<span class="sr-only"> (opens GitHub)</span></a
          >
          <span v-else>{{ CI_LABELS[ciState] }}</span>
        </Badge>
        <Btn
          class="ml-auto"
          sm
          :variant="ciBlocks ? 'danger' : 'primary'"
          :disabled="disabled"
          @click="emit('update', ciBlocks)"
        >
          <LIcon name="download" />
          {{ ciBlocks ? 'Update anyway' : 'Update & restart' }}
        </Btn>
      </div>
    </section>
  </Card>
</template>
