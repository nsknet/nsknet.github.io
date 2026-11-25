/** The Overview screen's data: host stats, alerts, sites and tools in one call,
 *  plus the services list (the dashboard call does not carry it). */
import { defineStore } from 'pinia';

import { endpoints, fetchData } from '@/api/client';
import type { DashboardData } from '@/api/types';

import { createResource, type LoadOptions } from './resource';
import { useServicesStore } from './services';

const EMPTY: DashboardData = { stats: {}, alerts: [], sites: [], tools: [] };

export const useDashboardStore = defineStore('dashboard', () => {
  const dashboard = createResource<DashboardData>(EMPTY, () => fetchData<DashboardData>(endpoints.dashboard));

  /** Full load (route entry, Refresh, after a job): dashboard and services together. */
  async function load(options: LoadOptions = {}): Promise<void> {
    await Promise.all([dashboard.load(options), useServicesStore().load(options)]);
  }

  /** Background refresh: stats and alerts only (no site/tool probes on the
   *  server). Sites, tools and services change through jobs, and a job
   *  finishing reloads them anyway. */
  async function poll(): Promise<void> {
    try {
      const live = await fetchData<Pick<DashboardData, 'stats' | 'alerts'>>(endpoints.dashboardLive);
      dashboard.data.value = { ...dashboard.data.value, ...live };
      dashboard.error.value = null;
    } catch (error) {
      dashboard.error.value = error instanceof Error ? error.message : String(error);
    }
  }

  return {
    dashboard: dashboard.data,
    loading: dashboard.loading,
    loaded: dashboard.loaded,
    error: dashboard.error,
    load,
    poll,
  };
});
