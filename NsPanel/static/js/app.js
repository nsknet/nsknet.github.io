import { appState, MOCK, navigate, openSite, addToast, openOverlay, confirmThen, currentRailKey, syncHashToState, fetchSamples } from './store.js';
import { LIcon, StatusBadge, TypeChip, Btn, Badge } from './utils.js';
import { OverlayModal, ConfirmDialog, InstallDialog, NetworkDialog, ToastList } from './components.js';
import { Dashboard } from './screens/Dashboard.js';
import { Sites } from './screens/Sites.js';
import { SiteDetail } from './screens/SiteDetail.js';
import { CreateSite } from './screens/CreateSite.js';
import { DNS } from './screens/DNS.js';
import { System } from './screens/System.js';
import { Firewall } from './screens/Firewall.js';
import { Services } from './screens/Services.js';
import { ServiceDetail } from './screens/ServiceDetail.js';
import { Tools } from './screens/Tools.js';
import { Logs } from './screens/Logs.js';
import { TaskManager } from './screens/TaskManager.js';

const { createApp, computed, watch, nextTick, ref } = Vue;

const SCREENS = {
  'dashboard': Dashboard,
  'sites': Sites,
  'site-detail': SiteDetail,
  'create-site': CreateSite,
  'dns': DNS,
  'system': System,
  'firewall': Firewall,
  'services': Services,
  'service-detail': ServiceDetail,
  'tools': Tools,
  'logs': Logs,
  'tasks': TaskManager,
};

// Each crumb: { label, screen? } — crumbs with a `screen` navigate on click.
const CRUMBS = {
  'dashboard': () => [{ label: 'Dashboard' }],
  'sites': () => [{ label: 'Sites' }],
  'site-detail': () => [
    { label: 'Sites', screen: 'sites' },
    { label: MOCK.sites.find((x) => x.slug === appState.selectedSiteSlug)?.name || 'Site' },
  ],
  'create-site': () => [{ label: 'Sites', screen: 'sites' }, { label: 'New site' }],
  'dns': () => [{ label: 'DNS' }],
  'system': () => [{ label: 'System' }],
  'firewall': () => [{ label: 'Firewall' }],
  'services': () => [{ label: 'Services' }],
  'service-detail': () => [
    { label: 'Services', screen: 'services' },
    { label: appState.selectedServiceName || 'Service' },
  ],
  'tools': () => [{ label: 'Tools' }],
  'tasks': () => [{ label: 'Task manager' }],
  'logs': () => [{ label: 'Audit logs' }],
};

const NAV_KEYS = ['dashboard', 'system', 'firewall', 'sites', 'dns', 'services', 'tools', 'logs', 'tasks'];

// Rail nav items — key, icon and the label shown when the sidebar is expanded
const NAV_ITEMS = [
  { key: 'dashboard', icon: 'layout-dashboard', label: 'Dashboard' },
  { key: 'system', icon: 'cpu', label: 'System' },
  { key: 'firewall', icon: 'shield', label: 'Firewall' },
  { key: 'sites', icon: 'globe', label: 'Sites' },
  { key: 'dns', icon: 'network', label: 'DNS' },
  { key: 'services', icon: 'server', label: 'Services' },
  { key: 'tools', icon: 'wrench', label: 'Tools' },
  { key: 'tasks', icon: 'activity', label: 'Task Manager' },
  { key: 'logs', icon: 'scroll-text', label: 'Audit Logs' },
];

function applyThemeVars() {
  const { theme } = appState;
  document.body.classList.toggle('theme-dark', theme === 'dark');
  document.body.classList.toggle('theme-light', theme !== 'dark');
}

