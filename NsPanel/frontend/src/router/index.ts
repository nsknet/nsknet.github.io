/** The single route table.
 *
 * It owns everything that used to live in five parallel lookup objects: which
 * component renders, which nav item lights up, the breadcrumb trail, and which
 * stores a screen needs. Adding a screen means adding one entry here.
 *
 * Information architecture (the nav rail, top to bottom):
 *   Overview · Apps · Tools · Network (Firewall, DNS, Interfaces)
 *   · System (Host, Storage, Processes) · Activity (Jobs, Audit) · Settings
 * Paths from the previous layout redirect to their new home, so bookmarks work.
 */
import { createRouter, createWebHashHistory, type RouteLocationNormalized } from 'vue-router';

export type StoreKey =
  | 'system'
  | 'disks'
  | 'sites'
  | 'tools'
  | 'services'
  | 'dns'
  | 'firewall'
  | 'processes'
  | 'jobs'
  | 'panel'
  | 'dashboard';

export type NavGroup = 'Overview' | 'Apps' | 'Network' | 'System' | 'Activity' | 'Settings';

export interface Crumb {
  label: string;
  to?: string;
}

declare module 'vue-router' {
  interface RouteMeta {
    /** Nav item to highlight — defaults to the route name. */
    rail?: string;
    /** Label, icon and nav section. Omit to keep the route out of the nav. */
    nav?: { label: string; icon: string; order: number; group: NavGroup };
    /** Stores to load when entering the route. */
    loads?: StoreKey[];
    /** Breadcrumb trail; the last crumb is the current page. */
    crumbs?: (route: RouteLocationNormalized) => Crumb[];
    /** Browser tab title (defaults to the last crumb). */
    title?: string;
  }
}

const param = (route: { params: Record<string, unknown> }, key: string) => String(route.params[key] ?? '');

