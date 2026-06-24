const { reactive } = Vue;

export const MOCK = reactive({
  host: {
    hostname: 'Loading...',
    kernel: '',
    distro: '',
    timezone: '',
    uptime: '',
    cpu: { usage: 0, cores: 0, threads: 0, load: [0, 0, 0] },
    ram: { used: 0, total: 8.0, pct: 0 },
    disk: { used: 0, total: 80.0, pct: 0 },
    swap: { used: 0, total: 4.0, pct: 0 },
    network: [],
  },
  disks: [],
  sites: [],
  tools: [],
  services: [],
  dns: { installed: false, running: false, records: [] },
  firewall: {
    active: false,
    rules: [],
  },
  audit: [],
  processes: [],
});

export const appState = reactive({
  currentScreen: 'dashboard',
  selectedSiteSlug: '',
  selectedServiceName: '',
  theme: 'light',
  toasts: [],
  overlay: null,   // { scriptKey, title, onDone? }
  confirm: null,   // { title, body, onYes }
  installDialog: null,  // { tool, onConfirm }
  networkDialog: null,  // { iface, current, onConfirm }
  loaded: false,
  // Per-API in-flight flags, e.g. fetching.services === true while /api/v1/services loads.
  // Lets screens tell "still loading" apart from "genuinely empty".
  fetching: {
    system: false, sites: false, tools: false, services: false,
    logs: false, firewall: false, dns: false, processes: false, disks: false,
  },
});

const RAIL_FOR_SCREEN = {
  dashboard:     'dashboard',
  sites:         'sites',
  'site-detail': 'sites',
  'create-site': 'sites',
  dns:           'dns',
  system:        'system',
  firewall:      'firewall',
  services:      'services',
  'service-detail': 'services',
  tools:         'tools',
  logs:          'logs',
  tasks:         'tasks',
};

export function currentRailKey() {
  return RAIL_FOR_SCREEN[appState.currentScreen] || appState.currentScreen;
}

export function syncHashToState() {
  const hash = window.location.hash || '#/';
  if (hash === '#/' || hash === '#') {
    appState.currentScreen = 'dashboard';
  } else if (hash === '#/system') {
    appState.currentScreen = 'system';
  } else if (hash === '#/firewall') {
    appState.currentScreen = 'firewall';
  } else if (hash === '#/sites') {
    appState.currentScreen = 'sites';
  } else if (hash === '#/sites/new') {
    appState.currentScreen = 'create-site';
  } else if (hash.startsWith('#/sites/')) {
    const slug = hash.replace('#/sites/', '');
    appState.selectedSiteSlug = slug;
    appState.currentScreen = 'site-detail';
  } else if (hash === '#/dns') {
    appState.currentScreen = 'dns';
  } else if (hash === '#/services') {
    appState.currentScreen = 'services';
  } else if (hash.startsWith('#/services/')) {
    const name = hash.replace('#/services/', '');
    appState.selectedServiceName = name;
    appState.currentScreen = 'service-detail';
  } else if (hash === '#/tools') {
    appState.currentScreen = 'tools';
  } else if (hash === '#/logs') {
    appState.currentScreen = 'logs';
  } else if (hash === '#/tasks') {
    appState.currentScreen = 'tasks';
  } else {
    appState.currentScreen = 'dashboard';
  }
}

export function navigate(screen, params = {}) {
  Object.assign(appState, params);
  
  let hash = '#/';
  if (screen === 'dashboard') hash = '#/';
  else if (screen === 'system') hash = '#/system';
  else if (screen === 'firewall') hash = '#/firewall';
  else if (screen === 'sites') hash = '#/sites';
  else if (screen === 'create-site') hash = '#/sites/new';
  else if (screen === 'dns') hash = '#/dns';
  else if (screen === 'site-detail') hash = `#/sites/${appState.selectedSiteSlug || params.selectedSiteSlug}`;
  else if (screen === 'services') hash = '#/services';
  else if (screen === 'service-detail') hash = `#/services/${appState.selectedServiceName || params.selectedServiceName}`;
  else if (screen === 'tools') hash = '#/tools';
  else if (screen === 'logs') hash = '#/logs';
  else if (screen === 'tasks') hash = '#/tasks';

  if (window.location.hash !== hash) {
    window.location.hash = hash;
  }
  
  if (appState.currentScreen === screen) {
    fetchSamples();
  } else {
    appState.currentScreen = screen;
  }
}

export function openSite(slug) {
  navigate('site-detail', { selectedSiteSlug: slug });
}

