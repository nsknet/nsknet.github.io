/** Render the ANSI colour codes the job runner passes through into terminal spans. */

export function escapeHtml(text: unknown): string {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

// SGR code → the class names defined for `.term` in theme.css.
const SGR_CLASS: Record<number, string> = {
  1: 'font-bold',
  2: 'dim',
  3: 'italic',
  4: 'underline',
  30: 'text-black',
  31: 'err',
  32: 'ok',
  33: 'warn',
  34: 'info',
  35: 'text-purple-400',
  36: 'cmd',
  37: 'text-gray-200',
  90: 'dim',
  91: 'err',
  92: 'ok',
  93: 'warn',
  94: 'text-blue-400',
  95: 'text-purple-300',
  96: 'cmd',
  97: 'text-white',
};

export function ansiToHtml(text: string): string {
  const escaped = escapeHtml(text);
  const pattern = /\x1b\[([0-9;]*)m/g;
  let html = '';
  let lastIndex = 0;
  let openSpans = 0;
  let match: RegExpExecArray | null;

  while ((match = pattern.exec(escaped)) !== null) {
    html += escaped.slice(lastIndex, match.index);
    lastIndex = pattern.lastIndex;

    const params = match[1];
    if (!params || params === '0') {
      html += '</span>'.repeat(openSpans);
      openSpans = 0;
      continue;
    }

    const classes: string[] = [];
    for (const code of params.split(';').map((value) => Number.parseInt(value, 10))) {
      if (code === 0) {
        html += '</span>'.repeat(openSpans);
        openSpans = 0;
      } else if (SGR_CLASS[code]) {
        classes.push(SGR_CLASS[code]);
      }
    }

    if (classes.length) {
      html += `<span class="${classes.join(' ')}">`;
      openSpans += 1;
    }
  }

  return html + escaped.slice(lastIndex) + '</span>'.repeat(openSpans);
}
