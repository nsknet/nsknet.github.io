/** View models for the Apps screens: nginx sites and systemd services shown as one list.
 *  The raw API shapes stay in types.ts; these are what the stores hand to the views. */
import type { Service, Site } from './types';

/** What kind of app a row is. Sites are nginx vhosts; services are systemd units. */
export type AppKind = 'site' | 'service';

/** The finer type shown in the Type column and used by the filter pills. */
export type AppType = 'static' | 'proxy' | 'dotnet' | 'service' | 'tunnel';

/** Coarse state used for counts and muting rows. */
export type AppState = 'up' | 'stopped' | 'failed' | 'other';

/** A site with the raw access fields kept (the forms and port checks need them). */
export interface SiteApp extends Site {
  accessKind: 'domain' | 'port' | string;
  accessValue: string;
  logDir: string;
}

/** A service with its PID and whether it is a panel-managed Cloudflare tunnel. */
export interface ServiceApp extends Service {
  pid: number | null;
  isTunnel: boolean;
}

/** One row of the unified Apps list. */
export interface AppRow {
  /** Unique across sites and services. */
  key: string;
  kind: AppKind;
  type: AppType;
  name: string;
  /** Domain, port, proxy target or command — the one-line "where does it go". */
  target: string;
  /** Status exactly as the API reports it (running, ok, active, inactive, failed …). */
  status: string;
  state: AppState;
  /** Only set while the process runs; null otherwise (never 0 for a stopped app). */
  mem: number | null;
  cpu: number | null;
  /** Server-local "YYYY-MM-DD HH:MM" as the API sends it. */
  modified: string;
  /** Epoch ms of `modified`, 0 when unknown — for sorting. */
  modifiedAt: number;
  to: string;
}

/** Who already uses a port, for the create form's collision check. */
export interface PortOwner {
  port: number;
  owner: string;
  /** e.g. "public port of site foo" or "internal port of site bar". */
  role: string;
}
