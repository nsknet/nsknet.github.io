/** Firewall rules: port parsing, source matching and lockout protection.
 *
 * A rule is "protected" when deleting it (or adding a blocking rule next to it)
 * can cut the operator off: it targets an SSH port or the panel's port, or it
 * is an all-ports allow covering this browser's address and is the only rule
 * that lets this browser reach one of those ports.
 */
import type { FirewallState, UfwRule } from '@/api/system';
import { IPV4 } from '@/utils/validate';

export const ACTIONS = ['ALLOW', 'DENY', 'REJECT', 'LIMIT'] as const;
export type RuleAction = (typeof ACTIONS)[number];

/** UFW_PORT in core/validators.py: one port, optionally with a protocol. */
const PORT_SPEC = /^(\d{1,5})(\/(tcp|udp))?$/i;

/** Error message for the add-rule port field, or ''. */
export function portSpecError(value: string): string {
  const text = value.trim();
  if (!text) return 'Enter a port, e.g. 443 or 443/tcp.';
  const match = text.match(PORT_SPEC);
  if (!match) return 'Use a port number, optionally with tcp or udp: 443 or 443/tcp.';
  const port = Number(match[1]);
  return port >= 1 && port <= 65535 ? '' : 'Use a port between 1 and 65535.';
}

export function portOfSpec(value: string): number | null {
  const match = value.trim().match(PORT_SPEC);
  return match ? Number(match[1]) : null;
}

/** The ports a rule's `to` covers: 'all' for "Anywhere", a list for
 *  "22/tcp", "80,443/tcp" or "8000:8100/tcp", [] for named apps we cannot read. */
export function portsOf(to: string): 'all' | { from: number; to: number }[] {
  const spec = to.replace(/\(v6\)/i, '').trim();
  if (/^anywhere$/i.test(spec) || spec === '') return 'all';
  // Strip a destination address ("10.0.0.1 22/tcp") and the protocol.
  const portPart = spec.split(/\s+/).pop()!.split('/')[0];
  const ranges: { from: number; to: number }[] = [];
  for (const piece of portPart.split(',')) {
    const range = piece.match(/^(\d+)(?::(\d+))?$/);
    if (range) ranges.push({ from: Number(range[1]), to: Number(range[2] ?? range[1]) });
  }
  return ranges;
}

export function coversPort(to: string, port: number): boolean {
  const ports = portsOf(to);
  return ports === 'all' || ports.some((range) => port >= range.from && port <= range.to);
}

function ipv4ToInt(ip: string): number {
  return ip.split('.').reduce((acc, part) => (acc << 8) + Number(part), 0) >>> 0;
}

/** Does the rule's source ("Anywhere", an IP, a CIDR) include `ip`?
 *  When it cannot tell (IPv6 ranges, odd formats) it answers true, which errs
 *  on the side of protecting the rule. */
export function sourceCovers(from: string, ip: string): boolean {
  const source = from.replace(/\(v6\)/i, '').trim();
  if (!ip || /^any(where)?$/i.test(source) || source === '') return true;
  const client = ip.replace(/^::ffff:/i, '');
  const [network, prefixText] = source.split('/');
  if (!IPV4.test(client) || !IPV4.test(network)) return true;
  const prefix = prefixText === undefined ? 32 : Number(prefixText);
  if (!Number.isInteger(prefix) || prefix < 0 || prefix > 32) return true;
  const mask = prefix === 0 ? 0 : (~0 << (32 - prefix)) >>> 0;
  return (ipv4ToInt(network) & mask) === (ipv4ToInt(client) & mask);
}

function isIpv6(ip: string): boolean {
  return ip.includes(':') && !/^::ffff:\d/i.test(ip);
}

/** Lets traffic in (LIMIT still allows, with rate limiting). */
function opens(rule: UfwRule): boolean {
  const action = rule.action.toUpperCase();
  return (action === 'ALLOW' || action === 'LIMIT') && rule.direction.toUpperCase() !== 'OUT';
}

export interface AccessPort {
  port: number;
  /** "SSH" or "this panel". */
  what: string;
}

export function accessPorts(state: FirewallState): AccessPort[] {
  const ports: AccessPort[] = state.ssh_ports.map((port) => ({ port, what: 'SSH' }));
  if (state.panel_port) ports.push({ port: state.panel_port, what: 'this panel' });
  return ports;
}

export interface Protection {
  /** The port to type to confirm. */
  port: number;
  /** "SSH" / "this panel" / "SSH and this panel". */
  what: string;
  reason: string;
}

function joinWhat(ports: AccessPort[]): string {
  return [...new Set(ports.map((p) => p.what))].join(' and ');
}

/** Why deleting this rule could lock the operator out, or null. */
export function protectionOf(rule: UfwRule, state: FirewallState): Protection | null {
  const access = accessPorts(state);
  const ports = portsOf(rule.to);

  // An application profile UFW resolves itself ("OpenSSH", "OpenSSH (v6)"):
  // its port is not in the rule text, so recognise SSH by name.
  if (ports !== 'all' && !ports.length && /ssh/i.test(rule.to)) {
    const ssh = access.filter((a) => a.what === 'SSH');
    if (ssh.length) {
      return {
        port: ssh[0].port,
        what: 'SSH',
        reason: `The ${rule.to.replace(/\(v6\)/i, '').trim()} profile opens SSH.`,
      };
    }
  }

  // A rule that names an SSH or panel port, whatever its action.
  if (ports !== 'all') {
    const hit = access.filter((a) => ports.some((r) => a.port >= r.from && a.port <= r.to));
    if (hit.length) {
      return {
        port: hit[0].port,
        what: joinWhat(hit),
        reason: `Applies to the ${joinWhat(hit)} port (${hit.map((h) => h.port).join(', ')}).`,
      };
    }
    return null;
  }

  // An all-ports allow that is this browser's only way in to an access port.
  if (!opens(rule) || !sourceCovers(rule.from_, state.client_ip)) return null;
  if (rule.is_v6 !== isIpv6(state.client_ip)) return null;
  const sole = access.filter(
    (a) =>
      !state.rules.some(
        (other) =>
          other.num !== rule.num &&
          other.is_v6 === rule.is_v6 &&
          opens(other) &&
          coversPort(other.to, a.port) &&
          sourceCovers(other.from_, state.client_ip),
      ),
  );
  if (!sole.length) return null;
  return {
    port: sole[0].port,
    what: joinWhat(sole),
    reason: `The only rule letting ${state.client_ip} reach ${joinWhat(sole)}.`,
  };
}

/** An access port a new DENY/REJECT/LIMIT rule would hit, or null. */
export function blockingHit(port: number | null, action: string, state: FirewallState): AccessPort | null {
  if (port === null || action.toUpperCase() === 'ALLOW') return null;
  return accessPorts(state).find((a) => a.port === port) ?? null;
}