export const router = createRouter({
  history: createWebHashHistory(),
  scrollBehavior: () => ({ top: 0 }),
  routes: [
    // ── Overview ────────────────────────────────────────────────────────────
    {
      path: '/',
      name: 'overview',
      component: () => import('@/views/OverviewView.vue'),
      meta: {
        nav: { label: 'Overview', icon: 'layout-dashboard', order: 1, group: 'Overview' },
        loads: ['dashboard'],
        crumbs: () => [{ label: 'Overview' }],
      },
    },

    // ── Apps: sites (nginx) and services (systemd, tunnels) in one place ────
    {
      path: '/apps',
      name: 'apps',
      component: () => import('@/views/apps/AppsView.vue'),
      meta: {
        nav: { label: 'Apps', icon: 'layers', order: 2, group: 'Apps' },
        loads: ['sites', 'services'],
        crumbs: () => [{ label: 'Apps' }],
      },
    },
    {
      path: '/apps/new',
      name: 'app-new',
      component: () => import('@/views/apps/CreateAppView.vue'),
      meta: {
        rail: 'apps',
        loads: ['sites', 'services', 'tools'],
        crumbs: () => [{ label: 'Apps', to: '/apps' }, { label: 'New app' }],
      },
    },
    {
      path: '/apps/site/:name',
      name: 'site-detail',
      component: () => import('@/views/apps/SiteDetailView.vue'),
      meta: {
        rail: 'apps',
        loads: ['sites'],
        crumbs: (route) => [{ label: 'Apps', to: '/apps' }, { label: param(route, 'name') }],
      },
    },
    {
      path: '/apps/service/:name',
      name: 'service-detail',
      component: () => import('@/views/apps/ServiceDetailView.vue'),
      meta: {
        rail: 'apps',
        loads: ['services', 'sites'],
        crumbs: (route) => [{ label: 'Apps', to: '/apps' }, { label: param(route, 'name') }],
      },
    },
    {
      path: '/tools',
      name: 'tools',
      component: () => import('@/views/ToolsView.vue'),
      meta: {
        nav: { label: 'Tools', icon: 'package', order: 3, group: 'Apps' },
        loads: ['tools'],
        crumbs: () => [{ label: 'Tools' }],
      },
    },

    // ── Network ─────────────────────────────────────────────────────────────
    {
      path: '/network/firewall',
      name: 'firewall',
      component: () => import('@/views/network/FirewallView.vue'),
      meta: {
        nav: { label: 'Firewall', icon: 'shield', order: 10, group: 'Network' },
        loads: ['firewall'],
        crumbs: () => [{ label: 'Network' }, { label: 'Firewall' }],
      },
    },
    {
      path: '/network/dns',
      name: 'dns',
      component: () => import('@/views/network/DnsView.vue'),
      meta: {
        nav: { label: 'DNS', icon: 'globe', order: 11, group: 'Network' },
        loads: ['dns'],
        crumbs: () => [{ label: 'Network' }, { label: 'DNS' }],
      },
    },
    {
      path: '/network/interfaces',
      name: 'interfaces',
      component: () => import('@/views/network/InterfacesView.vue'),
      meta: {
        nav: { label: 'Interfaces', icon: 'network', order: 12, group: 'Network' },
        loads: ['system'],
        crumbs: () => [{ label: 'Network' }, { label: 'Interfaces' }],
      },
    },

    // ── System ──────────────────────────────────────────────────────────────
    {
      path: '/system',
      name: 'host',
      component: () => import('@/views/system/HostView.vue'),
      meta: {
        nav: { label: 'Host', icon: 'server', order: 20, group: 'System' },
        loads: ['system'],
        crumbs: () => [{ label: 'System' }, { label: 'Host' }],
      },
    },
    {
      path: '/system/storage',
      name: 'storage',
      component: () => import('@/views/system/StorageView.vue'),
      meta: {
        nav: { label: 'Storage', icon: 'hard-drive', order: 21, group: 'System' },
        loads: ['system', 'disks'],
        crumbs: () => [{ label: 'System' }, { label: 'Storage' }],
      },
    },
    {
      path: '/system/processes',
      name: 'processes',
      component: () => import('@/views/system/ProcessesView.vue'),
      meta: {
        nav: { label: 'Processes', icon: 'activity', order: 22, group: 'System' },
        // No `loads`: the view fetches with the search term from the URL.
        crumbs: () => [{ label: 'System' }, { label: 'Processes' }],
      },
    },

    // ── Activity ────────────────────────────────────────────────────────────
    {
      path: '/activity/jobs',
      name: 'jobs',
      component: () => import('@/views/activity/JobsView.vue'),
      meta: {
        nav: { label: 'Jobs', icon: 'terminal', order: 30, group: 'Activity' },
        loads: ['jobs'],
        crumbs: () => [{ label: 'Activity' }, { label: 'Jobs' }],
      },
    },
    {
      path: '/activity/audit',
      name: 'audit',
      component: () => import('@/views/activity/AuditView.vue'),
      meta: {
        nav: { label: 'Audit log', icon: 'scroll-text', order: 31, group: 'Activity' },
        // No `loads`: the view pages and filters on the server.
        crumbs: () => [{ label: 'Activity' }, { label: 'Audit log' }],
      },
    },

    // ── Settings ────────────────────────────────────────────────────────────
    {
      path: '/settings/panel',
      name: 'panel',
      component: () => import('@/views/settings/PanelServiceView.vue'),
      meta: {
        nav: { label: 'Panel service', icon: 'rocket', order: 40, group: 'Settings' },
        loads: ['panel'],
        crumbs: () => [{ label: 'Settings' }, { label: 'Panel service' }],
      },
    },
    {
      path: '/settings/security',
      name: 'security',
      component: () => import('@/views/settings/SecurityView.vue'),
      meta: {
        nav: { label: 'Security', icon: 'key-round', order: 41, group: 'Settings' },
        crumbs: () => [{ label: 'Settings' }, { label: 'Security' }],
      },
    },

    // ── Paths from the previous layout ──────────────────────────────────────
    { path: '/sites', redirect: { path: '/apps', query: { type: 'site' } } },
    { path: '/sites/new', redirect: '/apps/new' },
    { path: '/sites/:slug', redirect: (to) => `/apps/site/${encodeURIComponent(param(to, 'slug'))}` },
    { path: '/services', redirect: { path: '/apps', query: { type: 'service' } } },
    { path: '/services/:name', redirect: (to) => `/apps/service/${encodeURIComponent(param(to, 'name'))}` },
    { path: '/firewall', redirect: '/network/firewall' },
    { path: '/dns', redirect: '/network/dns' },
    { path: '/tasks', redirect: '/system/processes' },
    { path: '/jobs', redirect: '/activity/jobs' },
    { path: '/logs', redirect: '/activity/audit' },
    { path: '/panel', redirect: '/settings/panel' },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
});

router.afterEach((to) => {
  const crumbs = to.meta.crumbs?.(to) ?? [];
  const title = to.meta.title ?? crumbs[crumbs.length - 1]?.label;
  document.title = title ? `${title} · NsPanel` : 'NsPanel';
});

/** Nav items, in order. */
export const navItems = router
  .getRoutes()
  .filter((route) => route.meta.nav)
  .sort((a, b) => a.meta.nav!.order - b.meta.nav!.order)
  .map((route) => ({
    key: String(route.name),
    path: route.path,
    label: route.meta.nav!.label,
    icon: route.meta.nav!.icon,
    group: route.meta.nav!.group,
  }));

/** Nav items bucketed by section, sections in first-appearance order. */
export const navGroups = navItems.reduce<{ group: NavGroup; items: typeof navItems }[]>(
  (groups, item) => {
    const last = groups[groups.length - 1];
    if (last?.group === item.group) last.items.push(item);
    else groups.push({ group: item.group, items: [item] });
    return groups;
  },
  [],
);
