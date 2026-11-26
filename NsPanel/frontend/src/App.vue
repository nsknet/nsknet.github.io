<script setup lang="ts">
/** The shell: navigation (rail on desktop, drawer on mobile), the header
 *  (breadcrumbs, search, running jobs, connection state), the routed screen,
 *  and the app-wide dialogs. Shows the login screen while signed out. */
import { storeToRefs } from 'pinia';
import { computed, onMounted, onUnmounted, ref, watch } from 'vue';
import { RouterLink, useRoute, useRouter } from 'vue-router';

import ChangePasswordDialog from '@/components/ChangePasswordDialog.vue';
import CommandPalette from '@/components/CommandPalette.vue';
import ConfirmDialog from '@/components/ConfirmDialog.vue';
import InstallDialog from '@/components/InstallDialog.vue';
import NavRail from '@/components/NavRail.vue';
import NetworkDialog from '@/components/NetworkDialog.vue';
import OverlayModal from '@/components/OverlayModal.vue';
import ToastList from '@/components/ToastList.vue';
import Btn from '@/components/ui/Btn.vue';
import LIcon from '@/components/ui/LIcon.vue';
import { dialogOpen } from '@/composables/useDialog';
import { useHealth } from '@/composables/useHealth';
import { loadRouteData } from '@/composables/useScreenData';
import { useAuthStore } from '@/stores/auth';
import { useJobsStore } from '@/stores/jobs';
import { useSystemStore } from '@/stores/system';
import { useUiStore } from '@/stores/ui';
import LoginView from '@/views/LoginView.vue';

const route = useRoute();
const router = useRouter();
const ui = useUiStore();
const system = useSystemStore();
const jobsStore = useJobsStore();
const auth = useAuthStore();
const { running: runningJobs } = storeToRefs(jobsStore);
const { sidebarOpen, overlay, confirm, installDialog, networkDialog, paletteOpen, mobileNavOpen } =
  storeToRefs(ui);
const { host, hostLoaded } = storeToRefs(system);
const health = useHealth();

const passwordDialog = ref(false);

const crumbs = computed(() => route.meta.crumbs?.(route) ?? [{ label: String(route.name ?? '') }]);
const isMac = /Mac|iPhone|iPad/.test(navigator.platform);
const signedIn = computed(() => auth.status === 'signed-in');

function onGlobalKeydown(event: KeyboardEvent): void {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault();
    if (!signedIn.value || !hostLoaded.value) return;
    // The palette is itself a dialog: the shortcut closes it, and opens it
    // only when no other dialog is up.
    if (paletteOpen.value) paletteOpen.value = false;
    else if (!dialogOpen()) paletteOpen.value = true;
  }
}

/** Everything the shell needs once a session exists (first load, or right after login). */
function startSession(): void {
  // The header shows the hostname on every screen, not only the ones that load it.
  void system.load();
  // After a reload: show running jobs in the header, and give a job dialog
  // restored from sessionStorage the usual refresh-when-done behaviour.
  void jobsStore.load();
  void loadRouteData(router.currentRoute.value.meta.loads);
  if (overlay.value && !overlay.value.onDone) {
    overlay.value.onDone = () => void loadRouteData(router.currentRoute.value.meta.loads);
  }
}

// A job that finished while its dialog was closed still changes what the
// current screen shows: reload it.
jobsStore.onJobFinished((job) => {
  void loadRouteData(router.currentRoute.value.meta.loads);
  if (job.status === 'failed' && !overlay.value) {
    ui.addToast({ t: 'Job failed', d: job.label, k: 'danger' });
  }
});

watch(
  () => auth.status,
  (status, previous) => {
    if (status === 'signed-in' && previous !== 'signed-in') startSession();
    if (status === 'anonymous') {
      paletteOpen.value = false;
      passwordDialog.value = false;
      mobileNavOpen.value = false;
    }
  },
);

// The drawer closes when the route changes (a link inside it was used).
watch(
  () => route.fullPath,
  () => (mobileNavOpen.value = false),
);

onMounted(() => {
  ui.applyTheme();
  void auth.check();
  document.addEventListener('keydown', onGlobalKeydown);
});
onUnmounted(() => document.removeEventListener('keydown', onGlobalKeydown));

function reloadPage(): void {
  window.location.reload();
}
</script>

