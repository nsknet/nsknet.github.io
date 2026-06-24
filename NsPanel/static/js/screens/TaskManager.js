import { MOCK, appState, addToast, confirmThen, fetchSamples } from '../store.js';

const { computed, ref, onMounted, onUnmounted, watch, nextTick } = Vue;

export const TaskManager = {
  name: 'TaskManager',
  setup() {
    const filterText = ref('');
    const sortCol = ref('cpu_percent'); // Default sort by CPU %
    const sortOrder = ref('desc'); // 'asc' or 'desc'
    const refreshIntervalVal = ref('5000'); // Default refresh to 5 seconds
    const expandedPids = ref(new Set());
    let intervalId = null;

    // Computed metrics summary cards
    const summary = computed(() => {
      const procs = MOCK.processes || [];
      const totalProcs = procs.length;
      let totalThreads = 0;
      let totalRam = 0;
      let activeCpuProcs = 0;

      procs.forEach(p => {
        totalThreads += p.threads || 0;
        totalRam += p.ram_gb || 0;
        if (p.cpu_percent > 1) {
          activeCpuProcs++;
        }
      });

      return {
        totalProcs,
        totalThreads,
        totalRam: totalRam.toFixed(2),
        activeCpuProcs
      };
    });

    // Compute independent top 10 lists for threads, cpu_percent, and ram_gb
    const topCpu = computed(() => {
      return [...(MOCK.processes || [])]
        .sort((a, b) => b.cpu_percent - a.cpu_percent)
        .slice(0, 10);
    });

    const topRam = computed(() => {
      return [...(MOCK.processes || [])]
        .sort((a, b) => b.ram_gb - a.ram_gb)
        .slice(0, 10);
    });

    const topThreads = computed(() => {
      return [...(MOCK.processes || [])]
        .sort((a, b) => b.threads - a.threads)
        .slice(0, 10);
    });

    // Dynamic HSL coloring for cells inside the Top 10
    function getHeatmapStyle(val, type, pid) {
      if (val === 0 || !val) return {};

      let list = [];
      if (type === 'cpu') list = topCpu.value;
      else if (type === 'ram') list = topRam.value;
      else if (type === 'threads') list = topThreads.value;

      const idx = list.findIndex(p => p.pid === pid);
      if (idx === -1) return {};

      // Rank is 0 (Rank 1, highest) to 9 (Rank 10, lowest in top 10)
      // Interpolate hue from 35 (Orange) to 0 (Red)
      const rankIndex = idx;
      const hue = Math.round(35 * (rankIndex / 9));

      const isDark = appState.theme === 'dark';
      if (isDark) {
        return {
          color: `hsla(${hue}, 100%, 80%, 1)`,
          backgroundColor: `hsla(${hue}, 95%, 42%, 0.22)`,
          border: `1px solid hsla(${hue}, 95%, 50%, 0.45)`,
          padding: '2px 8px',
          borderRadius: '6px',
          fontWeight: '600',
          display: 'inline-block',
          boxShadow: `0 0 12px hsla(${hue}, 95%, 50%, 0.12)`,
        };
      } else {
        return {
          color: `hsla(${hue}, 95%, 35%, 1)`,
          backgroundColor: `hsla(${hue}, 95%, 50%, 0.08)`,
          border: `1px solid hsla(${hue}, 95%, 45%, 0.26)`,
          padding: '2px 8px',
          borderRadius: '6px',
          fontWeight: '600',
          display: 'inline-block',
        };
      }
    }

    // Toggle full arguments view
    function toggleExpand(pid) {
      if (expandedPids.value.has(pid)) {
        expandedPids.value.delete(pid);
      } else {
        expandedPids.value.add(pid);
      }
    }

    // Manual quick refresh action
    async function handleRefresh() {
      await fetchSamples(filterText.value);
      addToast({ t: 'Processes refreshed', k: 'info' });
      nextTick(() => window.lucide?.createIcons());
    }

    // Kill process action
    function killProc(p) {
      confirmThen(
        'Terminate Process?',
        `Are you sure you want to terminate process PID ${p.pid} (${p.name})? This action cannot be undone.`,
        async () => {
          try {
            const form = new URLSearchParams();
            form.append('pid', p.pid);
            const r = await fetch('/api/v1/processes/kill', {
              method: 'POST',
              body: form,
            });
            if (r.ok) {
              addToast({ t: 'Process terminated', d: `PID ${p.pid} killed successfully.`, k: 'ok' });
              fetchSamples(filterText.value);
            } else {
              const err = await r.json().catch(() => ({ detail: 'Request failed' }));
              addToast({
                t: 'Failed to kill process',
                d: err.detail || 'Access denied or process already exited.',
                k: 'danger',
              });
            }
          } catch (e) {
            addToast({ t: 'Network error', d: e.message, k: 'danger' });
          }
        }
      );
    }

    // Sorting columns click handler
    function changeSort(col) {
      if (sortCol.value === col) {
        if (sortOrder.value === 'desc') {
          sortOrder.value = 'asc';
        } else if (sortOrder.value === 'asc') {
          sortOrder.value = 'none';
        } else {
          sortOrder.value = 'desc';
        }
      } else {
        sortCol.value = col;
        sortOrder.value = 'desc'; // Default to desc for numbers/meters
      }
    }

    // Handle auto-refresh interval setup and cleanup
    function setupInterval() {
      if (intervalId) {
        clearInterval(intervalId);
        intervalId = null;
      }

      if (refreshIntervalVal.value !== 'none') {
        const ms = parseInt(refreshIntervalVal.value, 10);
        intervalId = setInterval(() => {
          fetchSamples(filterText.value);
        }, ms);
      }
    }

    watch(refreshIntervalVal, setupInterval);

    // Debounced search watcher to fetch from server-side
    let debounceTimer = null;
    watch(filterText, (newVal) => {
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        fetchSamples(newVal);
      }, 300);
    });

    // Filtered & Sorted process rows (filtering is performed on server side now)
    const processedList = computed(() => {
      let list = [...(MOCK.processes || [])];

      // Sorting
      if (sortCol.value && sortOrder.value !== 'none') {
        list.sort((a, b) => {
          let valA = a[sortCol.value];
          let valB = b[sortCol.value];

          // Treat strings as lowercase
          if (typeof valA === 'string') valA = valA.toLowerCase();
          if (typeof valB === 'string') valB = valB.toLowerCase();

          if (valA < valB) return sortOrder.value === 'asc' ? -1 : 1;
          if (valA > valB) return sortOrder.value === 'asc' ? 1 : -1;
          return 0;
        });
      }

      return list;
    });

    onMounted(async () => {
      await fetchSamples(filterText.value);
      setupInterval();
      nextTick(() => window.lucide?.createIcons());
    });

    onUnmounted(() => {
      if (intervalId) {
        clearInterval(intervalId);
      }
    });

    return {
      MOCK,
      appState,
      filterText,
      sortCol,
      sortOrder,
      refreshIntervalVal,
      expandedPids,
      summary,
      getHeatmapStyle,
      toggleExpand,
      handleRefresh,
      killProc,
      changeSort,
      processedList
    };
  },
  template: `
    <section class="animate-fade">
      <!-- Title & Toolbar Header -->
      <div class="flex flex-col md:flex-row md:items-end justify-between gap-4 mb-6">
        <div>
          <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">Task Manager</h1>
          <div class="text-sm-var text-c-tx2">Real-time system process monitor and resource scheduler.</div>
        </div>
        <div class="flex items-center gap-2.5">
          <!-- Refresh Interval dropdown -->
          <div class="flex items-center gap-1.5 bg-c-bg border border-c-border rounded-lg px-2.5 py-1">
            <span class="text-xs-var font-medium text-c-tx2">Refresh:</span>
            <select v-model="refreshIntervalVal" class="bg-transparent border-0 outline-none text-xs-var font-semibold cursor-pointer text-c-tx focus:ring-0">
              <option value="none">Paused</option>
              <option value="5000">5s</option>
              <option value="10000">10s</option>
              <option value="15000">15s</option>
              <option value="30000">30s</option>
              <option value="60000">60s</option>
            </select>
          </div>
          <!-- Manual Refresh trigger -->
          <btn @click="handleRefresh">
            <l-icon name="refresh-cw" /> Refresh
          </btn>
        </div>
      </div>

      <!-- Quick Status Summary Cards -->
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-5">
        <div class="bg-c-bg border border-c-border rounded-theme p-[15px] flex items-center justify-between">
          <div>
            <div class="text-xs-var text-c-tx3 uppercase tracking-[0.05em] font-medium mb-1">Total Processes</div>
            <div class="text-xl font-semibold tabular-nums">{{ summary.totalProcs }}</div>
          </div>
          <div class="w-8 h-8 rounded-lg bg-c-subtle flex items-center justify-center text-c-tx2">
            <l-icon name="list" is="width:16px;height:16px" />
          </div>
        </div>
        <div class="bg-c-bg border border-c-border rounded-theme p-[15px] flex items-center justify-between">
          <div>
            <div class="text-xs-var text-c-tx3 uppercase tracking-[0.05em] font-medium mb-1">Total Threads</div>
            <div class="text-xl font-semibold tabular-nums">{{ summary.totalThreads }}</div>
          </div>
          <div class="w-8 h-8 rounded-lg bg-c-subtle flex items-center justify-center text-c-tx2">
            <l-icon name="git-merge" is="width:16px;height:16px" />
          </div>
        </div>
        <div class="bg-c-bg border border-c-border rounded-theme p-[15px] flex items-center justify-between">
          <div>
            <div class="text-xs-var text-c-tx3 uppercase tracking-[0.05em] font-medium mb-1">Total RSS Memory</div>
            <div class="text-xl font-semibold tabular-nums">{{ summary.totalRam }} <span class="text-xs font-normal text-c-tx3">GB</span></div>
          </div>
          <div class="w-8 h-8 rounded-lg bg-c-subtle flex items-center justify-center text-c-tx2">
            <l-icon name="memory-stick" is="width:16px;height:16px" />
          </div>
        </div>
        <div class="bg-c-bg border border-c-border rounded-theme p-[15px] flex items-center justify-between">
          <div>
            <div class="text-xs-var text-c-tx3 uppercase tracking-[0.05em] font-medium mb-1">Active (CPU > 1%)</div>
            <div class="text-xl font-semibold tabular-nums">{{ summary.activeCpuProcs }}</div>
          </div>
          <div class="w-8 h-8 rounded-lg bg-c-subtle flex items-center justify-center text-c-tx2">
            <l-icon name="activity" is="width:16px;height:16px" />
          </div>
        </div>
      </div>

      <!-- Search Filter Section -->
      <div class="mb-4">
        <div class="relative w-full max-w-md">
          <span class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none text-c-tx3">
            <l-icon name="search" is="width:14px;height:14px" />
          </span>
          <input type="text" v-model="filterText" placeholder="Search by PID, name, user, or arguments..." class="input pl-9 text-sm" />
        </div>
      </div>

      <!-- Processes Table Layout -->
      <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
        <div class="overflow-x-auto">
          <table class="tbl select-none">
            <thead>
              <tr>
                <th class="cursor-pointer hover:text-c-tx" @click="changeSort('pid')">
                  <div class="flex items-center gap-1">
                    PID
                    <span v-if="sortCol === 'pid'">
                      <l-icon :name="sortOrder === 'asc' ? 'chevron-up' : 'chevron-down'" is="width:12px;height:12px" />
                    </span>
                  </div>
                </th>
                <th class="cursor-pointer hover:text-c-tx w-[45%]" @click="changeSort('arguments')">
                  <div class="flex items-center gap-1">
                    Command / Arguments
                    <span v-if="sortCol === 'arguments'">
                      <l-icon :name="sortOrder === 'asc' ? 'chevron-up' : 'chevron-down'" is="width:12px;height:12px" />
                    </span>
                  </div>
                </th>
                <th class="cursor-pointer hover:text-c-tx text-right" @click="changeSort('threads')">
                  <div class="flex items-center justify-end gap-1">
                    Threads
                    <span v-if="sortCol === 'threads'">
                      <l-icon :name="sortOrder === 'asc' ? 'chevron-up' : 'chevron-down'" is="width:12px;height:12px" />
                    </span>
                  </div>
                </th>
                <th class="cursor-pointer hover:text-c-tx" @click="changeSort('user')">
                  <div class="flex items-center gap-1">
                    User
                    <span v-if="sortCol === 'user'">
                      <l-icon :name="sortOrder === 'asc' ? 'chevron-up' : 'chevron-down'" is="width:12px;height:12px" />
                    </span>
                  </div>
                </th>
                <th class="cursor-pointer hover:text-c-tx text-right" @click="changeSort('ram_gb')">
                  <div class="flex items-center justify-end gap-1">
                    RAM (GB)
                    <span v-if="sortCol === 'ram_gb'">
                      <l-icon :name="sortOrder === 'asc' ? 'chevron-up' : 'chevron-down'" is="width:12px;height:12px" />
                    </span>
                  </div>
                </th>
                <th class="cursor-pointer hover:text-c-tx text-right" @click="changeSort('cpu_percent')">
                  <div class="flex items-center justify-end gap-1">
                    CPU (%)
                    <span v-if="sortCol === 'cpu_percent'">
                      <l-icon :name="sortOrder === 'asc' ? 'chevron-up' : 'chevron-down'" is="width:12px;height:12px" />
                    </span>
                  </div>
                </th>
                <th class="text-right">Action</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="p in processedList" :key="p.pid" class="hover:bg-c-hover/40 transition-colors">
                <td class="mono font-semibold">{{ p.pid }}</td>
                <td class="whitespace-normal py-2 text-c-tx" style="max-width: 0;">
                  <div class="break-all text-xs-var leading-relaxed flex flex-col gap-0.5">
                    <span class="font-medium text-sm text-c-tx truncate" :title="p.name">{{ p.name }}</span>
                    <!-- Arguments expand / collapse logic -->
                    <div class="text-c-tx2 mono mt-0.5 max-w-[480px]">
                      <template v-if="p.arguments.length <= 75">
                        <span class="break-all">{{ p.arguments }}</span>
                      </template>
                      <template v-else>
                        <div class="flex flex-col gap-1">
                          <!-- Single line truncated with hover tooltip when collapsed -->
                          <span v-if="!expandedPids.has(p.pid)" class="block truncate max-w-[450px] cursor-help" :title="p.arguments">
                            {{ p.arguments }}
                          </span>
                          <!-- Wrapped multi-line details when expanded -->
                          <span v-else class="block whitespace-normal break-all">
                            {{ p.arguments }}
                          </span>
                          <div>
                            <button class="text-c-accent font-semibold cursor-pointer hover:underline text-[10px] uppercase tracking-wider focus:outline-none" @click.stop="toggleExpand(p.pid)">
                              {{ expandedPids.has(p.pid) ? 'Show less' : 'Show more' }}
                            </button>
                          </div>
                        </div>
                      </template>
                    </div>
                  </div>
                </td>
                <td class="text-right num font-semibold">
                  <span :style="getHeatmapStyle(p.threads, 'threads', p.pid)">
                    {{ p.threads }}
                  </span>
                </td>
                <td>
                  <badge tone="neutral">{{ p.user }}</badge>
                </td>
                <td class="text-right num font-semibold">
                  <span :style="getHeatmapStyle(p.ram_gb, 'ram', p.pid)">
                    {{ p.ram_gb.toFixed(3) }}
                  </span>
                </td>
                <td class="text-right num font-semibold">
                  <span :style="getHeatmapStyle(p.cpu_percent, 'cpu', p.pid)">
                    {{ p.cpu_percent.toFixed(1) }}%
                  </span>
                </td>
                <td class="text-right">
                  <btn variant="danger" sm @click.stop="killProc(p)">
                    <l-icon name="trash-2" /> Kill
                  </btn>
                </td>
              </tr>
              <!-- Loading state -->
              <tr v-if="appState.fetching.processes && processedList.length === 0">
                <td colspan="7" class="text-center py-10 text-c-tx3">
                  <div class="flex items-center justify-center gap-2">
                    <svg class="animate-spin h-3.5 w-3.5 text-c-accent" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                      <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                    </svg>
                    <span>Loading processes…</span>
                  </div>
                </td>
              </tr>
              <!-- Empty state -->
              <tr v-else-if="processedList.length === 0">
                <td colspan="7" class="text-center py-10 text-c-tx3">
                  <div class="flex flex-col items-center justify-center gap-2">
                    <l-icon name="inbox" is="width:24px;height:24px" />
                    <span>No active processes found matching description.</span>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
  `,
};
