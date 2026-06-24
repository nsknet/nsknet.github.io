import { appState, addToast } from './store.js';
import { escapeHtml, ansiToHtml } from './utils.js';

const { ref, computed, onMounted, onUnmounted, nextTick, watch } = Vue;

// ============ Live Output Overlay ============
export const OverlayModal = {
  name: 'OverlayModal',
  props: { overlay: { type: Object, required: true } },
  emits: ['close'],
  setup(props, { emit }) {
    const termEl      = ref(null);
    const lines       = ref([]);
    const statusPhase = ref('running'); // 'running' | 'done' | 'failed'
    const elapsed     = ref('0.0s');
    const jobId       = props.overlay.jobId || 'job ' + Math.random().toString(36).slice(2, 10);
    const exitCode    = ref(0);
    const wordWrap    = ref(true);

    let pendingTimeout = null;
    let elapsedTimer   = null;
    let evSource       = null;

    function dismiss() {
      clearTimeout(pendingTimeout);
      clearInterval(elapsedTimer);
      if (evSource) evSource.close();
      emit('close');
    }

    function onKeydown(e) { if (e.key === 'Escape') dismiss(); }

    function scrollTerm() {
      nextTick(() => { if (termEl.value) termEl.value.scrollTop = termEl.value.scrollHeight; });
    }

    function copyLogs() {
      const text = lines.value.map(l => l.text).join('\n');
      navigator.clipboard.writeText(text)
        .then(() => addToast({ t: 'Logs copied to clipboard', k: 'ok' }))
        .catch(err => addToast({ t: 'Failed to copy logs', d: err.message, k: 'danger' }));
    }

    onMounted(() => {
      document.addEventListener('keydown', onKeydown);

      const start = performance.now();
      elapsedTimer = setInterval(() => {
        elapsed.value = ((performance.now() - start) / 1000).toFixed(1) + 's';
      }, 100);

      if (props.overlay.jobId) {
        // Real-time backend SSE mode
        evSource = new EventSource('/stream/' + props.overlay.jobId);
        
        evSource.addEventListener('line', (e) => {
          lines.value.push({
            cls: '',
            text: e.data,
            html: ansiToHtml(e.data)
          });
          scrollTerm();
        });

        evSource.addEventListener('error', (e) => {
          lines.value.push({ cls: 'text-c-danger font-medium', text: '\n[SSE Connection Error / Interrupted]' });
          scrollTerm();
          statusPhase.value = 'failed';
          exitCode.value = 1;
          clearInterval(elapsedTimer);
          evSource.close();
        });

        evSource.addEventListener('done', (e) => {
          const code = parseInt(e.data, 10);
          exitCode.value = isNaN(code) ? 0 : code;
          statusPhase.value = (exitCode.value === 0) ? 'done' : 'failed';
          clearInterval(elapsedTimer);
          evSource.close();
          if (props.overlay.onDone) nextTick(() => props.overlay.onDone());
        });
      }
    });

    onUnmounted(() => {
      document.removeEventListener('keydown', onKeydown);
      clearTimeout(pendingTimeout);
      clearInterval(elapsedTimer);
      if (evSource) evSource.close();
    });

    return { termEl, lines, statusPhase, elapsed, jobId, exitCode, dismiss, escapeHtml, wordWrap, copyLogs };
  },
  template: `
    <div class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade" @click.self="dismiss">
      <div class="flex flex-col w-full max-w-4xl max-h-[80vh] bg-c-bg border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop" role="dialog" aria-modal="true">
        <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
          <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center"><l-icon name="terminal" is="width:14px;height:14px" /></div>
          <div>
            <div class="font-semibold text-sm-var">{{ overlay.title }}</div>
            <div class="text-xs-var text-c-tx2 mono">{{ jobId }}</div>
          </div>
          <div class="ml-auto flex items-center gap-2 mr-2">
            <btn variant="ghost" sm @click="copyLogs" class="text-xs-var h-7 px-2">
              <l-icon name="copy" is="width:13px;height:13px;margin-right:4px;" /> Copy
            </btn>
            <label class="flex items-center gap-1.5 text-xs-var cursor-pointer select-none px-2 h-7 bg-c-subtle hover:bg-c-hover rounded-theme border border-c-border text-c-tx2 hover:text-c-tx">
              <input type="checkbox" v-model="wordWrap" class="w-3 h-3 accent-c-accent rounded" />
              <span>Word Wrap</span>
            </label>
          </div>
          <btn variant="ghost" sm square @click="dismiss" aria-label="Close">
            <l-icon name="x" />
          </btn>
        </div>
        <div :class="['term', wordWrap ? 'whitespace-pre-wrap' : 'whitespace-pre overflow-x-auto']" ref="termEl" style="word-break: break-all;">
          <span v-for="(ln, i) in lines" :key="i" :class="['ln', ln.cls]" v-html="ln.html || escapeHtml(ln.text)"></span>
        </div>
        <div class="flex items-center gap-2.5 py-2.5 px-4 border-t border-c-border bg-c-elev text-xs-var text-c-tx2">
          <template v-if="statusPhase === 'running'">
            <span class="w-3 h-3 rounded-full border-[1.5px] border-c-bstrong border-t-c-accent animate-spin"></span>
            <span>running…</span>
          </template>
          <template v-else-if="statusPhase === 'done'">
            <l-icon name="check-circle-2" is="width:14px;height:14px;color:var(--ok)" />
            <span class="text-c-ok font-medium">Success</span>
            <span class="text-c-tx2">· exit 0</span>
          </template>
          <template v-else>
            <l-icon name="x-circle" is="width:14px;height:14px;color:var(--danger)" />
            <span class="text-c-danger font-medium">Failed</span>
            <span class="text-c-tx2">· exit {{ exitCode }}</span>
          </template>
          <span class="ml-auto mono">{{ elapsed }}</span>
        </div>
      </div>
    </div>
  `,
};

