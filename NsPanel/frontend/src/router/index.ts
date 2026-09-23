/** The single route table.
 *
 * It owns everything that used to live in five parallel lookup objects: which
 * component renders, which rail item lights up, the breadcrumb trail, and which
 * stores a screen needs. Adding a screen means adding one entry here.
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
  | 'logs'
  | 'processes';

export type NavGroup = 'Overview' | 'Hosting' | 'System';

export interface Crumb {
  label: string;
  to?: string;
}

declare module 'vue-router' {
  interface RouteMeta {
    /** Rail item to highlight — defaults to the route name. */
    rail?: string;
    /** Label, icon and rail section. Omit to keep the route out of the rail. */
    nav?: { label: string; icon: string; order: number; group: NavGroup };
    /** Stores to load when entering the route. */
    loads?: StoreKey[];
    /** Breadcrumb trail; the last crumb is the current page. */
    crumbs?: (route: RouteLocationNormalized) => Crumb[];
  }
}

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    {
      path: '/',
      name: 'dashboard',
      component: () => import('@/views/DashboardView.vue'),
      meta: {
        nav: { label: 'Dashboard', icon: 'layout-dashboard', order: 1, group: 'Overview' },
        loads: ['system', 'sites', 'tools'],
        crumbs: () => [{ label: 'Dashboard' }],
      },
    },
    {
      path: '/system',
      name: 'system',
      component: () => import('@/views/SystemView.vue'),
      meta: {
        nav: { label: 'System', icon: 'cpu', order: 6, group: 'System' },
        loads: ['system', 'disks'],
        crumbs: () => [{ label: 'System' }],
      },
    },
    {
      path: '/firewall',
      name: 'firewall',
      component: () => import('@/views/FirewallView.vue'),
      meta: {
        nav: { label: 'Firewall', icon: 'shield', order: 7, group: 'System' },
        loads: ['firewall'],
        crumbs: () => [{ label: 'Firewall' }],
      },
    },
    {
      path: '/sites',
      name: 'sites',
      component: () => import('@/views/SitesView.vue'),
      meta: {
        nav: { label: 'Sites', icon: 'globe', order: 2, group: 'Hosting' },
        loads: ['sites'],
        crumbs: () => [{ label: 'Sites' }],
      },
    },
    {
      path: '/sites/new',
      name: 'create-site',
      component: () => import('@/views/CreateSiteView.vue'),
      meta: {
        rail: 'sites',
        loads: ['sites'],
        crumbs: () => [{ label: 'Sites', to: '/sites' }, { label: 'New site' }],
      },
    },
    {
      path: '/sites/:slug',
      name: 'site-detail',
      component: () => import('@/views/SiteDetailView.vue'),
      props: true,
      meta: {
        rail: 'sites',
        loads: ['sites'],
        crumbs: (route) => [
          { label: 'Sites', to: '/sites' },
          { label: String(route.params.slug ?? 'Site') },
        ],
      },
    },
    {
      path: '/dns',
      name: 'dns',
      component: () => import('@/views/DnsView.vue'),
      meta: {
        nav: { label: 'DNS', icon: 'network', order: 3, group: 'Hosting' },
        loads: ['dns'],
        crumbs: () => [{ label: 'DNS' }],
      },
    },
    {
      path: '/services',
      name: 'services',
      component: () => import('@/views/ServicesView.vue'),
      meta: {
        nav: { label: 'Services', icon: 'server', order: 4, group: 'Hosting' },
        loads: ['services'],
        crumbs: () => [{ label: 'Services' }],
      },
    },
    {
      path: '/services/:name',
      name: 'service-detail',
      component: () => import('@/views/ServiceDetailView.vue'),
      props: true,
      meta: {
        rail: 'services',
        loads: ['services'],
        crumbs: (route) => [
          { label: 'Services', to: '/services' },
          { label: String(route.params.name ?? 'Service') },
        ],
      },
    },
    {
      path: '/tools',
      name: 'tools',
      component: () => import('@/views/ToolsView.vue'),
      meta: {
        nav: { label: 'Tools', icon: 'wrench', order: 5, group: 'Hosting' },
        loads: ['tools'],
        crumbs: () => [{ label: 'Tools' }],
      },
    },
    {
      path: '/tasks',
      name: 'tasks',
      component: () => import('@/views/TaskManagerView.vue'),
      meta: {
        nav: { label: 'Task Manager', icon: 'activity', order: 8, group: 'System' },
        loads: ['processes'],
        crumbs: () => [{ label: 'Task manager' }],
      },
    },
    {
      path: '/logs',
      name: 'logs',
      component: () => import('@/views/LogsView.vue'),
      meta: {
        nav: { label: 'Audit Logs', icon: 'scroll-text', order: 9, group: 'System' },
        loads: ['logs'],
        crumbs: () => [{ label: 'Audit logs' }],
      },
    },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
});

/** Rail items, in declaration order. */
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

/** Rail items bucketed by section, sections in first-appearance order. */
export const navGroups = navItems.reduce<{ group: NavGroup; items: typeof navItems }[]>(
  (groups, item) => {
    const last = groups[groups.length - 1];
    if (last?.group === item.group) last.items.push(item);
    else groups.push({ group: item.group, items: [item] });
    return groups;
  },
  [],
);