const App = {
  setup() {
    const currentScreenComp = computed(() => SCREENS[appState.currentScreen] || Dashboard);
    const crumbs = computed(() => (CRUMBS[appState.currentScreen] || (() => [{ label: appState.currentScreen }]))());
    const railKey = computed(() => currentRailKey());

    function isRailActive(key) { return railKey.value === key; }

    // Sidebar collapse/expand — persisted across reloads
    const sidebarOpen = ref(localStorage.getItem('sidebarOpen') === '1');
    function toggleSidebar() {
      sidebarOpen.value = !sidebarOpen.value;
      localStorage.setItem('sidebarOpen', sidebarOpen.value ? '1' : '0');
    }

    function toggleTheme() {
      appState.theme = appState.theme === 'dark' ? 'light' : 'dark';
    }

    function logout() {
      window.location.href = '/logout';
    }

    // Watch appState for theme changes
    watch(() => appState.theme, applyThemeVars, { immediate: true });

    // When screen changes, fetch its data and re-hydrate Lucide
    watch(() => appState.currentScreen, (newScreen) => {
      fetchSamples().then(() => nextTick(() => window.lucide?.createIcons()));
      nextTick(() => window.lucide?.createIcons());
    }, { immediate: true });

    return {
      appState, MOCK, NAV_KEYS, NAV_ITEMS,
      currentScreenComp, crumbs, isRailActive,
      sidebarOpen, toggleSidebar,
      navigate, openSite, addToast, openOverlay, confirmThen,
      toggleTheme,
      logout,
    };
  },

  // String template — bypasses browser HTML parser, so self-closing tags work correctly
  template: `
    <div v-if="appState.loaded" class="grid h-screen overflow-hidden bg-c-bg sidebar-grid" :style="{ gridTemplateColumns: (sidebarOpen ? '220px' : '56px') + ' 1fr' }">

      <!-- Left Rail -->
      <nav :class="['border-r border-c-border bg-c-elev flex flex-col py-3 gap-1', sidebarOpen ? 'items-stretch px-3' : 'items-center']" aria-label="Primary">
        <div :class="['flex items-center mb-3', sidebarOpen ? 'gap-2.5 px-1' : 'justify-center']">
          <div class="w-9 h-9 shrink-0 rounded-theme bg-c-accent text-c-acfg grid place-items-center font-bold text-sm tracking-[-0.04em] shadow-sm cursor-pointer hover:scale-105 active:scale-95 transition-all duration-150" title="NsPanel" @click="navigate('dashboard')">N</div>
          <span v-if="sidebarOpen" class="font-semibold text-sm tracking-[-0.02em] text-c-tx whitespace-nowrap overflow-hidden">NsPanel</span>
        </div>

        <button v-for="item in NAV_ITEMS" :key="item.key"
          :class="['rail-btn', { active: isRailActive(item.key), 'rail-btn--wide': sidebarOpen }]"
          :data-tip="sidebarOpen ? null : item.label" :aria-label="item.label" @click="navigate(item.key)">
          <l-icon :name="item.icon" />
          <span v-if="sidebarOpen" class="rail-label">{{ item.label }}</span>
        </button>

        <div class="flex-1"></div>

        <button :class="['rail-btn', { 'rail-btn--wide': sidebarOpen }]" :data-tip="sidebarOpen ? null : 'Toggle theme'" aria-label="Toggle theme" @click="toggleTheme">
          <l-icon :name="appState.theme === 'dark' ? 'moon' : 'sun'" />
          <span v-if="sidebarOpen" class="rail-label">Theme</span>
        </button>
        <button :class="['rail-btn', { 'rail-btn--wide': sidebarOpen }]" :data-tip="sidebarOpen ? null : 'Log out'" aria-label="Log out" @click="logout">
          <l-icon name="log-out" />
          <span v-if="sidebarOpen" class="rail-label">Log out</span>
        </button>
        <button :class="['rail-btn', { 'rail-btn--wide': sidebarOpen }]" :data-tip="sidebarOpen ? null : 'Expand'" :aria-label="sidebarOpen ? 'Collapse sidebar' : 'Expand sidebar'" @click="toggleSidebar">
          <l-icon :name="sidebarOpen ? 'panel-left-close' : 'panel-left-open'" />
          <span v-if="sidebarOpen" class="rail-label">Collapse</span>
        </button>
      </nav>

      <!-- Main -->
      <div class="flex flex-col min-w-0 h-screen overflow-hidden">
        <header class="h-12 border-b border-c-border flex items-center px-[var(--pad-x)] gap-3 shrink-0 bg-c-bg">
          <nav class="flex items-center gap-2 text-sm-var text-c-tx2" aria-label="Breadcrumb">
            <a class="inline-flex items-center cursor-pointer text-c-tx3 hover:text-c-tx transition-colors" aria-label="Dashboard" title="Dashboard" @click="navigate('dashboard')">
              <l-icon name="house" is="width:14px;height:14px" />
            </a>
            <span class="text-c-tx3">/</span>
            <template v-for="(crumb, i) in crumbs" :key="i">
              <template v-if="i < crumbs.length - 1">
                <a v-if="crumb.screen" class="cursor-pointer hover:text-c-tx hover:underline underline-offset-2 transition-colors" @click="navigate(crumb.screen)">{{ crumb.label }}</a>
                <span v-else>{{ crumb.label }}</span>
                <span class="text-c-tx3">/</span>
              </template>
              <span v-else class="text-c-tx font-medium">{{ crumb.label }}</span>
            </template>
          </nav>
          <div class="ml-auto flex items-center gap-2">
            <span class="inline-flex items-center gap-1.5 py-1 px-2.5 bg-c-subtle border border-c-border rounded-full mono text-xs-var text-c-tx2">
              <span class="w-[6px] h-[6px] rounded-full bg-c-ok shadow-[0_0_0_3px_var(--ok-soft)]"></span>
              <span>{{ MOCK.host.hostname }}</span>
            </span>
          </div>
        </header>

        <main class="content flex-1 overflow-y-auto py-[var(--pad-y)] px-[var(--pad-x)]">
          <component :is="currentScreenComp" />
        </main>
      </div>
    </div>

    <!-- Pulsing aesthetic Loading Splash Screen when not logged in -->
    <div v-else class="h-screen w-screen flex flex-col items-center justify-center bg-[#09090b] text-[#f4f4f5] select-none font-sans">
      <div class="relative flex items-center justify-center mb-8">
        <!-- Glow effect behind the logo -->
        <div class="absolute w-24 h-24 rounded-2xl bg-gradient-to-tr from-[#f59e0b] to-[#ea580c] opacity-25 blur-2xl animate-pulse"></div>
        <!-- Modern Glassmorphic Logo -->
        <div class="relative w-16 h-16 rounded-2xl bg-gradient-to-tr from-[#f59e0b] to-[#ea580c] text-white flex items-center justify-center font-bold text-2xl tracking-[-0.05em] shadow-lg shadow-amber-500/20 border border-white/10">
          N
        </div>
      </div>
      
      <!-- Text details -->
      <h2 class="text-xl font-semibold tracking-[-0.02em] mb-1.5 text-white/90">NsPanel</h2>
      <div class="flex items-center gap-2 text-xs-var text-zinc-400 mono mt-2">
        <svg class="animate-spin h-3.5 w-3.5 text-amber-500" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
        </svg>
        <span>Awaiting authentication...</span>
      </div>
    </div>

    <!-- Toasts, tweaks, modals — siblings rendered outside the grid -->
    <toast-list />
    <overlay-modal v-if="appState.overlay" :overlay="appState.overlay" @close="appState.overlay = null" />
    <confirm-dialog v-if="appState.confirm" :confirm="appState.confirm" @close="appState.confirm = null" />
    <install-dialog v-if="appState.installDialog" :dialog="appState.installDialog" @close="appState.installDialog = null" />
    <network-dialog v-if="appState.networkDialog" :dialog="appState.networkDialog" @close="appState.networkDialog = null" />
  `,
};

const app = createApp(App);

// Global components
app.component('l-icon', LIcon);
app.component('btn', Btn);
app.component('badge', Badge);
app.component('status-badge', StatusBadge);
app.component('type-chip', TypeChip);
app.component('overlay-modal', OverlayModal);
app.component('confirm-dialog', ConfirmDialog);
app.component('install-dialog', InstallDialog);
app.component('network-dialog', NetworkDialog);
app.component('toast-list', ToastList);

// Sync hash router
window.addEventListener('hashchange', syncHashToState);
syncHashToState();

// Data fetching is handled automatically via the immediate watcher on currentScreen inside App setup.

app.mount('#app');

// Initial Lucide hydration
nextTick(() => window.lucide?.createIcons());
