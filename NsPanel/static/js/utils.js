const { computed, onMounted, onUpdated, ref } = Vue;

export function badgeCls(s) {
  const map = {
    running: 'ok', ok: 'ok', active: 'ok', installed: 'ok',
    stopped: 'muted', failed: 'danger', inactive: 'muted',
    'not installed': 'muted',
    enabled: 'info', disabled: 'muted',
  };
  return map[s] || 'muted';
}

// LIcon — wraps Lucide icons safely inside Vue's virtual DOM
// Props: name (required), is (optional inline style string for the svg)
export const LIcon = {
  name: 'LIcon',
  props: { name: { type: String, required: true }, is: { type: String, default: '' } },
  setup(props) {
    const el = ref(null);
    function hydrate() {
      if (!el.value || !window.lucide) return;
      const styleAttr = props.is ? ` style="${props.is}"` : '';
      el.value.innerHTML = `<i data-lucide="${props.name}"${styleAttr}></i>`;
      window.lucide.createIcons({ rootElement: el.value });
    }
    onMounted(hydrate);
    onUpdated(hydrate);
    return { el };
  },
  template: `<span ref="el" style="display:contents"></span>`,
};

// Btn — single source of truth for button styling (replaces .btn* CSS)
const BTN_BASE = 'inline-flex items-center justify-center gap-1.5 font-medium leading-none whitespace-nowrap rounded-lg border transition-[background-color,border-color,color,box-shadow,transform] duration-150 ease-out select-none active:scale-[0.97] disabled:opacity-50 disabled:pointer-events-none disabled:active:scale-100 focus-visible:outline-none focus-visible:shadow-[0_0_0_3px_color-mix(in_oklab,var(--accent)_30%,transparent)] [&_svg]:w-4 [&_svg]:h-4 [&_svg]:shrink-0';
const BTN_VARIANT = {
  default: 'bg-c-bg border-c-border text-c-tx shadow-sm hover:bg-c-hover hover:border-c-bstrong active:bg-c-subtle',
  primary: 'bg-c-accent border-transparent text-c-acfg shadow-sm hover:bg-c-achover hover:shadow-md active:shadow-sm',
  ghost:   'border-transparent text-c-tx2 hover:bg-c-hover hover:text-c-tx active:bg-c-subtle',
  danger:  'bg-c-bg border-c-border text-c-danger shadow-sm hover:bg-c-dngsoft hover:border-c-danger active:bg-c-dngsoft',
  success: 'bg-c-oksoft border-[color-mix(in_oklab,var(--ok)_20%,transparent)] text-c-ok shadow-sm hover:bg-[color-mix(in_oklab,var(--ok)_18%,transparent)] hover:border-[color-mix(in_oklab,var(--ok)_50%,transparent)] active:bg-c-oksoft',
  warn:    'bg-c-warnsoft border-[color-mix(in_oklab,var(--warn)_20%,transparent)] text-c-warn shadow-sm hover:bg-[color-mix(in_oklab,var(--warn)_18%,transparent)] hover:border-[color-mix(in_oklab,var(--warn)_50%,transparent)] active:bg-c-warnsoft',
  info:    'bg-c-infosoft border-[color-mix(in_oklab,var(--info)_20%,transparent)] text-c-info shadow-sm hover:bg-[color-mix(in_oklab,var(--info)_18%,transparent)] hover:border-[color-mix(in_oklab,var(--info)_50%,transparent)] active:bg-c-infosoft',
};
export const Btn = {
  name: 'Btn',
  props: {
    variant: { type: String, default: 'default' },
    sm:      { type: Boolean, default: false },
    square:  { type: Boolean, default: false },
  },
  setup(props) {
    const cls = computed(() => [
      BTN_BASE,
      BTN_VARIANT[props.variant] || BTN_VARIANT.default,
      props.sm ? 'h-7 text-xs-var' : 'h-9 text-sm-var',
      props.square
        ? (props.sm ? 'w-7' : 'w-9')
        : (props.sm ? 'px-2.5' : 'px-3.5'),
    ]);
    return { cls };
  },
  template: `<button :class="cls"><slot /></button>`,
};