<template>
  <div
    v-if="signedIn && hostLoaded"
    class="h-[100dvh] overflow-hidden bg-c-canvas md:grid sidebar-grid"
    :style="{ '--rail-w': sidebarOpen ? '232px' : '60px' }"
  >
    <a
      href="#main"
      class="sr-only focus:not-sr-only focus:fixed focus:top-2 focus:left-2 focus:z-[400] focus:px-3 focus:py-2 focus:bg-c-card focus:rounded-theme focus:shadow-md"
      >Skip to content</a
    >

    <!-- Desktop rail -->
    <aside class="hidden md:block border-r border-c-border bg-c-elev min-h-0">
      <NavRail :wide="sidebarOpen" />
    </aside>

    <!-- Mobile drawer -->
    <div v-if="mobileNavOpen" class="md:hidden fixed inset-0 z-[150]">
      <!-- Backdrop is pointer-only by design; Esc and the drawer links close it from the keyboard. -->
      <!-- eslint-disable-next-line vuejs-accessibility/click-events-have-key-events, vuejs-accessibility/no-static-element-interactions -->
      <div class="absolute inset-0 bg-c-overlay animate-fade" @click="mobileNavOpen = false"></div>
      <aside
        class="absolute inset-y-0 left-0 w-[260px] max-w-[85vw] bg-c-elev border-r border-c-border shadow-lg animate-slidein"
      >
        <NavRail wide :show-collapse="false" @navigate="mobileNavOpen = false" />
      </aside>
    </div>

    <div class="flex flex-col min-w-0 h-[100dvh] overflow-hidden">
      <header
        class="h-14 md:h-12 border-b border-c-border flex items-center px-[var(--pad-x)] gap-2 md:gap-3 shrink-0 bg-c-bg/85 backdrop-blur-md relative z-10"
      >
        <button
          type="button"
          class="md:hidden -ml-1.5 w-9 h-9 grid place-items-center rounded-lg text-c-tx2 hover:bg-c-hover"
          aria-label="Open navigation"
          :aria-expanded="mobileNavOpen"
          @click="mobileNavOpen = true"
        >
          <LIcon is="width:18px;height:18px" name="menu" />
        </button>

        <nav class="min-w-0 flex items-center gap-1.5 text-sm-var text-c-tx2" aria-label="Breadcrumb">
          <ol class="m-0 p-0 list-none flex items-center gap-1.5 min-w-0">
            <li
              v-for="(crumb, index) in crumbs"
              :key="index"
              :class="[
                'flex items-center gap-1.5 min-w-0',
                index < crumbs.length - 1 ? 'hidden sm:flex' : '',
              ]"
            >
              <RouterLink
                v-if="crumb.to && index < crumbs.length - 1"
                :to="crumb.to"
                class="text-c-tx2 no-underline hover:text-c-tx hover:underline underline-offset-2"
                >{{ crumb.label }}</RouterLink
              >
              <span
                v-else
                :class="index === crumbs.length - 1 ? 'text-c-tx font-medium truncate' : ''"
                :aria-current="index === crumbs.length - 1 ? 'page' : undefined"
                >{{ crumb.label }}</span
              >
              <span v-if="index < crumbs.length - 1" class="text-c-tx3" aria-hidden="true">/</span>
            </li>
          </ol>
        </nav>

        <div class="ml-auto flex items-center gap-1.5 md:gap-2">
          <button
            v-if="health.restartedOnNewCode.value || auth.bundleStale"
            type="button"
            class="inline-flex items-center gap-1.5 h-8 px-2.5 rounded-full border border-c-border bg-c-warnsoft text-xs-var text-c-warn"
            title="The panel runs newer code than this page. Reload to get the current UI."
            @click="reloadPage"
          >
            <LIcon is="width:14px;height:14px" name="refresh-cw" />
            <span class="hidden sm:inline">New version — reload</span>
          </button>
          <button
            type="button"
            class="hidden sm:inline-flex items-center gap-2 h-8 pl-2.5 pr-1.5 min-w-[200px] rounded-lg border border-c-border bg-c-card text-c-tx3 text-xs-var shadow-card hover:border-c-bstrong hover:text-c-tx2 transition-colors"
            aria-label="Search and jump (command palette)"
            @click="paletteOpen = true"
          >
            <LIcon is="width:14px;height:14px" name="search" />
            <span>Search…</span>
            <kbd
              class="ml-auto mono text-2xs-var px-1.5 py-0.5 rounded border border-c-border bg-c-subtle text-c-tx3"
              >{{ isMac ? '⌘' : 'Ctrl' }} K</kbd
            >
          </button>
          <button
            type="button"
            class="sm:hidden w-9 h-9 grid place-items-center rounded-lg border border-c-border bg-c-card text-c-tx2"
            aria-label="Search and jump"
            @click="paletteOpen = true"
          >
            <LIcon is="width:16px;height:16px" name="search" />
          </button>
          <RouterLink
            v-if="runningJobs.length"
            to="/activity/jobs"
            class="inline-flex items-center gap-1.5 h-8 px-2.5 rounded-full border border-c-border bg-c-card text-xs-var text-c-tx2 no-underline hover:text-c-tx hover:border-c-bstrong transition-colors"
            :title="runningJobs.map((job) => job.label).join(', ')"
          >
            <span
              class="w-3 h-3 rounded-full border-[1.5px] border-c-bstrong border-t-c-accent animate-spin"
              aria-hidden="true"
            ></span>
            <span>{{ runningJobs.length }}<span class="hidden sm:inline"> running</span></span>
          </RouterLink>
          <span
            class="inline-flex items-center gap-1.5 h-8 px-2.5 bg-c-subtle border border-c-border rounded-full mono text-xs-var text-c-tx2 max-w-[180px]"
            :title="health.online.value ? `Connected to ${host.hostname}` : 'The panel is not answering'"
            role="status"
          >
            <span
              :class="[
                'w-[7px] h-[7px] rounded-full shrink-0',
                health.online.value
                  ? 'bg-c-ok shadow-[0_0_0_3px_var(--ok-soft)]'
                  : 'bg-c-danger shadow-[0_0_0_3px_var(--danger-soft)]',
              ]"
              aria-hidden="true"
            ></span>
            <span class="truncate">{{ health.online.value ? host.hostname : 'Disconnected' }}</span>
          </span>
        </div>
      </header>

      <main
        id="main"
        class="content flex-1 overflow-y-auto py-[var(--pad-y)] px-[var(--pad-x)]"
        tabindex="-1"
      >
        <div class="mx-auto max-w-[1400px]">
          <RouterView v-slot="{ Component, route: viewRoute }">
            <Transition name="page" mode="out-in">
              <component :is="Component" :key="viewRoute.path" />
            </Transition>
          </RouterView>
        </div>
      </main>
    </div>
  </div>

  <LoginView v-else-if="auth.status === 'anonymous'" />

  <!-- Checking the session, loading the host, or the panel is unreachable. -->
  <div
    v-else
    class="h-[100dvh] w-screen flex flex-col items-center justify-center bg-c-canvas text-c-tx select-none"
  >
    <div
      class="w-14 h-14 rounded-2xl brand-mark text-white flex items-center justify-center font-bold text-xl tracking-[-0.05em] shadow-lg ring-1 ring-inset ring-white/15 mb-5"
      aria-hidden="true"
    >
      N
    </div>
    <div class="flex items-center gap-2 text-sm-var text-c-tx2" role="status">
      <span
        v-if="auth.status !== 'unreachable'"
        class="w-3.5 h-3.5 rounded-full border-2 border-c-bstrong border-t-c-accent animate-spin"
        aria-hidden="true"
      ></span>
      <span>{{ auth.status === 'unreachable' ? 'Cannot reach the panel.' : 'Loading…' }}</span>
    </div>
    <Btn v-if="auth.status === 'unreachable'" class="mt-5" @click="auth.check()">
      <LIcon name="refresh-cw" /> Try again
    </Btn>
  </div>

  <ToastList />
  <template v-if="signedIn">
    <CommandPalette v-if="paletteOpen" @close="paletteOpen = false" />
    <ChangePasswordDialog v-if="passwordDialog" @close="passwordDialog = false" />
    <!-- Gated on hostLoaded: a dialog restored after a reload waits for the shell. -->
    <OverlayModal v-if="overlay && hostLoaded" :overlay="overlay" @close="overlay = null" />
    <InstallDialog v-if="installDialog" :dialog="installDialog" @close="installDialog = null" />
    <NetworkDialog v-if="networkDialog" :dialog="networkDialog" @close="networkDialog = null" />
  </template>
  <ConfirmDialog v-if="confirm" :confirm="confirm" @close="confirm = null" />
</template>
