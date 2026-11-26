<script setup lang="ts">
/** Run NsPanel itself as a systemd service: install, reconfigure, version,
 *  updates, rollback, restart and uninstall. Actions that restart the panel
 *  this page is served by hand over to usePanelRestart, which follows it. */
import { storeToRefs } from 'pinia';
import { computed, ref } from 'vue';
import { RouterLink } from 'vue-router';

import type { PanelTarget } from '@/api/settings';
import PanelInstallForm from '@/components/settings/PanelInstallForm.vue';
import PanelStatusCard from '@/components/settings/PanelStatusCard.vue';
import PanelVersionCard from '@/components/settings/PanelVersionCard.vue';
import Alert from '@/components/ui/Alert.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import ErrorState from '@/components/ui/ErrorState.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import Skeleton from '@/components/ui/Skeleton.vue';
import { endpoints } from '@/api/client';
import { useJobRunner } from '@/composables/useJobs';
import { usePanelRestart } from '@/composables/usePanelRestart';
import { useRefresh } from '@/composables/useRefresh';
import { useJobsStore } from '@/stores/jobs';
import { usePanelStore } from '@/stores/panel';
import { useUiStore } from '@/stores/ui';

const API = endpoints.panel;

const ui = useUiStore();
const { run } = useJobRunner();
const { refresh, refreshing } = useRefresh();
const panelStore = usePanelStore();
const { status, loaded, loading, error } = storeToRefs(panelStore);
const { running } = storeToRefs(useJobsStore());

const { restarting, movingTo, showMoveLink, waitForRestart, afterReconfigure } = usePanelRestart(
  () => void panelStore.load(),
);

const reconfiguring = ref(false);
const showForm = computed(() => loaded.value && (!status.value.installed || reconfiguring.value));

/** The server refuses restart, update and rollback while jobs run (409). */
const busyJobs = computed(() => running.value.length);
const blocked = computed(() => restarting.value || busyJobs.value > 0);

/** Restarts this page's own server: follow it afterwards. */
function followIfSelf(): void {
  if (status.value.is_self) void waitForRestart(status.value.running_commit?.hash);
}

function onSaved(target: PanelTarget): void {
  reconfiguring.value = false;
  const s = status.value;
  if (s.installed && s.is_self) afterReconfigure(target, s.running_commit?.hash, s.current_port);
}

function restart(): void {
  ui.confirmThen(
    'Restart the NsPanel service?',
    status.value.is_self
      ? 'The panel you are on stops for a few seconds; this page reloads when it is back.'
      : 'The service stops for a few seconds and starts again.',
    () => void run(`${API}/restart`, {}, { onSuccess: followIfSelf }),
    { confirmLabel: 'Restart' },
  );
}

function rollback(): void {
  const s = status.value;
  const subject = s.previous_commit?.subject ? ` (${s.previous_commit.subject})` : '';
  ui.confirmThen(
    'Roll back to the previous release?',
    `Switches the service back to ${s.previous_commit?.short ?? 'the previous release'}${subject} and restarts it.`,
    () => void run(`${API}/rollback`, {}, { onSuccess: followIfSelf }),
    { danger: true, confirmLabel: 'Roll back' },
  );
}

function update(force: boolean): void {
  const s = status.value;
  const u = s.update;
  const ci = u?.ci?.state;
  const body =
    `Installs ${u?.behind ?? 0} commit(s) from ${s.branch} into a new release directory, checks it, ` +
    'then restarts onto it. If the new version does not answer within a minute, the previous release ' +
    'is put back automatically.';
  ui.confirmThen(
    force ? 'Update although CI is not green?' : 'Update and restart NsPanel?',
    force ? `CI ${ci === 'failure' ? 'failed' : 'is still running'} on the new commit. ${body}` : body,
    () => void run(`${API}/update`, force ? { force: true } : {}, { onSuccess: followIfSelf }),
    force
      ? {
          danger: true,
          confirmLabel: 'Update anyway',
          details: [
            `Target commit: ${u?.remote_commit?.short ?? 'branch tip'}.`,
            ci === 'failure'
              ? 'Its CI run failed — the release may be broken.'
              : 'Its CI run has not finished.',
          ],
        }
      : { confirmLabel: 'Update & restart' },
  );
}

