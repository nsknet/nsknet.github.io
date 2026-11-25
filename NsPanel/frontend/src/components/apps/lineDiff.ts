/** A small line diff (longest common subsequence) for reviewing unit-file edits.
 *  Unit files are a few dozen lines, so the O(n·m) table is cheap; past
 *  MAX_CELLS it falls back to "everything removed, everything added". */

export interface DiffLine {
  op: 'same' | 'add' | 'del';
  text: string;
  /** 1-based line number in the old text (same/del). */
  oldNo: number | null;
  /** 1-based line number in the new text (same/add). */
  newNo: number | null;
}

/** A run of unchanged lines folded away in the review. */
export interface DiffGap {
  op: 'gap';
  count: number;
}

const MAX_CELLS = 4_000_000;

function splitLines(text: string): string[] {
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  // A trailing newline is not an extra empty line.
  if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop();
  return lines;
}

export function lineDiff(before: string, after: string): DiffLine[] {
  const a = splitLines(before);
  const b = splitLines(after);
  const n = a.length;
  const m = b.length;

  if (n * m > MAX_CELLS) {
    return [
      ...a.map((text, i) => ({ op: 'del' as const, text, oldNo: i + 1, newNo: null })),
      ...b.map((text, j) => ({ op: 'add' as const, text, oldNo: null, newNo: j + 1 })),
    ];
  }

  // lcs[i][j] = LCS length of a[i..] and b[j..], stored flat.
  const width = m + 1;
  const lcs = new Uint32Array((n + 1) * width);
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i * width + j] =
        a[i] === b[j] ? lcs[(i + 1) * width + j + 1] + 1 : Math.max(lcs[(i + 1) * width + j], lcs[i * width + j + 1]);
    }
  }

  const out: DiffLine[] = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      out.push({ op: 'same', text: a[i], oldNo: i + 1, newNo: j + 1 });
      i++;
      j++;
    } else if (lcs[(i + 1) * width + j] >= lcs[i * width + j + 1]) {
      out.push({ op: 'del', text: a[i], oldNo: i + 1, newNo: null });
      i++;
    } else {
      out.push({ op: 'add', text: b[j], oldNo: null, newNo: j + 1 });
      j++;
    }
  }
  for (; i < n; i++) out.push({ op: 'del', text: a[i], oldNo: i + 1, newNo: null });
  for (; j < m; j++) out.push({ op: 'add', text: b[j], oldNo: null, newNo: j + 1 });
  return out;
}

/** Keep `context` unchanged lines around each change; fold the rest into gaps. */
export function withContext(lines: DiffLine[], context = 3): (DiffLine | DiffGap)[] {
  const keep = new Array<boolean>(lines.length).fill(false);
  lines.forEach((line, index) => {
    if (line.op === 'same') return;
    for (let k = Math.max(0, index - context); k <= Math.min(lines.length - 1, index + context); k++) keep[k] = true;
  });

  const out: (DiffLine | DiffGap)[] = [];
  let folded = 0;
  lines.forEach((line, index) => {
    if (keep[index]) {
      if (folded) out.push({ op: 'gap', count: folded });
      folded = 0;
      out.push(line);
    } else {
      folded++;
    }
  });
  if (folded) out.push({ op: 'gap', count: folded });
  return out;
}

export function diffStats(lines: DiffLine[]): { added: number; removed: number } {
  return {
    added: lines.filter((line) => line.op === 'add').length,
    removed: lines.filter((line) => line.op === 'del').length,
  };
}
