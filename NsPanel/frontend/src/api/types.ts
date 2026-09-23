/** Shapes the panel API returns. Mirrors NsPanel/core/schemas.py. */

export interface DataResponse<T> {
  status: string;
  data: T;
}

export interface JobResponse {
  status: string;
  job_id: string;
  title: string;
  extra: Record<string, unknown>;
}

export interface MessageResponse {
  status: string;
  message: string;
}

// --- System -----------------------------------------------------------------

export interface NetworkInterface {
  iface: string;
  ip: string;
  prefix: number | null;
  cidr: string;
  method: string;
  gateway: string;
  dns: string[];
}

export interface SystemInfo {
  hostname: string;
  kernel: string;
  os_name: string;
  timezone: string;
  uptime: string;
  cpu_percent: number;
  cpu_count: number;
  cpu_count_physical: number;
  load_1: number;
  load_5: number;
  load_15: number;
  ram_used_gb: number;
  ram_total_gb: number;
  ram_percent: number;
  disk_used_gb: number;
  disk_total_gb: number;
  disk_percent: number;
  swap_used_gb: number;
  swap_total_gb: number;
  swap_percent: number;
  ips?: NetworkInterface[];
}

export interface Host {
  hostname: string;
  kernel: string;
  distro: string;
  timezone: string;
  uptime: string;
  cpu: { usage: number; cores: number; threads: number; load: [number, number, number] };
  ram: { used: number; total: number; pct: number };
  disk: { used: number; total: number; pct: number };
  swap: { used: number; total: number; pct: number };
  network: NetworkInterface[];
}

export interface DiskPartition {
  device: string;
  size?: string;
  fstype?: string;
  mountpoint?: string;
  label?: string;
  [key: string]: unknown;
}

// --- Sites ------------------------------------------------------------------

export interface RawSite {
  name: string;
  type: string;
  access: { kind: string; value: string };
  backend?: {
    proxy_target?: string;
    dll?: string;
    internal_port?: number | string;
    aspnetcore_env?: string;
  };
  status: {
    badge?: string;
    pid?: number | null;
    enabled?: string | null;
    memory_mb?: number | null;
    cpu_percent?: number | null;
  };
  paths?: { nginx_conf?: string; systemd_unit?: string; public?: string };
  last_modified?: string;
  created_at?: string;
}

/** The view model the screens render. */
export interface Site {
  slug: string;
  name: string;
  type: string;
  access: string;
  status: string;
  pid: number | null;
  autostart: string | null;
  mem: number | null;
  cpu: number | null;
  modified: string;
  dll: string;
  internalPort: number | string | null;
  env: string | null;
  created: string;
  configPath: string;
  unitPath: string;
  webRoot: string;
  proxyTarget: string | null;
}

// --- Tools ------------------------------------------------------------------

export interface InstallParam {
  name: string;
  env?: string;
  type: 'string' | 'number' | 'checkbox' | 'select';
  label: string;
  default?: string | number | boolean;
  help?: string;
  min?: number;
  max?: number;
  options?: { value: string; label: string }[];
}

export interface RawTool {
  module: {
    name: string;
    display_name: string;
    description: string;
    logo: string | null;
    requires_password: boolean;
    firewall_ports: number[];
    install_params: InstallParam[];
    can_uninstall: boolean;
    can_change_password: boolean;
  };
  status: {
    installed: boolean;
    version: string | null;
    service_state: string;
    ports: number[];
    extra: Record<string, string>;
  };
}

export interface Tool {
  id: string;
  name: string;
  desc: string;
  installed: boolean;
  version: string | null;
  state: string;
  ports: string | null;
  logo: string;
  color: string;
  diag?: [string, string][];
  requiresPassword: boolean;
  firewallPorts: number[];
  installParams: InstallParam[];
  canUninstall: boolean;
  canChangePassword: boolean;
}

// --- Services ---------------------------------------------------------------

export interface Tunnel {
  hostname: string;
  service_url: string;
  tunnel_id: string;
  tunnel_name: string;
  zone: string;
  public_url: string;
}

export interface RawService {
  name: string;
  description: string | null;
  path: string;
  content: string;
  state: string;
  enabled: string;
  last_edit: string;
  memory_mb: number | null;
  cpu_percent: number | null;
  pid: number | null;
  exec_start: string | null;
  working_dir: string | null;
  user: string | null;
  restart: string | null;
  restart_sec: string | null;
  syslog_id: string | null;
  env_vars: string[];
  tunnel: Tunnel | null;
}

export interface Service {
  name: string;
  desc: string;
  status: string;
  autostart: string;
  mem: number | null;
  cpu: number | null;
  modified: string;
  cmd: string;
  path: string;
  content: string;
  workingDir: string | null;
  user: string | null;
  restart: string | null;
  restartSec: string | null;
  syslogId: string | null;
  envVars: string[];
  /** Only for cloudflared.<hostname> units the panel created. */
  tunnel: Tunnel | null;
}

// --- DNS, firewall, processes, audit ----------------------------------------

export interface DnsRecord {
  ip: string;
  domain: string;
}

export interface DnsState {
  installed: boolean;
  running: boolean;
  version: string | null;
  hosts_file: string;
  records: DnsRecord[];
}

export interface RawFirewallRule {
  num: number;
  to: string;
  action: string;
  from_: string;
  is_v6: boolean;
  label: string;
}

export interface FirewallRule {
  idx: number;
  port: string;
  action: string;
  from: string;
  v6: boolean;
  label: string;
}

export interface UfwInfo {
  enabled: boolean;
  installed?: boolean;
  rules?: RawFirewallRule[];
}

export interface ProcessRow {
  pid: number;
  name: string;
  arguments: string;
  threads: number;
  user: string;
  ram_gb: number;
  cpu_percent: number;
}

export interface AuditEntry {
  t: string;
  a: string;
  d: Record<string, string | number>;
}
