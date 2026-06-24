import { MOCK, appState, navigate, addToast, runJobAction, confirmThen } from '../store.js';
import { ansiToHtml } from '../utils.js';

const { computed, onMounted, nextTick, ref } = Vue;

export const ServiceDetail = {
  name: 'ScreenServiceDetail',
  setup() {
    const isEditingUnit = ref(false);
    const editableUnitContent = ref('');
    const showOutput = ref(false);
    const outputTitle = ref('');
    const outputContent = ref('');
    const outputWordWrap = ref(true);

    const service = computed(() =>
      MOCK.services.find((x) => x.name === appState.selectedServiceName) || MOCK.services[0] || {}
    );

    // Dynamic defaults based on active service
    const serviceDetails = computed(() => {
      const s = service.value;
      if (s && s.workingDir) {
        return {
          workingDir: s.workingDir,
          user: s.user || 'root',
          restart: s.restart || 'always',
          restartSec: s.restartSec || 10,
          syslogId: s.syslogId || s.name || '—',
          envVars: s.envVars || []
        };
      }
      const defaults = {
        workingDir: s.name ? `/var/www/services/${s.name}` : '—',
        user: (s.name && s.name.includes('backup')) ? 'root' : 'www-data',
        restart: (s.name && s.name.includes('backup')) ? 'on-failure' : 'always',
        restartSec: 5,
        syslogId: s.name || '—',
        envVars: s.name ? [
          'NODE_ENV=production',
          'PORT=5000'
        ] : []
      };

      if (s.name === 'acme-worker') {
        defaults.envVars = ['DOTNET_ENVIRONMENT=Production', 'QUEUE_CONCURRENCY=4'];
      } else if (s.name === 'acme-scheduler') {
        defaults.envVars = ['CONFIG_PATH=/etc/acme/scheduler.toml', 'LOG_LEVEL=info'];
      } else if (s.name === 'postgres-backup') {
        defaults.envVars = ['PGPASSWORD=********', 'BACKUP_DIR=/backups', 'MAX_BACKUPS=7'];
      } else if (s.name === 'log-shipper') {
        defaults.envVars = ['AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE', 'AWS_REGION=us-east-1', 'S3_BUCKET=acme-logs'];
      } else if (s.name === 'metrics-exporter') {
        defaults.envVars = ['PROMETHEUS_PORT=9100', 'COLLECTORS_ENABLED=cpu,mem,disk,systemd'];
      }

      return defaults;
    });

    const getServicePath = computed(() => service.value.name ? `/etc/systemd/system/${service.value.name}.service` : '—');

    const meta = computed(() => {
      const s = service.value;
      const d = serviceDetails.value;
      return [
        { k: 'Command', v: s.cmd || '—', mono: true, break: true },
        { k: 'Working dir', v: d.workingDir || '—', mono: true },
        { k: 'User', v: d.user || '—', mono: true },
        { k: 'Restart policy', v: d.restart ? `${d.restart} / ${d.restartSec}s` : '—', mono: false },
        { k: 'Syslog id', v: d.syslogId || '—', mono: true },
        { k: 'Last modified', v: s.modified || '—', mono: false },
        { k: 'Unit file', v: getServicePath.value, mono: true, break: true },
      ];
    });

    const runtime = computed(() => {
      const s = service.value;
      const isRunning = s.status === 'active';
      return [
        { lbl: 'Memory', val: (isRunning && s.mem != null) ? s.mem.toFixed(1) : '0.0', unit: 'MB' },
        { lbl: 'CPU', val: (isRunning && s.cpu != null) ? s.cpu.toFixed(1) : '0.0', unit: '%' },
        { lbl: 'Uptime', val: isRunning ? '4d 18h 12m' : '—', unit: '', full: true },
      ];
    });

    const recentEvents = computed(() => {
      const s = service.value;
      const isRunning = s.status === 'active';
      return [
        { t: '1h ago', k: isRunning ? 'ok' : 'info', msg: `service ${s.status || 'stopped'} manually by admin` },
        { t: 'yesterday', k: 'info', msg: 'config reloaded' },
        { t: '5d ago', k: 'info', msg: 'service registered in systemd' },
      ];
    });

    function openEditModal() {
      if (!service.value.name) return;
      editableUnitContent.value = service.value.content || `[Unit]
Description=${service.value.desc || ''}
After=network.target

[Service]
Type=simple
User=${serviceDetails.value.user || 'root'}
WorkingDirectory=${serviceDetails.value.workingDir || ''}
ExecStart=${service.value.cmd || ''}
Restart=${serviceDetails.value.restart || 'always'}
RestartSec=${serviceDetails.value.restartSec || 5}
SyslogIdentifier=${serviceDetails.value.syslogId || ''}

[Install]
WantedBy=multi-user.target`;
      isEditingUnit.value = true;
    }

    function saveUnitFile() {
      if (!service.value.name) return;
      isEditingUnit.value = false;
      runJobAction(`/api/v1/services/${service.value.name}/edit`, { content: editableUnitContent.value }, `Saving & restarting ${service.value.name}`);
    }

    function runServiceAction(action) {
      const name = service.value.name;
      if (!name) return;
      const actionTitle = action.charAt(0).toUpperCase() + action.slice(1);
      runJobAction(`/api/v1/services/${name}/${action}`, {}, `${actionTitle}ing service ${name}`);
    }

    async function viewOutput(action) {
      try {
        const name = service.value.name;
        if (!name) return;
        const apiPath = `/api/v1/services/${name}/${action}`;
        const r = await fetch(apiPath);
        if (r.ok) {
          const res = await r.json();
          outputTitle.value = action === 'status' ? 'Systemd Status Output' : 'Journalctl Logs Output';
          outputContent.value = res.output;
          showOutput.value = true;
          addToast({ t: `${action.toUpperCase()} loaded`, k: 'info' });
        } else {
          addToast({ t: `Failed to fetch ${action}`, k: 'danger' });
        }
      } catch (e) {
        addToast({ t: 'Network error', d: e.message, k: 'danger' });
      }
    }

    function deleteService() {
      const name = service.value.name;
      if (!name) return;
      confirmThen(
        `Delete service '${name}'?`,
        `This will stop, disable, and remove the unit file permanently. This action cannot be undone.`,
        () => {
          runJobAction(`/api/v1/services/${name}/delete`, {}, `Deleting service ${name}`, () => {
            navigate('services');
          });
        }
      );
    }

    async function copyOutput() {
      const text = outputContent.value || '';
      try {
        if (navigator.clipboard && window.isSecureContext) {
          await navigator.clipboard.writeText(text);
        } else {
          // Fallback for non-secure contexts (HTTP / panel accessed by IP)
          const ta = document.createElement('textarea');
          ta.value = text;
          ta.setAttribute('readonly', '');
          ta.style.position = 'fixed';
          ta.style.top = '-9999px';
          document.body.appendChild(ta);
          ta.select();
          const ok = document.execCommand('copy');
          document.body.removeChild(ta);
          if (!ok) throw new Error('Clipboard not available');
        }
        addToast({ t: 'Output copied to clipboard', k: 'info' });
      } catch (err) {
        addToast({ t: 'Failed to copy output', d: err.message, k: 'danger' });
      }
    }

    function downloadOutput() {
      const pad = (n) => String(n).padStart(2, '0');
      const safe = (s) => String(s || '').replace(/[^a-zA-Z0-9._-]/g, '_');
      const name = service.value.name || 'service';
      const host = (MOCK.host?.hostname && MOCK.host.hostname !== 'Loading...') ? MOCK.host.hostname : 'server';
      const d = new Date();
      const ts = `${pad(d.getMonth() + 1)}-${pad(d.getDate())}-${d.getFullYear()}-${pad(d.getHours())}-${pad(d.getMinutes())}-${pad(d.getSeconds())}`;
      const filename = `${safe(host)}-${safe(name)}-${ts}.log`;
      const blob = new Blob([outputContent.value || ''], { type: 'text/plain;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
      addToast({ t: 'Log downloaded', d: filename, k: 'ok' });
    }

    const formattedOutput = computed(() => ansiToHtml(outputContent.value));

    onMounted(() => nextTick(() => window.lucide?.createIcons()));

    return {
      service, serviceDetails, getServicePath, meta, runtime, recentEvents,
      isEditingUnit, editableUnitContent, showOutput, outputTitle, outputContent,
      openEditModal, saveUnitFile, runServiceAction, viewOutput, deleteService, navigate,
      outputWordWrap, copyOutput, downloadOutput, formattedOutput
    };
  },
  template: `
    <section>
      <!-- Breadcrumb and Top Nav actions -->
      <div class="flex items-end justify-between gap-6 mb-6">
        <div>
          <div class="flex items-center gap-2 mb-2">
            <btn variant="ghost" sm @click="navigate('services')">
              <l-icon name="arrow-left" /> Services
            </btn>
          </div>
          <div class="flex items-center gap-3">
            <h1 class="text-[22px] font-semibold tracking-[-0.02em] mono font-mono">{{ service.name }}</h1>
            <status-badge :status="service.status" />
            <status-badge :status="service.autostart" />
          </div>
          <div v-if="service.desc" class="text-sm-var text-c-tx2 mt-1">{{ service.desc }}</div>
        </div>
      </div>

      <!-- Main Layout Grid -->
      <div class="grid grid-cols-1 lg:grid-cols-[2fr_1fr] gap-3">
        
        <!-- Left Side Cards -->
        <div class="flex flex-col gap-3">
          
          <!-- Configuration Details Card -->
          <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
            <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
              <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Configuration</h3>
              <span class="text-xs-var text-c-tx3 mono font-mono">systemd unit configuration</span>
            </div>
            <div class="p-4">
              <dl class="grid grid-cols-1 sm:grid-cols-[140px_1fr] gap-y-2.5 gap-x-4 text-sm-var m-0">
                <template v-for="m in meta" :key="m.k">
                  <dt class="text-c-tx2 font-medium">{{ m.k }}</dt>
                  <dd class="m-0 tabular-nums" :class="[m.mono ? 'mono text-xs-var' : '', m.break ? 'break-all' : '']">{{ m.v }}</dd>
                </template>
              </dl>
            </div>
            
            <!-- Environment Variables list inside Configuration -->
            <div class="px-4 py-3.5 border-t border-c-border">
              <div class="text-xs-var uppercase tracking-[0.06em] text-c-tx2 font-medium mb-2.5">Environment Variables</div>
              <ul class="flex flex-col gap-1.5 m-0 p-0 list-none">
                <li v-for="ev in serviceDetails.envVars" :key="ev" class="font-mono text-xs-var text-c-tx2 bg-c-subtle border border-c-border rounded px-2.5 py-1 select-all">
                  {{ ev }}
                </li>
              </ul>
            </div>
          </div>

          <!-- Unit Action Bar Card -->
          <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
            <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
              <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Actions</h3>
            </div>
            <div class="p-4 flex flex-wrap gap-2">
              
              <!-- Start / Stop / Restart actions -->
              <btn variant="success" @click="runServiceAction('start')" :disabled="service.status === 'active'">
                <l-icon name="play" /> Start
              </btn>
              <btn variant="danger" @click="runServiceAction('stop')" :disabled="service.status === 'stopped'">
                <l-icon name="square" /> Stop
              </btn>
              <btn variant="warn" @click="runServiceAction('restart')">
                <l-icon name="refresh-cw" /> Restart
              </btn>

              <div class="hidden sm:block w-px bg-c-border mx-1 self-stretch"></div>

              <!-- Autostart toggles -->
              <btn variant="success" @click="runServiceAction('enable')" :disabled="service.autostart === 'enabled'">
                <l-icon name="check-circle" /> Enable
              </btn>
              <btn variant="danger" @click="runServiceAction('disable')" :disabled="service.autostart === 'disabled'">
                <l-icon name="ban" /> Disable
              </btn>

              <div class="hidden sm:block w-px bg-c-border mx-1 self-stretch"></div>

              <!-- Diagnostic Tools -->
              <btn @click="openEditModal">
                <l-icon name="pencil" /> Edit Unit File
              </btn>
              <btn variant="info" @click="viewOutput('status')">
                <l-icon name="info" /> Status
              </btn>
              <btn variant="info" @click="viewOutput('logs')">
                <l-icon name="scroll-text" /> Logs
              </btn>
            </div>
          </div>

          <!-- Danger Zone Card -->
          <div class="bg-c-bg border border-c-dngstrong/30 rounded-theme overflow-hidden bg-[color-mix(in_oklab,var(--danger)_3%,transparent)]">
            <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-dngstrong/20">
              <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em] text-c-danger">Danger Zone</h3>
            </div>
            <div class="p-4 flex items-center justify-between gap-4 flex-wrap">
              <div>
                <p class="m-0 text-sm-var font-medium">Delete this service</p>
                <p class="m-0 text-xs-var text-c-tx2 mt-0.5">Stops, disables, and removes the systemd unit file permanently.</p>
              </div>
              <btn variant="danger" @click="deleteService">
                <l-icon name="trash-2" /> Delete Service
              </btn>
            </div>
          </div>
        </div>

        <!-- Right Side Cards -->
        <div class="flex flex-col gap-3">
          
          <!-- Runtime Statistics Card -->
          <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
            <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
              <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Runtime</h3>
              <span class="text-xs-var text-c-tx3 mono font-mono">{{ service.status === 'active' ? 'PID 184511' : '' }}</span>
            </div>
            <div class="p-4">
              <div class="grid grid-cols-2 gap-x-2 gap-y-3.5">
                <div v-for="r in runtime" :key="r.lbl" :class="r.full ? 'col-span-2' : ''">
                  <div class="text-c-tx2 text-xs-var uppercase tracking-[0.06em] font-medium">{{ r.lbl }}</div>
                  <div class="text-xl font-semibold tracking-[-0.02em] tabular-nums mt-0.5">
                    {{ r.val }}<span v-if="r.unit" class="text-xs text-c-tx3 font-medium"> {{ r.unit }}</span>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <!-- Recent Events Card -->
          <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
            <div class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border">
              <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em]">Recent events</h3>
            </div>
            <div class="p-4">
              <div class="flex flex-col gap-2.5">
                <div v-for="e in recentEvents" :key="e.t" class="flex items-center gap-2.5 text-sm-var">
                  <span class="inline-flex items-center gap-1.5 h-[18px] px-1.5 rounded-full text-[11px] font-medium" :class="e.k === 'ok' ? 'bg-c-oksoft text-c-ok' : 'bg-c-infosoft text-c-info'">
                    <span class="w-1.5 h-1.5 rounded-full bg-current"></span>{{ e.k === 'ok' ? 'done' : 'info' }}
                  </span>
                  <span>{{ e.msg }}</span>
                  <span class="flex-1"></span>
                  <span class="text-c-tx3 mono text-xs-var">{{ e.t }}</span>
                </div>
              </div>
            </div>
          </div>
        </div>

      </div>

      <!-- Edit Unit File Modal -->
      <div v-if="isEditingUnit" class="fixed inset-0 z-[250] flex items-center justify-center bg-black/60 backdrop-blur-sm p-4 animate-fade" @click.self="isEditingUnit = false">
        <div class="w-full max-w-3xl bg-c-bg border border-c-border rounded-theme-lg shadow-2xl flex flex-col max-h-[85vh] overflow-hidden animate-pop">
          
          <div class="flex items-center justify-between px-5 py-3.5 border-b border-c-border shrink-0 bg-c-elev">
            <div class="flex items-center gap-2">
              <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center"><l-icon name="pencil" is="width:14px;height:14px" /></div>
              <h3 class="m-0 text-sm-var font-semibold tracking-[-0.01em] mono font-mono">{{ service.name }}.service</h3>
            </div>
            <btn variant="ghost" sm square @click="isEditingUnit = false" aria-label="Close">
              <l-icon name="x" />
            </btn>
          </div>
          
          <div class="flex flex-col flex-1 min-h-0">
            <textarea v-model="editableUnitContent" spellcheck="false"
                      class="flex-1 min-h-[360px] bg-zinc-950 font-mono text-xs text-zinc-300 p-5 resize-none outline-none border-0 leading-relaxed overflow-y-auto" style="font-family: monospace;"></textarea>
            
            <div class="px-5 py-3.5 border-t border-c-border bg-c-elev flex items-center justify-between shrink-0">
              <span class="text-[10px] text-c-tx3 mono">{{ getServicePath }}</span>
              <div class="flex gap-2">
                <btn @click="isEditingUnit = false">Cancel</btn>
                <btn variant="primary" @click="saveUnitFile">
                  <l-icon name="check" /> Save &amp; Restart
                </btn>
              </div>
            </div>
          </div>
          
        </div>
      </div>

      <!-- Output viewer dialog (Status/Logs) -->
      <div v-if="showOutput" class="fixed inset-0 z-[200] grid place-items-center p-10 px-6 bg-black/40 backdrop-blur-[4px]" @click.self="showOutput = false">
        <div class="flex flex-col w-full max-w-4xl max-h-[80vh] bg-c-bg border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop" role="dialog" aria-modal="true">
          <div class="flex items-center gap-2.5 py-3.5 px-4 border-b border-c-border">
            <div class="w-7 h-7 rounded-[7px] bg-c-subtle grid place-items-center"><l-icon name="terminal" is="width:14px;height:14px" /></div>
            <div>
              <div class="font-semibold text-sm-var">{{ outputTitle }}</div>
              <div class="text-xs-var text-c-tx2 mono">{{ service.name }}</div>
            </div>
            <div class="ml-auto flex items-center gap-2 mr-2">
              <btn variant="ghost" sm @click="copyOutput" class="text-xs-var h-7 px-2">
                <l-icon name="copy" is="width:13px;height:13px;margin-right:4px;" /> Copy
              </btn>
              <btn variant="ghost" sm @click="downloadOutput" class="text-xs-var h-7 px-2">
                <l-icon name="download" is="width:13px;height:13px;margin-right:4px;" /> Download
              </btn>
              <label class="flex items-center gap-1.5 text-xs-var cursor-pointer select-none px-2 h-7 bg-c-subtle hover:bg-c-hover rounded-theme border border-c-border text-c-tx2 hover:text-c-tx">
                <input type="checkbox" v-model="outputWordWrap" class="w-3 h-3 accent-c-accent rounded" />
                <span>Word Wrap</span>
              </label>
            </div>
            <btn variant="ghost" sm square class="ml-auto" @click="showOutput = false" aria-label="Close">
              <l-icon name="x" />
            </btn>
          </div>
          <div :class="['term overflow-auto font-mono text-xs-var p-4 bg-c-elev text-c-tx leading-relaxed select-text', outputWordWrap ? 'whitespace-pre-wrap' : 'whitespace-pre']" style="height:480px; word-break: break-all;" v-html="formattedOutput"></div>
        </div>
      </div>
    </section>
  `,
};