// Badge — soft pill (replaces .badge* CSS)
const BADGE_BASE = 'inline-flex items-center gap-1.5 px-2 h-[22px] rounded-full text-xs-var font-medium tabular-nums border whitespace-nowrap shrink-0';
const BADGE_TONE = {
  ok:      'bg-c-oksoft text-c-ok border-transparent',
  warn:    'bg-c-warnsoft text-c-warn border-transparent',
  danger:  'bg-c-dngsoft text-c-danger border-transparent',
  info:    'bg-c-infosoft text-c-info border-transparent',
  accent:  'bg-c-acsoft text-c-accent border-transparent',
  muted:   'bg-c-muted text-c-tx2 border-transparent',
  neutral: 'bg-c-subtle text-c-tx2 border-c-border',
};
export const Badge = {
  name: 'Badge',
  props: {
    tone: { type: String, default: 'neutral' },
    dot:  { type: Boolean, default: false },
  },
  setup(props) {
    const cls = computed(() => [BADGE_BASE, BADGE_TONE[props.tone] || BADGE_TONE.neutral]);
    const dotCls = computed(() => [
      'w-1.5 h-1.5 rounded-full',
      props.tone === 'neutral' || props.tone === 'muted' ? 'bg-c-tx3' : 'bg-current',
      props.tone === 'ok' ? 'shadow-[0_0_0_3px_var(--ok-soft)]' : '',
    ]);
    return { cls, dotCls };
  },
  template: `<span :class="cls"><span v-if="dot" :class="dotCls"></span><slot /></span>`,
};

export const StatusBadge = {
  name: 'StatusBadge',
  props: { status: { type: String, default: '' } },
  setup(props) {
    const tone = computed(() => badgeCls(props.status));
    return { tone, label: computed(() => props.status || '') };
  },
  template: `<badge :tone="tone" dot>{{ label }}</badge>`,
};

const TYPE_CHIP_BASE = 'inline-flex items-center gap-1.5 px-2 py-0.5 rounded-[5px] text-xs-var mono font-medium border';
const TYPE_CHIP = {
  dotnet: { c: 'text-[#8b5cf6] bg-[color-mix(in_oklab,#8b5cf6_10%,transparent)] border-transparent', l: '.NET' },
  proxy:  { c: 'text-[#2563eb] bg-[color-mix(in_oklab,#2563eb_10%,transparent)] border-transparent', l: 'proxy' },
  static: { c: 'bg-c-subtle text-c-tx2 border-c-border', l: 'static' },
};
export const TypeChip = {
  name: 'TypeChip',
  props: { type: { type: String, default: '' } },
  setup(props) {
    const cfg = computed(() => TYPE_CHIP[props.type] || { c: 'bg-c-subtle text-c-tx2 border-c-border', l: props.type });
    return { cfg, base: TYPE_CHIP_BASE };
  },
  template: `<span :class="base + ' ' + cfg.c">{{ cfg.l }}</span>`,
};

export function escapeHtml(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

export function ansiToHtml(text) {
  let escaped = escapeHtml(text);
  const ansiRegex = /\x1b\[([0-9;]*)m/g;
  let html = '';
  let lastIndex = 0;
  let activeSpans = 0;

  let match;
  while ((match = ansiRegex.exec(escaped)) !== null) {
    html += escaped.substring(lastIndex, match.index);
    lastIndex = ansiRegex.lastIndex;

    const paramStr = match[1];
    if (!paramStr || paramStr === '0') {
      html += '</span>'.repeat(activeSpans);
      activeSpans = 0;
      continue;
    }

    const codes = paramStr.split(';').map(x => parseInt(x, 10));
    let classes = [];
    
    for (const code of codes) {
      if (code === 0) {
        html += '</span>'.repeat(activeSpans);
        activeSpans = 0;
      } else if (code === 1) {
        classes.push('font-bold');
      } else if (code === 2) {
        classes.push('dim');
      } else if (code === 3) {
        classes.push('italic');
      } else if (code === 4) {
        classes.push('underline');
      } else if (code === 30) {
        classes.push('text-black');
      } else if (code === 31) {
        classes.push('err');
      } else if (code === 32) {
        classes.push('ok');
      } else if (code === 33) {
        classes.push('warn');
      } else if (code === 34) {
        classes.push('info');
      } else if (code === 35) {
        classes.push('text-purple-400');
      } else if (code === 36) {
        classes.push('cmd');
      } else if (code === 37) {
        classes.push('text-gray-200');
      } else if (code === 90) {
        classes.push('dim');
      } else if (code === 91) {
        classes.push('err');
      } else if (code === 92) {
        classes.push('ok');
      } else if (code === 93) {
        classes.push('warn');
      } else if (code === 94) {
        classes.push('text-blue-400');
      } else if (code === 95) {
        classes.push('text-purple-300');
      } else if (code === 96) {
        classes.push('cmd');
      } else if (code === 97) {
        classes.push('text-white');
      }
    }

    if (classes.length > 0) {
      html += `<span class="${classes.join(' ')}">`;
      activeSpans++;
    }
  }

  html += escaped.substring(lastIndex);
  html += '</span>'.repeat(activeSpans);
  return html;
}