// ============ Confirm Dialog ============
export const ConfirmDialog = {
  name: 'ConfirmDialog',
  props: { confirm: { type: Object, required: true } },
  emits: ['close'],
  setup(props, { emit }) {
    function dismiss() { emit('close'); }
    function onYes() { dismiss(); if (props.confirm.onYes) props.confirm.onYes(); }
    function onKeydown(e) { if (e.key === 'Escape') dismiss(); }
    onMounted(() => document.addEventListener('keydown', onKeydown));
    onUnmounted(() => document.removeEventListener('keydown', onKeydown));
    return { dismiss, onYes };
  },
  template: `
    <div class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade" @click.self="dismiss">
      <div class="max-w-[420px] bg-c-bg border border-c-border rounded-theme-lg shadow-lg p-5">
        <div class="w-10 h-10 rounded-[10px] bg-c-dngsoft text-c-danger grid place-items-center mb-3.5"><l-icon name="alert-triangle" is="width:20px;height:20px" /></div>
        <h3 class="m-0 mb-1.5 text-base font-semibold tracking-[-0.01em]">{{ confirm.title }}</h3>
        <p class="m-0 mb-4 text-c-tx2 text-sm-var">{{ confirm.body }}</p>
        <div class="flex justify-end gap-1.5">
          <btn @click="dismiss">Cancel</btn>
          <btn variant="primary" @click="onYes">Continue</btn>
        </div>
      </div>
    </div>
  `,
};

// ============ Pre-install Dialog (password + firewall scope) ============
const SUBNET_OPTIONS = [
  { cidr: '10.0.0.0/8',     label: 'Class A — private',  note: '10.0.0.0/8' },
  { cidr: '172.16.0.0/12',  label: 'Class B — private',  note: '172.16.0.0/12' },
  { cidr: '192.168.0.0/16', label: 'Class C — private',  note: '192.168.0.0/16' },
  { cidr: '127.0.0.0/8',    label: 'Loopback (local)',   note: '127.0.0.0/8' },
  { cidr: '0.0.0.0/0',      label: 'Any IP — public',    note: '0.0.0.0/0' },
];

function genPassword(len = 24) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  const arr = new Uint32Array(len);
  (window.crypto || window.msCrypto).getRandomValues(arr);
  let out = '';
  for (let i = 0; i < len; i++) out += chars[arr[i] % chars.length];
  return out;
}

