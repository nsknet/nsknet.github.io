import { describe, expect, it } from 'vitest';

import type { FirewallState, UfwRule } from '@/api/system';

import { blockingHit, coversPort, portSpecError, protectionOf, sourceCovers } from './firewall';

function rule(num: number, to: string, from_ = 'Anywhere', action = 'ALLOW', is_v6 = false): UfwRule {
  return { num, to, action, direction: 'IN', from_, is_v6, label: '' };
}

function state(rules: UfwRule[], overrides: Partial<FirewallState> = {}): FirewallState {
  return {
    installed: true,
    enabled: true,
    rules,
    defaults: { incoming: 'deny' },
    ssh_ports: [2222],
    panel_port: 7778,
    client_ip: '192.168.1.20',
    ...overrides,
  };
}

describe('firewall lockout protection', () => {
  it('protects rules on the real SSH port and the panel port', () => {
    const s = state([rule(1, '2222/tcp'), rule(2, '7778/tcp', '192.168.0.0/16'), rule(3, '80/tcp')]);
    expect(protectionOf(s.rules[0], s)).toMatchObject({ port: 2222, what: 'SSH' });
    expect(protectionOf(s.rules[1], s)).toMatchObject({ port: 7778, what: 'this panel' });
    expect(protectionOf(s.rules[2], s)).toBeNull();
  });

  it('does not protect port 22 when SSH listens elsewhere', () => {
    const s = state([rule(1, '22/tcp')]);
    expect(protectionOf(s.rules[0], s)).toBeNull();
  });

  it('protects port ranges that include an access port', () => {
    const s = state([rule(1, '2000:3000/tcp')]);
    expect(protectionOf(s.rules[0], s)?.port).toBe(2222);
  });

  it('protects the OpenSSH application profile', () => {
    const s = state([rule(1, 'OpenSSH')]);
    expect(protectionOf(s.rules[0], s)).toMatchObject({ what: 'SSH', port: 2222 });
  });

  it('protects an all-ports allow only when it is the sole way in for this browser', () => {
    const lan = rule(1, 'Anywhere', '192.168.1.0/24');
    const alone = state([lan]);
    expect(protectionOf(lan, alone)).not.toBeNull();
    const withSsh = state([lan, rule(2, '2222/tcp'), rule(3, '7778/tcp')]);
    expect(protectionOf(lan, withSsh)).toBeNull();
    const otherNet = state([rule(1, 'Anywhere', '10.0.0.0/8')]);
    expect(protectionOf(otherNet.rules[0], otherNet)).toBeNull();
  });

  it('flags blocking rules on access ports only', () => {
    const s = state([]);
    expect(blockingHit(2222, 'DENY', s)?.what).toBe('SSH');
    expect(blockingHit(7778, 'LIMIT', s)?.what).toBe('this panel');
    expect(blockingHit(2222, 'ALLOW', s)).toBeNull();
    expect(blockingHit(80, 'DENY', s)).toBeNull();
  });
});

describe('firewall parsing', () => {
  it('matches sources by CIDR, erring on the side of caution', () => {
    expect(sourceCovers('192.168.0.0/16', '192.168.1.20')).toBe(true);
    expect(sourceCovers('10.0.0.0/8', '192.168.1.20')).toBe(false);
    expect(sourceCovers('Anywhere (v6)', '192.168.1.20')).toBe(true);
    expect(sourceCovers('2001:db8::/32', '192.168.1.20')).toBe(true);
  });

  it('reads port lists and ranges', () => {
    expect(coversPort('80,443/tcp', 443)).toBe(true);
    expect(coversPort('8000:8100/tcp', 8080)).toBe(true);
    expect(coversPort('8000:8100/tcp', 80)).toBe(false);
    expect(coversPort('Anywhere', 22)).toBe(true);
  });

  it('validates the add-rule port like the backend', () => {
    expect(portSpecError('443/tcp')).toBe('');
    expect(portSpecError('70000')).not.toBe('');
    expect(portSpecError('80:90')).not.toBe('');
  });
});