function uninstall(): void {
  const s = status.value;
  ui.confirmThen(
    'Uninstall the NsPanel service?',
    'Stops and removes the service. The admin password and the panel you are on are not affected.',
    () => void run(`${API}/uninstall`, {}, { title: 'Uninstalling the NsPanel service' }),
    {
      danger: true,
      confirmLabel: 'Uninstall',
      typeToConfirm: 'nspanel',
      details: [
        `The service on port ${s.port} stops and is removed from systemd.`,
        'Its UFW rules are deleted.',
        'Its settings in /etc/nspanel are removed.',
        `${s.repo_dir || 'Its directory'} is deleted, with every release in it.`,
      ],
    },
  );
}

function startReconfigure(): void {
  reconfiguring.value = true;
}
</script>

<template>
  <section>
    <PageHeader
      title="Panel service"
      subtitle="Run NsPanel as a systemd service on the LAN, and keep it up to date from GitHub."
    >
      <Btn v-if="status.installed && !showForm" :disabled="blocked" @click="startReconfigure">
        <LIcon name="pencil" /> Reconfigure
      </Btn>
      <Btn :loading="refreshing" :disabled="restarting" @click="refresh">
        <LIcon name="refresh-cw" /> Refresh
      </Btn>
    </PageHeader>

    <div class="flex flex-col gap-3 mb-4 empty:hidden">
      <Alert v-if="restarting && !movingTo" tone="info" icon="rotate-cw" title="Restarting the panel">
        This page reloads when it is back.
      </Alert>
      <Alert v-if="movingTo" tone="info" icon="arrow-right-left" title="The panel is moving">
        Waiting for <span class="mono break-all">{{ movingTo }}</span> to answer, then opening it.
        <template v-if="showMoveLink">
          It has not answered yet — the browser may not trust its certificate, or it blocks an http address
          from an https page. Open it yourself.
        </template>
        <template v-if="showMoveLink" #action>
          <a
            :href="movingTo"
            class="inline-flex items-center gap-1.5 h-8 px-2.5 rounded-lg bg-c-accent text-c-acfg text-xs-var font-medium no-underline"
          >
            <LIcon is="width:14px;height:14px" name="external-link" /> Open the new address
          </a>
        </template>
      </Alert>
      <Alert v-if="!restarting && busyJobs && status.installed" tone="warn">
        {{ busyJobs }} job{{ busyJobs > 1 ? 's are' : ' is' }} still running. Restart, update and roll back
        wait until {{ busyJobs > 1 ? 'they finish' : 'it finishes' }} — a restart would stop
        {{ busyJobs > 1 ? 'them' : 'it' }}.
        <template #action>
          <RouterLink to="/activity/jobs" class="text-xs-var underline underline-offset-2"
            >Show jobs</RouterLink
          >
        </template>
      </Alert>
    </div>

    <Card v-if="!loaded && error && !loading">
      <ErrorState :message="error" title="Could not load the panel service" @retry="panelStore.load()" />
    </Card>

    <Card v-else-if="!loaded" class="p-4"><Skeleton :count="5" /></Card>

    <PanelInstallForm
      v-else-if="showForm"
      :key="String(status.installed)"
      :status="status"
      :disabled="restarting"
      @cancel="reconfiguring = false"
      @saved="onSaved"
    />

    <div v-else class="grid grid-cols-1 lg:grid-cols-2 gap-3 items-start">
      <PanelStatusCard :status="status" :disabled="blocked" @restart="restart" @uninstall="uninstall" />
      <PanelVersionCard
        :status="status"
        :disabled="blocked"
        @restart="restart"
        @rollback="rollback"
        @update="update"
      />
    </div>
  </section>
</template>