export const InstallDialog = {
  name: 'InstallDialog',
  props: { dialog: { type: Object, required: true } },
  emits: ['close'],
  setup(props, { emit }) {
    const tool = props.dialog.tool;
    const isPasswordMode = (props.dialog.mode || 'install') === 'password';
    const needsPassword = isPasswordMode || !!tool.requiresPassword;
    const ports = isPasswordMode ? [] : (tool.firewallPorts || []);
    const needsPorts = ports.length > 0;

    // Module-declared custom params (string / number / checkbox / select).
    const params = isPasswordMode ? [] : (tool.installParams || []);
    const needsParams = params.length > 0;
    const paramValues = ref(Object.fromEntries(params.map((p) => {
      if (p.type === 'checkbox') return [p.name, p.default === true || p.default === 'true'];
      if (p.default !== undefined && p.default !== null && p.default !== '') return [p.name, p.default];
      if (p.type === 'select' && p.options && p.options.length) return [p.name, p.options[0].value];
      return [p.name, ''];
    })));

    const password = ref(needsPassword ? genPassword() : '');
    const showPassword = ref(true);
    // Default scope mirrors the previous behaviour: private subnets + loopback.
    const selected = ref({
      '10.0.0.0/8': true,
      '172.16.0.0/12': true,
      '192.168.0.0/16': true,
      '127.0.0.0/8': true,
      '0.0.0.0/0': false,
    });

    function dismiss() { emit('close'); }
    function onKeydown(e) { if (e.key === 'Escape') dismiss(); }
    onMounted(() => { document.addEventListener('keydown', onKeydown); nextTick(() => window.lucide?.createIcons()); });
    onUnmounted(() => document.removeEventListener('keydown', onKeydown));

    function regenerate() { password.value = genPassword(); }

    function copyPassword() {
      navigator.clipboard.writeText(password.value)
        .then(() => addToast({ t: 'Password copied', k: 'ok' }))
        .catch(() => addToast({ t: 'Could not copy', k: 'warn' }));
    }

    function toggle(cidr) {
      const next = !selected.value[cidr];
      if (cidr === '0.0.0.0/0' && next) {
        // "Any" supersedes everything else — clear the narrower scopes.
        for (const k of Object.keys(selected.value)) selected.value[k] = false;
        selected.value['0.0.0.0/0'] = true;
      } else {
        selected.value[cidr] = next;
        if (next) selected.value['0.0.0.0/0'] = false;
      }
    }

    const chosenSubnets = computed(() =>
      SUBNET_OPTIONS.map((o) => o.cidr).filter((c) => selected.value[c])
    );

    function confirm() {
      if (needsPassword && password.value.trim().length < 8) {
        addToast({ t: 'Password too short', d: 'Use at least 8 characters.', k: 'warn' });
        return;
      }
      if (needsPorts && chosenSubnets.value.length === 0) {
        addToast({ t: 'Select a firewall scope', d: 'Pick at least one subnet.', k: 'warn' });
        return;
      }
      const payload = {};
      if (needsPassword) payload.db_password = password.value.trim();
      if (needsPorts) payload.allowed_subnets = chosenSubnets.value.join(',');
      for (const p of params) {
        const v = paramValues.value[p.name];
        payload[p.name] = p.type === 'checkbox' ? (v ? 'true' : 'false') : v;
      }
      dismiss();
      props.dialog.onConfirm(payload);
    }

    return {
      tool, isPasswordMode, needsPassword, needsPorts, ports, password, showPassword, selected,
      params, needsParams, paramValues,
      SUBNET_OPTIONS, dismiss, regenerate, copyPassword, toggle, confirm,
    };
  },
  template: `
    <div class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade" @click.self="dismiss">
      <div class="w-full max-w-[460px] bg-c-bg border border-c-border rounded-theme-lg shadow-lg p-5 animate-pop" role="dialog" aria-modal="true">
        <div class="flex items-center gap-3 mb-4">
          <div class="w-10 h-10 rounded-[10px] bg-c-acsoft text-c-accent grid place-items-center shrink-0"><l-icon :name="isPasswordMode ? 'key-round' : 'download'" is="width:20px;height:20px" /></div>
          <div class="min-w-0">
            <h3 class="m-0 text-base font-semibold tracking-[-0.01em] truncate">{{ isPasswordMode ? 'Change ' + tool.name + ' password' : 'Install ' + tool.name }}</h3>
            <p class="m-0 text-c-tx2 text-xs-var">{{ isPasswordMode ? 'Set a new admin password — the service and its credentials file are updated.' : 'Configure credentials and network access before installing.' }}</p>
          </div>
        </div>

        <!-- Password -->
        <div v-if="needsPassword" class="mb-4">
          <label class="flex items-center justify-between text-xs-var text-c-tx2 mb-1.5">
            <span class="uppercase tracking-[0.05em] text-[10px] font-medium">Admin / DB password</span>
          </label>
          <div class="flex items-center gap-1.5">
            <div class="relative flex-1">
              <input :type="showPassword ? 'text' : 'password'" class="input mono w-full pr-8" v-model="password" autocomplete="new-password" spellcheck="false" />
              <button type="button" class="absolute right-1.5 top-1/2 -translate-y-1/2 text-c-tx3 hover:text-c-tx p-1" @click="showPassword = !showPassword" :aria-label="showPassword ? 'Hide' : 'Show'">
                <l-icon :name="showPassword ? 'eye-off' : 'eye'" is="width:14px;height:14px" />
              </button>
            </div>
            <btn sm square @click="regenerate" title="Generate new password"><l-icon name="refresh-cw" /></btn>
            <btn sm square @click="copyPassword" title="Copy password"><l-icon name="copy" /></btn>
          </div>
          <div class="text-[11px] text-c-tx3 mt-1.5">Auto-generated. Click <l-icon name="refresh-cw" is="width:11px;height:11px;display:inline" /> to regenerate. Saved to the tool's credentials file.</div>
        </div>

        <!-- Custom install params (edition dropdown, etc.) -->
        <div v-if="needsParams" class="mb-4 flex flex-col gap-3">
          <div v-for="p in params" :key="p.name">
            <label v-if="p.type !== 'checkbox'" class="block text-xs-var text-c-tx2 mb-1.5">
              <span class="uppercase tracking-[0.05em] text-[10px] font-medium">{{ p.label }}</span>
            </label>
            <select v-if="p.type === 'select'" class="input w-full" v-model="paramValues[p.name]">
              <option v-for="o in p.options" :key="o.value" :value="o.value">{{ o.label }}</option>
            </select>
            <label v-else-if="p.type === 'checkbox'" class="flex items-center gap-2.5 cursor-pointer select-none">
              <input type="checkbox" class="w-3.5 h-3.5 accent-c-accent rounded shrink-0" v-model="paramValues[p.name]" />
              <span class="text-sm-var text-c-tx">{{ p.label }}</span>
            </label>
            <input v-else :type="p.type === 'number' ? 'number' : 'text'" class="input w-full"
              v-model="paramValues[p.name]" :min="p.min" :max="p.max" :placeholder="p.placeholder || ''" />
            <div v-if="p.help && p.type !== 'checkbox'" class="text-[11px] text-c-tx3 mt-1.5">{{ p.help }}</div>
          </div>
        </div>

        <!-- Firewall scope -->
        <div v-if="needsPorts" class="mb-4">
          <label class="block text-xs-var text-c-tx2 mb-1.5">
            <span class="uppercase tracking-[0.05em] text-[10px] font-medium">Open port{{ ports.length > 1 ? 's' : '' }} {{ ports.join(', ') }} to</span>
          </label>
          <div class="flex flex-col gap-1 border border-c-border rounded-theme p-1.5 bg-c-elev">
            <label v-for="o in SUBNET_OPTIONS" :key="o.cidr"
              :class="['flex items-center gap-2.5 px-2 py-1.5 rounded-theme cursor-pointer select-none hover:bg-c-hover', o.cidr === '0.0.0.0/0' && selected[o.cidr] ? 'text-c-warn' : '']">
              <input type="checkbox" class="w-3.5 h-3.5 accent-c-accent rounded shrink-0" :checked="selected[o.cidr]" @change="toggle(o.cidr)" />
              <span class="text-sm-var flex-1">{{ o.label }}</span>
              <span class="mono text-[11px] text-c-tx3 tabular-nums">{{ o.note }}</span>
            </label>
          </div>
          <div v-if="selected['0.0.0.0/0']" class="flex items-start gap-1.5 text-[11px] text-c-warn mt-1.5">
            <l-icon name="alert-triangle" is="width:12px;height:12px;margin-top:1px;flex-shrink:0" />
            <span>Exposing this port to any IP — make sure that is intended.</span>
          </div>
        </div>

        <div class="flex justify-end gap-1.5 mt-5">
          <btn @click="dismiss">Cancel</btn>
          <btn variant="primary" @click="confirm">
            <l-icon :name="isPasswordMode ? 'key-round' : 'download'" /> {{ isPasswordMode ? 'Change password' : 'Install' }}
          </btn>
        </div>
      </div>
    </div>
  `,
};