export function addToast({ t = '', d = '', k = 'info' } = {}) {
  const id = Date.now() + Math.random();
  appState.toasts.push({ id, t, d, k });
  setTimeout(() => {
    const idx = appState.toasts.findIndex((x) => x.id === id);
    if (idx >= 0) appState.toasts.splice(idx, 1);
  }, 3700);
}

export function openOverlay(scriptKey, opts = {}) {
  appState.overlay = {
    scriptKey,
    jobId: opts.jobId || null,
    title: opts.title || 'Running…',
    onDone: opts.onDone || null
  };
}

export function confirmThen(title, body, onYes) {
  appState.confirm = { title, body, onYes };
}

// Opens the pre-install dialog (password + firewall subnet selection).
// onConfirm receives { db_password, allowed_subnets }.
// opts.mode: 'install' (default) | 'password' (password-only, for changing it).
export function openInstallDialog(tool, onConfirm, opts = {}) {
  appState.installDialog = { tool, onConfirm, mode: opts.mode || 'install' };
}

// Opens the network interface editor. `current` holds the interface's present
// config; onConfirm receives { iface, method, address, gateway, dns }.
export function openNetworkDialog(iface, current, onConfirm) {
  appState.networkDialog = { iface, current, onConfirm };
}

async function fetchJSON(name, query = "") {
  let apiPath = '';
  if (name === 'system') apiPath = '/api/v1/system';
  else if (name === 'disks') apiPath = '/api/v1/system/disks';
  else if (name === 'sites') apiPath = '/api/v1/sites';
  else if (name === 'tools') apiPath = '/api/v1/tools';
  else if (name === 'services') apiPath = '/api/v1/services';
  else if (name === 'logs') apiPath = '/api/v1/logs';
  else if (name === 'firewall') apiPath = '/api/v1/firewall';
  else if (name === 'dns') apiPath = '/api/v1/dns';
  else if (name === 'processes') {
    apiPath = '/api/v1/processes';
    if (query) {
      apiPath += `?q=${encodeURIComponent(query)}`;
    }
  }

  if (apiPath) {
    const r = await fetch(apiPath);
    if (r.ok) return await r.json();
    throw new Error(`API fetch for ${name} failed with status ${r.status}`);
  }
  throw new Error(`Unknown API endpoint ${name}`);
}

export async function runJobAction(apiPath, bodyParams = {}, overlayTitle = 'Running…', onDone = null) {
  try {
    const form = new URLSearchParams();
    for (const [k, v] of Object.entries(bodyParams)) {
      if (v !== null && v !== undefined) {
        form.append(k, v);
      }
    }
    const r = await fetch(apiPath, {
      method: 'POST',
      body: form
    });
    if (!r.ok) {
      const err = await r.json().catch(() => ({ detail: 'Request failed' }));
      addToast({ t: 'Action failed', d: err.detail || 'Unknown error', k: 'danger' });
      return null;
    }
    const res = await r.json();
    if (res.job_id) {
      openOverlay(null, {
        jobId: res.job_id,
        title: overlayTitle || res.title,
        onDone: () => {
          fetchSamples();
          if (onDone) onDone();
        }
      });
    } else {
      addToast({ t: 'Success', d: res.message || 'Action completed successfully.', k: 'ok' });
      fetchSamples();
      if (onDone) onDone();
    }
    return res;
  } catch (e) {
    console.error('Job action error:', e);
    addToast({ t: 'Network error', d: e.message || 'Could not reach panel server.', k: 'danger' });
    return null;
  }
}

