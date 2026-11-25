import { describe, expect, it } from 'vitest';

import { buildApps, fmtCpu, fmtMem, parseModified } from './appRows';
import { diffStats, lineDiff, withContext } from './lineDiff';

describe('lineDiff', () => {
  it('marks unchanged, removed and added lines', () => {
    const lines = lineDiff('a\nb\nc\n', 'a\nB\nc\nd\n');
    expect(lines.map((line) => `${line.op}:${line.text}`)).toEqual(['same:a', 'del:b', 'add:B', 'same:c', 'add:d']);
    expect(diffStats(lines)).toEqual({ added: 2, removed: 1 });
  });

  it('reports no changes for identical text', () => {
    expect(diffStats(lineDiff('x\ny', 'x\ny\n'))).toEqual({ added: 0, removed: 0 });
  });

  it('folds long unchanged runs into gaps', () => {
    const before = Array.from({ length: 20 }, (_, i) => `line ${i}`).join('\n');
    const after = before.replace('line 10', 'changed');
    const folded = withContext(lineDiff(before, after), 2);
    expect(folded[0]).toEqual({ op: 'gap', count: 8 });
    expect(folded[folded.length - 1]).toEqual({ op: 'gap', count: 7 });
  });
});

describe('appRows', () => {
  it('parses server timestamps', () => {
    expect(parseModified('2026-11-26 10:30')).toBe(new Date(2026, 10, 26, 10, 30).getTime());
    expect(parseModified('')).toBe(0);
  });

  it('shows a dash instead of zero for stopped apps', () => {
    expect(fmtMem(0, false)).toBe('—');
    expect(fmtCpu(0, false)).toBe('—');
    expect(fmtCpu(2.345, true)).toBe('2.3%');
  });

  it('does not list a .NET site unit twice', () => {
    const site = {
      slug: 'api', name: 'api', type: 'dotnet', access: ':8080', accessKind: 'port', accessValue: '8080',
      status: 'running', pid: 1, autostart: 'enabled', mem: 50, cpu: 1, modified: '', dll: 'Api.dll',
      internalPort: 5000, env: 'Production', created: '', configPath: '', unitPath: '', webRoot: '', logDir: '',
      proxyTarget: null,
    };
    const service = {
      name: 'api', desc: '', status: 'active', autostart: 'enabled', mem: 50, cpu: 1, pid: 1, modified: '',
      cmd: '', path: '', content: '', workingDir: null, user: null, restart: null, restartSec: null,
      syslogId: null, envVars: [], tunnel: null, isTunnel: false,
    };
    const rows = buildApps([site], [service, { ...service, name: 'worker', status: 'inactive' }]);
    expect(rows.map((row) => row.key)).toEqual(['site:api', 'service:worker']);
    expect(rows[1].mem).toBeNull();
  });
});