// ============ Network Interface Dialog (DHCP / manual IP) ============
export const NetworkDialog = {
  name: 'NetworkDialog',
  props: { dialog: { type: Object, required: true } },
  emits: ['close'],
  setup(props, { emit }) {
    const iface = props.dialog.iface;
    const cur = props.dialog.current || {};

    // Default the mode to the interface's current method, falling back to manual.
    const mode = ref(cur.method === 'dhcp' ? 'dhcp' : 'manual');
    const address = ref(cur.cidr || (cur.ip ? (cur.prefix != null ? `${cur.ip}/${cur.prefix}` : cur.ip) : ''));
    const gateway = ref(cur.gateway || '');
    const dns = ref(Array.isArray(cur.dns) ? cur.dns.join(', ') : (cur.dns || '1.1.1.1'));

    function dismiss() { emit('close'); }
    function onKeydown(e) { if (e.key === 'Escape') dismiss(); }
    onMounted(() => { document.addEventListener('keydown', onKeydown); nextTick(() => window.lucide?.createIcons()); });
    onUnmounted(() => document.removeEventListener('keydown', onKeydown));

    // Mirror the backend's CIDR / IP validation so we can flag errors before submit.
    const ipv4 = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/;
    function validCidr(v) {
      const m = (v || '').trim().match(/^(.+)\/(\d{1,2})$/);
      if (!m) return false;
      const prefix = Number(m[2]);
      return ipv4.test(m[1]) && prefix >= 0 && prefix <= 32;
    }
    function validIp(v) { return ipv4.test((v || '').trim()); }

    const addressError = computed(() => mode.value === 'manual' && address.value.trim() && !validCidr(address.value));
    const gatewayError = computed(() => mode.value === 'manual' && gateway.value.trim() && !validIp(gateway.value));

    function confirm() {
      if (mode.value === 'manual') {
        if (!validCidr(address.value)) {
          addToast({ t: 'Invalid IP address', d: 'Use CIDR notation, e.g. 192.168.1.50/24', k: 'warn' });
          return;
        }
        if (gateway.value.trim() && !validIp(gateway.value)) {
          addToast({ t: 'Invalid gateway', d: 'Enter a valid IPv4 address.', k: 'warn' });
          return;
        }
        // Fall back to a sensible default gateway so a manual config without one
        // doesn't leave the host without a default route (and drop off the network).
        const gw = gateway.value.trim() || '192.168.1.1';
        const servers = dns.value.split(/[,\s]+/).map(s => s.trim()).filter(Boolean);
        for (const s of servers) {
          if (!validIp(s)) {
            addToast({ t: 'Invalid DNS server', d: s, k: 'warn' });
            return;
          }
        }
        dismiss();
        props.dialog.onConfirm({
          iface,
          method: 'manual',
          address: address.value.trim(),
          gateway: gw,
          dns: servers.join(','),
        });
      } else {
        dismiss();
        props.dialog.onConfirm({ iface, method: 'dhcp' });
      }
    }

    return { iface, cur, mode, address, gateway, dns, addressError, gatewayError, dismiss, confirm };
  },
  template: `
    <div class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px] animate-fade" @click.self="dismiss">
      <div class="w-full max-w-[460px] bg-c-bg border border-c-border rounded-theme-lg shadow-lg p-5 animate-pop" role="dialog" aria-modal="true">
        <div class="flex items-center gap-3 mb-4">
          <div class="w-10 h-10 rounded-[10px] bg-c-acsoft text-c-accent grid place-items-center shrink-0"><l-icon name="network" is="width:20px;height:20px" /></div>
          <div class="min-w-0">
            <h3 class="m-0 text-base font-semibold tracking-[-0.01em] truncate">Edit <span class="mono">{{ iface }}</span></h3>
            <p class="m-0 text-c-tx2 text-xs-var">Configure IPv4 addressing for this interface.</p>
          </div>
        </div>

        <!-- Mode selector -->
        <div class="grid grid-cols-2 gap-1.5 mb-4">
          <button type="button" @click="mode = 'dhcp'"
            :class="['flex flex-col items-start gap-0.5 px-3 py-2.5 rounded-theme border text-left transition-colors', mode === 'dhcp' ? 'border-c-accent bg-c-acsoft text-c-tx' : 'border-c-border bg-c-elev text-c-tx2 hover:bg-c-hover']">
            <span class="flex items-center gap-1.5 text-sm-var font-medium"><l-icon name="zap" is="width:14px;height:14px" /> Automatic</span>
            <span class="text-[11px] text-c-tx3">DHCP — assigned by the network</span>
          </button>
          <button type="button" @click="mode = 'manual'"
            :class="['flex flex-col items-start gap-0.5 px-3 py-2.5 rounded-theme border text-left transition-colors', mode === 'manual' ? 'border-c-accent bg-c-acsoft text-c-tx' : 'border-c-border bg-c-elev text-c-tx2 hover:bg-c-hover']">
            <span class="flex items-center gap-1.5 text-sm-var font-medium"><l-icon name="pencil" is="width:14px;height:14px" /> Manual</span>
            <span class="text-[11px] text-c-tx3">Static IP address</span>
          </button>
        </div>

        <!-- Manual fields -->
        <div v-if="mode === 'manual'" class="flex flex-col gap-3">
          <div>
            <label class="block text-xs-var text-c-tx2 mb-1.5"><span class="uppercase tracking-[0.05em] text-[10px] font-medium">IP address (CIDR)</span></label>
            <input class="input mono w-full" :class="addressError ? 'border-c-danger' : ''" v-model="address" placeholder="192.168.1.50/24" spellcheck="false" autocomplete="off" />
            <div v-if="addressError" class="text-[11px] text-c-danger mt-1">Enter an address in CIDR notation, e.g. 192.168.1.50/24.</div>
          </div>
          <div>
            <label class="block text-xs-var text-c-tx2 mb-1.5"><span class="uppercase tracking-[0.05em] text-[10px] font-medium">Gateway <span class="text-c-tx3 normal-case tracking-normal">(optional, defaults to 192.168.1.1)</span></span></label>
            <input class="input mono w-full" :class="gatewayError ? 'border-c-danger' : ''" v-model="gateway" placeholder="192.168.1.1" spellcheck="false" autocomplete="off" />
            <div v-if="gatewayError" class="text-[11px] text-c-danger mt-1">Enter a valid IPv4 address.</div>
          </div>
          <div>
            <label class="block text-xs-var text-c-tx2 mb-1.5"><span class="uppercase tracking-[0.05em] text-[10px] font-medium">DNS servers <span class="text-c-tx3 normal-case tracking-normal">(optional, comma-separated)</span></span></label>
            <input class="input mono w-full" v-model="dns" placeholder="1.1.1.1, 8.8.8.8" spellcheck="false" autocomplete="off" />
          </div>
        </div>

        <div v-else class="text-xs-var text-c-tx2 border border-c-border rounded-theme p-3 bg-c-elev">
          The interface will request its address, gateway, and DNS automatically from the network's DHCP server.
        </div>

        <div class="flex items-start gap-1.5 text-[11px] text-c-warn mt-3">
          <l-icon name="alert-triangle" is="width:12px;height:12px;margin-top:1px;flex-shrink:0" />
          <span>Applies via <span class="mono">netplan</span>. If you are connected over <span class="mono">{{ iface }}</span>, your session may briefly drop.</span>
        </div>

        <div class="flex justify-end gap-1.5 mt-5">
          <btn @click="dismiss">Cancel</btn>
          <btn variant="primary" @click="confirm"><l-icon name="check" /> Apply</btn>
        </div>
      </div>
    </div>
  `,
};

// ============ Toast List ============
export const ToastList = {
  name: 'ToastList',
  setup() {
    const ICON  = { info: 'info', warn: 'alert-triangle', danger: 'x-octagon', ok: 'check-circle-2' };
    const COLOR = { info: 'var(--info)', warn: 'var(--warn)', danger: 'var(--danger)', ok: 'var(--ok)' };
    return { toasts: appState.toasts, ICON, COLOR };
  },
  template: `
    <div class="fixed bottom-4 right-4 z-[300] flex flex-col gap-2 pointer-events-none">
      <div v-for="toast in toasts" :key="toast.id"
        class="pointer-events-auto flex items-start gap-2.5 min-w-[260px] max-w-[360px] py-2.5 px-3 bg-c-bg border border-c-border rounded-theme shadow-md text-sm-var animate-slidein">
        <l-icon :name="ICON[toast.k] || 'info'" :is="'width:16px;height:16px;flex-shrink:0;margin-top:2px;color:' + (COLOR[toast.k] || COLOR.info)" />
        <div class="flex-1">
          <div class="font-medium">{{ toast.t }}</div>
          <div v-if="toast.d" class="text-c-tx2 text-xs-var mt-px">{{ toast.d }}</div>
        </div>
      </div>
    </div>
  `,
};


