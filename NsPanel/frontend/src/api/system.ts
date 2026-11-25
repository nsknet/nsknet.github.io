/** API shapes for the Network and System screens (firewall, DNS, interfaces,
 *  host, storage, processes). Mirrors routes/system.py, routes/firewall.py and
 *  routes/processes.py. */
import type { NetworkInterface, SystemInfo } from './types';

// --- Host and interfaces ------------------------------------------------------

/** One IPv4 address on an interface, with the live link state. */
export interface NetInterface extends NetworkInterface {
  /** Link is up (psutil isup). */
  up: boolean;
  /** Negotiated speed; null when the driver does not report one. */
  speed_mbps: number | null;
  mtu: number | null;
}

export interface RawNetInterface extends Partial<NetworkInterface> {
  iface: string;
  ip: string;
  up?: boolean;
  speed_mbps?: number | null;
  mtu?: number | null;
}

/** GET /api/v1/system, with the fields the shared `SystemInfo` leaves out. */
export interface SystemInfoFull extends Omit<SystemInfo, 'ips'> {
  architecture?: string;
  swap_enabled?: boolean;
  ips?: RawNetInterface[];
}

// --- Storage ------------------------------------------------------------------

/** One node of GET /api/v1/system/disks: a disk, a partition, an LVM volume… */
export interface DiskNode {
  name: string;
  path: string;
  kname: string;
  type: string;
  size_gb: number;
  fstype: string;
  mountpoint: string;
  label: string;
  model: string;
  vendor: string;
  serial: string;
  uuid: string;
  removable: boolean;
  readonly: boolean;
  used_gb: number | null;
  avail_gb: number | null;
  use_percent: number | null;
  /** Why the device must not be formatted ('' when free). */
  in_use: string;
  /** Holds /, /boot, /boot/efi or swap (itself or a child). */
  system: boolean;
  children: DiskNode[];
}

// --- Firewall -----------------------------------------------------------------

export interface UfwRule {
  num: number;
  /** "22/tcp", "443", "22/tcp (v6)", "Anywhere", "OpenSSH"… */
  to: string;
  /** ALLOW, DENY, REJECT or LIMIT. */
  action: string;
  /** IN, OUT, FWD or ''. */
  direction: string;
  /** "Anywhere", "Anywhere (v6)", "10.0.0.0/8"… */
  from_: string;
  is_v6: boolean;
  label: string;
}

export interface FirewallState {
  installed: boolean;
  enabled: boolean;
  rules: UfwRule[];
  /** `{incoming, outgoing, routed}` default policies; empty when unknown. */
  defaults: Partial<Record<'incoming' | 'outgoing' | 'routed', string>>;
  ssh_ports: number[];
  panel_port: number;
  /** The address this browser reaches the panel from. */
  client_ip: string;
}

// --- Processes ----------------------------------------------------------------

export interface Process {
  pid: number;
  name: string;
  /** Command line with secrets masked. */
  arguments: string;
  threads: number;
  user: string;
  ram_gb: number;
  cpu_percent: number;
  /** init, the panel itself and its ancestors, sshd, systemd…: cannot be signalled. */
  protected: boolean;
}

export type KillSignal = 'TERM' | 'KILL';