export async function fetchSamples(query = "", specificApis = null) {
  const promises = [];

  // Determine which APIs we need to fetch
  let apisToFetch = [];
  if (specificApis) {
    apisToFetch = specificApis;
  } else {
    const screen = appState.currentScreen || 'dashboard';
    const SCREEN_APIS = {
      dashboard: ['system', 'sites', 'tools'],
      system: ['system', 'disks'],
      firewall: ['firewall'],
      sites: ['sites'],
      'site-detail': ['sites'],
      'create-site': ['sites'],
      dns: ['dns'],
      services: ['services'],
      'service-detail': ['services'],
      tools: ['tools'],
      logs: ['logs'],
      tasks: ['processes'],
    };
    apisToFetch = SCREEN_APIS[screen] || [];
  }

  // Always fetch system if the hostname is 'Loading...' to populate the header
  if (MOCK.host.hostname === 'Loading...' && !apisToFetch.includes('system')) {
    apisToFetch.push('system');
  }

  // Flag every API in this cycle as in-flight so screens can show a loading state.
  apisToFetch.forEach((name) => { appState.fetching[name] = true; });

  const safeFetch = async (name, handler, queryArg = "") => {
    try {
      const data = await fetchJSON(name, queryArg);
      if (data) {
        handler(data);
      }
    } catch (e) {
      console.error(`Failed to fetch/process ${name} data:`, e);
    } finally {
      appState.fetching[name] = false;
    }
  };

  // 1. System
  if (apisToFetch.includes('system')) {
    promises.push(safeFetch('system', (sysData) => {
      if (sysData.info) {
        const sys = sysData.info;
        MOCK.host.hostname = sys.hostname;
        MOCK.host.kernel = sys.kernel;
        MOCK.host.distro = sys.os_name;
        MOCK.host.timezone = sys.timezone;
        MOCK.host.uptime = sys.uptime;
        MOCK.host.cpu.usage = sys.cpu_percent;
        MOCK.host.cpu.cores = sys.cpu_count_physical;
        MOCK.host.cpu.threads = sys.cpu_count;
        MOCK.host.cpu.load = [sys.load_1, sys.load_5, sys.load_15];
        MOCK.host.ram.used = sys.ram_used_gb;
        MOCK.host.ram.total = sys.ram_total_gb;
        MOCK.host.ram.pct = sys.ram_percent;
        MOCK.host.disk.used = sys.disk_used_gb;
        MOCK.host.disk.total = sys.disk_total_gb;
        MOCK.host.disk.pct = sys.disk_percent;
        MOCK.host.swap.used = sys.swap_used_gb;
        MOCK.host.swap.total = sys.swap_total_gb;
        MOCK.host.swap.pct = sys.swap_percent;
        MOCK.host.network = sys.ips ? sys.ips.map(ip => ({
          iface: ip.iface,
          ip: ip.ip,
          prefix: ip.prefix != null ? ip.prefix : null,
          cidr: ip.cidr || ip.ip,
          method: ip.method || 'unknown',
          gateway: ip.gateway || '',
          dns: ip.dns || [],
        })) : [];
      }
    }));
  }

  // 1b. Disks (block devices, partitions, mount points)
  if (apisToFetch.includes('disks')) {
    promises.push(safeFetch('disks', (disksData) => {
      MOCK.disks = Array.isArray(disksData.disks) ? disksData.disks : [];
    }));
  }

  // 2. Sites
  if (apisToFetch.includes('sites')) {
    promises.push(safeFetch('sites', (sitesData) => {
      if (sitesData.sites) {
        MOCK.sites = sitesData.sites.map(site => {
          let accessStr = '';
          if (site.access.kind === 'domain') {
            accessStr = site.access.value;
            if (site.backend && site.backend.proxy_target) {
              const portMatch = site.backend.proxy_target.match(/:(\d+)$/);
              if (portMatch) accessStr += ` → :${portMatch[1]}`;
              else accessStr += ` → ${site.backend.proxy_target}`;
            }
          } else if (site.access.kind === 'port') {
            accessStr = `:${site.access.value}`;
            if (site.backend && site.backend.proxy_target) {
              const portMatch = site.backend.proxy_target.match(/:(\d+)$/);
              accessStr += ` → :${portMatch ? portMatch[1] : site.backend.proxy_target}`;
            }
          }

          let dll = site.backend?.dll || '';
          if (dll && !dll.endsWith('.dll')) dll += '.dll';

          return {
            slug: site.name,
            name: site.name,
            type: site.type,
            access: accessStr,
            status: site.status.badge || 'ok',
            pid: site.status.pid,
            mem: site.status.memory_mb != null ? site.status.memory_mb : null,
            cpu: site.status.cpu_percent != null ? site.status.cpu_percent : null,
            modified: site.last_modified,
            dll: dll,
            internalPort: site.backend?.internal_port || null,
            env: site.backend?.aspnetcore_env || null,
            created: site.created_at ? site.created_at.slice(0, 10) : '',
            configPath: site.paths?.nginx_conf || '',
            unitPath: site.paths?.systemd_unit || '',
            webRoot: site.paths?.public || '',
            proxyTarget: site.backend?.proxy_target || null
          };
        });
      }
    }));
  }

  // 3. Tools
  if (apisToFetch.includes('tools')) {
    promises.push(safeFetch('tools', (toolsData) => {
      if (toolsData.tools) {
        MOCK.tools = toolsData.tools.map(t => {
          const existing = MOCK.tools.find(x => x.id === t.module.name) || {};
          let version = t.status.version || '';
          const versionMatch = version.match(/\d+\.\d+(?:\.\d+)*\b/);
          if (versionMatch) {
            version = versionMatch[0];
          } else {
            if (version.includes('nginx/')) version = version.replace('nginx/', '');
            if (version.includes('PostgreSQL) ')) version = version.substring(version.indexOf('PostgreSQL) ') + 12);
            const vLeadingMatch = version.match(/\bv(\d+)/i);
            if (vLeadingMatch) {
              version = version.substring(version.indexOf(vLeadingMatch[0]) + 1);
            }
          }

          const diag = t.status.extra ? Object.entries(t.status.extra) : [];

          return {
            id: t.module.name,
            name: t.module.display_name,
            desc: t.module.description,
            installed: t.status.installed,
            version: version || null,
            state: (t.status.service_state === 'n/a' && t.status.installed) ? 'installed' : t.status.service_state,
            ports: t.status.ports && t.status.ports.length ? t.status.ports.join(', ') : null,
            logo: t.module.logo ? `logo/${t.module.logo}` : (existing.logo || t.module.name.substring(0, 2).toUpperCase()),
            color: existing.color || '#6b7280',
            diag: diag.length ? diag : undefined,
            requiresPassword: t.module.requires_password || false,
            firewallPorts: t.module.firewall_ports || [],
            installParams: t.module.install_params || [],
            canUninstall: t.module.can_uninstall || false,
            canChangePassword: t.module.can_change_password || false
          };
        });
      }
    }));
  }

  // 3b. DNS (CoreDNS records)
  if (apisToFetch.includes('dns')) {
    promises.push(safeFetch('dns', (dnsData) => {
      MOCK.dns.installed = !!dnsData.installed;
      MOCK.dns.running = !!dnsData.running;
      MOCK.dns.records = Array.isArray(dnsData.records)
        ? dnsData.records.map((r) => ({ ip: r.ip, domain: r.domain }))
        : [];
    }));
  }

  // 4. Services
  if (apisToFetch.includes('services')) {
    promises.push(safeFetch('services', (servicesData) => {
      MOCK.services = servicesData.map(s => ({
        name: s.name,
        desc: s.description || s.name,
        status: s.state,
        autostart: s.enabled,
        mem: s.memory_mb != null ? s.memory_mb : null,
        cpu: s.cpu_percent != null ? s.cpu_percent : null,
        modified: s.last_edit,
        cmd: s.exec_start || '',
        path: s.path,
        content: s.content,
        workingDir: s.working_dir,
        user: s.user,
        restart: s.restart,
        restartSec: s.restart_sec,
        syslogId: s.syslog_id,
        envVars: s.env_vars || []
      }));
    }));
  }

  // 5. Logs
  if (apisToFetch.includes('logs')) {
    promises.push(safeFetch('logs', (logsData) => {
      MOCK.audit = logsData.map(line => {
        const parts = line.split(' | ');
        const tStr = parts[0] || '';
        const aStr = parts[1] || '';
        const dStr = parts[2] || '';

        let formattedTime = tStr.replace('T', ' ').replace('Z', '');
        const detailsObj = {};
        if (dStr) {
          const regex = /([a-zA-Z0-9_-]+)=([^=\s]+|"[^"]*")/g;
          let match;
          let hasMatches = false;
          while ((match = regex.exec(dStr)) !== null) {
            hasMatches = true;
            let val = match[2];
            if (val.startsWith('"') && val.endsWith('"')) {
              val = val.substring(1, val.length - 1);
            }
            if (!isNaN(val) && val.trim() !== '') {
              val = Number(val);
            }
            detailsObj[match[1]] = val;
          }
          if (!hasMatches) {
            detailsObj.info = dStr;
          }
        }

        return {
          t: formattedTime,
          a: aStr,
          d: detailsObj
        };
      });
    }));
  }

  // 6. Firewall
  if (apisToFetch.includes('firewall')) {
    promises.push(safeFetch('firewall', (firewallData) => {
      if (firewallData.ufw) {
        MOCK.firewall.active = firewallData.ufw.enabled;
        if (firewallData.ufw.rules) {
          MOCK.firewall.rules = firewallData.ufw.rules.map(r => ({
            idx: r.num,
            port: r.to,
            action: r.action,
            from: r.from_,
            v6: r.is_v6,
            label: r.label
          }));
        }
      }
    }));
  }

  // 7. Processes
  if (apisToFetch.includes('processes')) {
    promises.push(safeFetch('processes', (procData) => {
      if (procData.processes) {
        MOCK.processes = procData.processes;
      }
    }, query));
  }

  try {
    await Promise.all(promises);
  } catch (error) {
    console.error('Failed to parallel load all API data:', error);
  } finally {
    appState.loaded = true;
  }
}

