import { describe, expect, it } from 'vitest';

import * as v from './validate';

describe('validate', () => {
  it('accepts IPv4 and rejects junk', () => {
    expect(v.ipv4('192.168.1.10')).toBe('');
    expect(v.ipv4('256.1.1.1')).not.toBe('');
    expect(v.ipv4('10.0.0')).not.toBe('');
  });

  it('needs a prefix for CIDR', () => {
    expect(v.cidr('10.0.0.0/8')).toBe('');
    expect(v.cidr('10.0.0.0')).not.toBe('');
    expect(v.cidr('10.0.0.0/33')).not.toBe('');
  });

  it('checks the gateway is on the same subnet', () => {
    expect(v.sameSubnet('192.168.1.50/24', '192.168.1.1')).toBe(true);
    expect(v.sameSubnet('192.168.1.50/24', '192.168.2.1')).toBe(false);
    expect(v.sameSubnet('10.0.0.5/8', '10.200.0.1')).toBe(true);
    expect(v.sameSubnet('10.0.0.5', '10.0.0.1')).toBe(false);
  });

  it('bounds ports', () => {
    expect(v.port('8080')).toBe('');
    expect(v.port('80', { min: 1024 })).not.toBe('');
    expect(v.port('70000')).not.toBe('');
    expect(v.port('abc')).not.toBe('');
  });

  it('follows the backend name rule', () => {
    expect(v.name('my-app_1.0')).toBe('');
    expect(v.name('-rf')).not.toBe('');
    expect(v.name('a..b')).not.toBe('');
    expect(v.name('')).not.toBe('');
  });

  it('checks domains and optional e-mails', () => {
    expect(v.domain('app.example.com')).toBe('');
    expect(v.domain('localhost')).not.toBe('');
    expect(v.email('')).toBe('');
    expect(v.email('ops@example.com')).toBe('');
    expect(v.email('ops@')).not.toBe('');
  });

  it('returns the first failing message', () => {
    expect(v.first('', 'b', 'c')).toBe('b');
    expect(v.first('', '')).toBe('');
  });
});
