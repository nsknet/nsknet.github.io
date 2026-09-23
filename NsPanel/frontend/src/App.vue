<script setup lang="ts">
/** The shell: nav rail, breadcrumb header, routed screen, the palette and the dialogs. */
import { storeToRefs } from 'pinia';
import { computed, onMounted, onUnmounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';

import CommandPalette from '@/components/CommandPalette.vue';
import ConfirmDialog from '@/components/ConfirmDialog.vue';
import InstallDialog from '@/components/InstallDialog.vue';
import NetworkDialog from '@/components/NetworkDialog.vue';
import OverlayModal from '@/components/OverlayModal.vue';
import ToastList from '@/components/ToastList.vue';
import Btn from '@/components/ui/Btn.vue';
import LIcon from '@/components/ui/LIcon.vue';
import { navGroups } from '@/router';
import { useSystemStore } from '@/stores/system';
import { useUiStore } from '@/stores/ui';

const route = useRoute();
const router = useRouter();
const ui = useUiStore();
const system = useSystemStore();

const { sidebarOpen, theme, overlay, confirm, installDialog, networkDialog, paletteOpen } =
  storeToRefs(ui);
const { host, hostLoaded } = storeToRefs(system);

const crumbs = computed(() => route.meta.crumbs?.(route) ?? [{ label: String(route.name ?? '') }]);
const railKey = computed(() => route.meta.rail ?? String(route.name ?? ''));
const isMac = /Mac|iPhone|iPad/.test(navigator.platform);

function onGlobalKeydown(event: KeyboardEvent): void {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault();
    if (hostLoaded.value) paletteOpen.value = !paletteOpen.value;
  }
}

onMounted(() => {
  ui.applyTheme();
  // The header shows the hostname on every screen, not only the ones that load it.
  if (!hostLoaded.value) void system.load();
  document.addEventListener('keydown', onGlobalKeydown);
});
onUnmounted(() => document.removeEventListener('keydown', onGlobalKeydown));

function logout(): void {
  window.location.href = '/logout';
}
</script>

<template>
  <div
    v-if="hostLoaded"
    class="grid h-screen overflow-hidden bg-c-bg sidebar-grid"
    :style="{ '--rail-w': sidebarOpen ? '220px' : '56px' }"
  >
    <nav
      :class="[
        'border-r border-c-border bg-c-elev flex flex-col py-3 gap-1',
        sidebarOpen ? 'items-stretch px-3' : 'items-center',
      ]"
      aria-label="Primary"
    >
      <div :class="['flex items-center mb-3', sidebarOpen ? 'gap-2.5 px-1' : 'justify-center']">
        <div
          class="w-9 h-9 shrink-0 rounded-theme bg-gradient-to-tr from-[#f59e0b] to-[#ea580c] text-white grid place-items-center font-bold text-sm tracking-[-0.04em] shadow-sm ring-1 ring-inset ring-white/15 cursor-pointer hover:scale-105 active:scale-95 transition-transform duration-150"
          title="NsPanel"
          @click="router.push('/')"
        >
          N
        </div>
        <span
          v-if="sidebarOpen"
          class="font-semibold text-sm tracking-[-0.02em] text-c-tx whitespace-nowrap overflow-hidden"
          >NsPanel</span
        >
      </div>

      <template v-for="(section, sectionIndex) in navGroups" :key="section.group">
        <div
          v-if="sidebarOpen"
          :class="[
            'px-2.5 pb-1 text-[10px] uppercase tracking-[0.08em] font-semibold text-c-tx3 whitespace-nowrap',
            sectionIndex ? 'pt-3' : 'pt-0',
          ]"
        >
          {{ section.group }}
        </div>
        <div v-else-if="sectionIndex" class="w-6 h-px bg-c-border my-1.5" aria-hidden="true"></div>
        <button
          v-for="item in section.items"
          :key="item.key"
          :class="['rail-btn', { active: railKey === item.key, 'rail-btn--wide': sidebarOpen }]"
          :data-tip="sidebarOpen ? null : item.label"
          :aria-label="item.label"
          @click="router.push(item.path)"
        >
          <LIcon :name="item.icon" />
          <span v-if="sidebarOpen" class="rail-label">{{ item.label }}</span>
        </button>
      </template>

      <div class="flex-1"></div>

      <button
        :class="['rail-btn', { 'rail-btn--wide': sidebarOpen }]"
        :data-tip="sidebarOpen ? null : 'Toggle theme'"
        aria-label="Toggle theme"
        @click="ui.toggleTheme()"
      >
        <LIcon :name="theme === 'dark' ? 'moon' : 'sun'" />
        <span v-if="sidebarOpen" class="rail-label">Theme</span>
      </button>
      <button
        :class="['rail-btn', { 'rail-btn--wide': sidebarOpen }]"
        :data-tip="sidebarOpen ? null : 'Log out'"
        aria-label="Log out"
        @click="logout"
      >
        <LIcon name="log-out" />
        <span v-if="sidebarOpen" class="rail-label">Log out</span>
      </button>
      <button
        :class="['rail-btn', { 'rail-btn--wide': sidebarOpen }]"
        :data-tip="sidebarOpen ? null : 'Expand'"
        :aria-label="sidebarOpen ? 'Collapse sidebar' : 'Expand sidebar'"
        @click="ui.toggleSidebar()"
      >
        <LIcon :name="sidebarOpen ? 'panel-left-close' : 'panel-left-open'" />
        <span v-if="sidebarOpen" class="rail-label">Collapse</span>
      </button>
    </nav>

    <div class="flex flex-col min-w-0 h-screen overflow-hidden bg-c-canvas">
      <header
        class="h-12 border-b border-c-border flex items-center px-[var(--pad-x)] gap-3 shrink-0 bg-c-bg/80 backdrop-blur-md backdrop-saturate-150 relative z-10"
      >
        <nav class="flex items-center gap-2 text-sm-var text-c-tx2" aria-label="Breadcrumb">
          <a
            class="inline-flex items-center cursor-pointer text-c-tx3 hover:text-c-tx transition-colors"
            aria-label="Dashboard"
            title="Dashboard"
            @click="router.push('/')"
          >
            <LIcon name="house" is="width:14px;height:14px" />
          </a>
          <span class="text-c-tx3">/</span>
          <template v-for="(crumb, index) in crumbs" :key="index">
            <template v-if="index < crumbs.length - 1">
              <a
                v-if="crumb.to"
                class="cursor-pointer hover:text-c-tx hover:underline underline-offset-2 transition-colors"
                @click="router.push(crumb.to)"
                >{{ crumb.label }}</a
              >
              <span v-else>{{ crumb.label }}</span>
              <span class="text-c-tx3">/</span>
            </template>
            <span v-else class="text-c-tx font-medium">{{ crumb.label }}</span>
          </template>
        </nav>
        <div class="ml-auto flex items-center gap-2">
          <button
            class="hidden sm:inline-flex items-center gap-2 h-8 pl-2.5 pr-1.5 min-w-[220px] rounded-lg border border-c-border bg-c-card text-c-tx3 text-xs-var shadow-card hover:border-c-bstrong hover:text-c-tx2 transition-colors"
            aria-label="Open command palette"
            @click="paletteOpen = true"
          >
            <LIcon name="search" is="width:14px;height:14px" />
            <span>Search…</span>
            <kbd
              class="ml-auto mono text-[10px] px-1.5 py-0.5 rounded border border-c-border bg-c-subtle text-c-tx3"
              >{{ isMac ? '⌘' : 'Ctrl' }} K</kbd
            >
          </button>
          <button
            class="sm:hidden inline-flex items-center justify-center w-8 h-8 rounded-lg border border-c-border bg-c-card text-c-tx2"
            aria-label="Open command palette"
            @click="paletteOpen = true"
          >
            <LIcon name="search" is="width:15px;height:15px" />
          </button>
          <span
            class="inline-flex items-center gap-1.5 py-1 px-2.5 bg-c-subtle border border-c-border rounded-full mono text-xs-var text-c-tx2"
          >
            <span class="w-[6px] h-[6px] rounded-full bg-c-ok shadow-[0_0_0_3px_var(--ok-soft)]"></span>
            <span>{{ host.hostname }}</span>
          </span>
        </div>
      </header>

      <main class="content flex-1 overflow-y-auto py-[var(--pad-y)] px-[var(--pad-x)]">
        <RouterView v-slot="{ Component, route: viewRoute }">
          <Transition name="page" mode="out-in">
            <component :is="Component" :key="viewRoute.path" />
          </Transition>
        </RouterView>
      </main>
    </div>
  </div>

  <!-- Shown until the first /api/v1/system call succeeds, i.e. until Basic Auth passes. -->
  <div
    v-else
    class="h-screen w-screen flex flex-col items-center justify-center bg-[#09090b] text-[#f4f4f5] select-none font-sans"
  >
    <div class="relative flex items-center justify-center mb-8">
      <div
        class="absolute w-24 h-24 rounded-2xl bg-gradient-to-tr from-[#f59e0b] to-[#ea580c] opacity-25 blur-2xl animate-pulse"
      ></div>
      <div
        class="relative w-16 h-16 rounded-2xl bg-gradient-to-tr from-[#f59e0b] to-[#ea580c] text-white flex items-center justify-center font-bold text-2xl tracking-[-0.05em] shadow-lg shadow-amber-500/20 border border-white/10"
      >
        N
      </div>
    </div>
    <h2 class="text-xl font-semibold tracking-[-0.02em] mb-1.5 text-white/90">NsPanel</h2>
    <div class="flex items-center gap-2 text-xs-var text-zinc-400 mono mt-2">
      <svg
        class="animate-spin h-3.5 w-3.5 text-amber-500"
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
      >
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
        <path
          class="opacity-75"
          fill="currentColor"
          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
        />
      </svg>
      <span>Awaiting authentication…</span>
    </div>
    <Btn class="mt-6" variant="ghost" @click="system.load()">
      <LIcon name="refresh-cw" /> Retry
    </Btn>
  </div>

  <ToastList />
  <CommandPalette v-if="paletteOpen" @close="paletteOpen = false" />
  <OverlayModal v-if="overlay" :overlay="overlay" @close="overlay = null" />
  <ConfirmDialog v-if="confirm" :confirm="confirm" @close="confirm = null" />
  <InstallDialog v-if="installDialog" :dialog="installDialog" @close="installDialog = null" />
  <NetworkDialog v-if="networkDialog" :dialog="networkDialog" @close="networkDialog = null" />
</template>
