<script setup lang="ts">
/** Ctrl/⌘+K jump list: every screen plus each site, service and tool.
 *
 * WAI-ARIA combobox with a listbox popup: focus stays in the input, ↑/↓ move
 * the active option (aria-activedescendant), Enter opens it. Escape, the focus
 * trap and focus return come from useDialog — no keydown listener of its own.
 */
import { storeToRefs } from 'pinia';
import { computed, nextTick, onMounted, ref, useId, watch } from 'vue';
import { useRouter } from 'vue-router';

import { useDialog } from '@/composables/useDialog';
import { navItems } from '@/router';
import { useServicesStore } from '@/stores/services';
import { useSitesStore } from '@/stores/sites';
import { useToolsStore } from '@/stores/tools';

import LIcon from './ui/LIcon.vue';

interface Entry {
  id: string;
  group: string;
  label: string;
  hint: string;
  icon: string;
  to: string;
}

const emit = defineEmits<{ close: [] }>();

const router = useRouter();
const sitesStore = useSitesStore();
const servicesStore = useServicesStore();
const toolsStore = useToolsStore();
const { sites } = storeToRefs(sitesStore);
const { services } = storeToRefs(servicesStore);
const { tools } = storeToRefs(toolsStore);

const panel = ref<HTMLElement | null>(null);
const query = ref('');
const active = ref(0);
const base = useId();
const listId = `${base}-list`;
const titleId = `${base}-title`;

/** The platform's shortcut modifier, shown the same way as in the header. */
const modKey = /Mac|iPhone|iPad/.test(navigator.platform) ? '⌘' : 'Ctrl';

const MAX_PER_GROUP = 6;

const entries = computed<Entry[]>(() => [
  ...navItems.map((item) => ({
    id: `nav-${item.key}`,
    group: 'Go to',
    label: item.label,
    hint: item.group,
    icon: item.icon,
    to: item.path,
  })),
  {
    id: 'action-new-app',
    group: 'Go to',
    label: 'Create app',
    hint: 'Apps',
    icon: 'plus',
    to: '/apps/new',
  },
  ...sites.value.map((site) => ({
    id: `site-${site.slug}`,
    group: 'Sites',
    label: site.name,
    hint: site.access,
    icon: 'globe',
    to: `/apps/site/${encodeURIComponent(site.slug)}`,
  })),
  ...services.value.map((service) => ({
    id: `service-${service.name}`,
    group: 'Services',
    label: service.name,
    hint: service.status,
    icon: 'server',
    to: `/apps/service/${encodeURIComponent(service.name)}`,
  })),
  ...tools.value.map((tool) => ({
    id: `tool-${tool.id}`,
    group: 'Tools',
    label: tool.name,
    hint: tool.installed ? (tool.version ?? tool.state) : 'not installed',
    icon: 'package',
    to: `/tools?q=${encodeURIComponent(tool.name)}`,
  })),
]);

const results = computed<Entry[]>(() => {
  const q = query.value.trim().toLowerCase();
  const counts: Record<string, number> = {};
  return entries.value.filter((entry) => {
    if (q && !`${entry.label} ${entry.hint} ${entry.group}`.toLowerCase().includes(q)) return false;
    counts[entry.group] = (counts[entry.group] ?? 0) + 1;
    return counts[entry.group] <= MAX_PER_GROUP;
  });
});

/** Results split into headed groups, each row keeping its flat index. */
const sections = computed(() => {
  const out: { group: string; rows: { entry: Entry; index: number }[] }[] = [];
  results.value.forEach((entry, index) => {
    const last = out[out.length - 1];
    if (last?.group === entry.group) last.rows.push({ entry, index });
    else out.push({ group: entry.group, rows: [{ entry, index }] });
  });
  return out;
});

const optionId = (index: number) => `${base}-opt-${index}`;
const activeId = computed(() => (results.value.length ? optionId(active.value) : undefined));

watch(query, () => (active.value = 0));

function close(): void {
  emit('close');
}

useDialog(panel, close);

function go(entry: Entry | undefined): void {
  if (!entry) return;
  close();
  void router.push(entry.to);
}

function setActive(index: number): void {
  active.value = index;
  void nextTick(() => document.getElementById(optionId(index))?.scrollIntoView({ block: 'nearest' }));
}

function onInputKeydown(event: KeyboardEvent): void {
  const total = results.value.length;
  if (event.key === 'Enter') {
    event.preventDefault();
    go(results.value[active.value]);
    return;
  }
  if (!total) return;
  const next: Record<string, number> = {
    ArrowDown: (active.value + 1) % total,
    ArrowUp: (active.value - 1 + total) % total,
    PageDown: Math.min(total - 1, active.value + 5),
    PageUp: Math.max(0, active.value - 5),
  };
  if (event.key in next) {
    event.preventDefault();
    setActive(next[event.key]);
  }
}

onMounted(() => {
  // The palette searches data other screens own; fetch whatever is still missing.
  if (!sitesStore.loaded) void sitesStore.load({ silent: true });
  if (!servicesStore.loaded) void servicesStore.load({ silent: true });
  if (!toolsStore.loaded) void toolsStore.load({ silent: true });
});
</script>

<template>
  <!-- Backdrop click closes; the keyboard path is Esc via the dialog stack. -->
  <!-- eslint-disable-next-line vuejs-accessibility/no-static-element-interactions -->
  <div
    class="fixed inset-0 z-[210] flex justify-center items-start pt-[10vh] px-4 bg-c-overlay backdrop-blur-[2px] animate-fade"
    @mousedown.self="close"
  >
    <div
      ref="panel"
      role="dialog"
      aria-modal="true"
      :aria-labelledby="titleId"
      tabindex="-1"
      class="w-full max-w-[560px] bg-c-card border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop outline-none"
    >
      <h2 :id="titleId" class="sr-only">Search and jump</h2>
      <div class="flex items-center gap-2.5 px-4 h-12 border-b border-c-border">
        <LIcon is="width:16px;height:16px;color:var(--text-3);flex-shrink:0" name="search" />
        <input
          v-model="query"
          data-autofocus
          type="text"
          role="combobox"
          aria-autocomplete="list"
          aria-expanded="true"
          :aria-controls="listId"
          :aria-activedescendant="activeId"
          aria-label="Search screens, sites, services and tools"
          class="flex-1 min-w-0 bg-transparent outline-none border-0 text-sm-var text-c-tx placeholder:text-c-tx3"
          placeholder="Search screens, sites, services, tools…"
          autocomplete="off"
          spellcheck="false"
          @keydown="onInputKeydown"
        />
        <button
          type="button"
          class="shrink-0 h-7 px-2 rounded-md border border-c-border bg-c-subtle mono text-2xs-var text-c-tx2 hover:text-c-tx"
          aria-label="Close"
          @click="close"
        >
          Esc
        </button>
      </div>

      <div class="max-h-[min(420px,60vh)] overflow-y-auto p-1.5">
        <ul :id="listId" role="listbox" aria-label="Results" class="m-0 p-0 list-none">
          <li v-for="section in sections" :key="section.group" role="presentation" class="mb-1 last:mb-0">
            <div
              :id="`${base}-grp-${section.group.replace(/\W+/g, '')}`"
              class="px-2.5 pt-2 pb-1 text-2xs-var uppercase tracking-[0.08em] font-semibold text-c-tx3"
              aria-hidden="true"
            >
              {{ section.group }}
            </div>
            <ul
              role="group"
              :aria-labelledby="`${base}-grp-${section.group.replace(/\W+/g, '')}`"
              class="m-0 p-0 list-none"
            >
              <!-- Focus stays in the search box (aria-activedescendant); arrows and Enter drive options. -->
              <!-- eslint-disable-next-line vuejs-accessibility/click-events-have-key-events, vuejs-accessibility/interactive-supports-focus -->
              <li
                v-for="row in section.rows"
                :id="optionId(row.index)"
                :key="row.entry.id"
                role="option"
                :aria-selected="row.index === active"
                :class="[
                  'flex items-center gap-2.5 px-2.5 h-9 rounded-md text-sm-var text-c-tx cursor-pointer',
                  row.index === active ? 'bg-c-hover' : '',
                ]"
                @mousemove="active = row.index"
                @mousedown.prevent
                @click="go(row.entry)"
              >
                <LIcon is="width:15px;height:15px;color:var(--text-2);flex-shrink:0" :name="row.entry.icon" />
                <span class="truncate">{{ row.entry.label }}</span>
                <span class="ml-auto pl-3 truncate mono text-xs-var text-c-tx3 max-w-[45%]">{{
                  row.entry.hint
                }}</span>
              </li>
            </ul>
          </li>
        </ul>
        <p v-if="!results.length" class="m-0 text-center text-c-tx2 text-sm-var py-10" role="status">
          No results for “{{ query }}”
        </p>
      </div>

      <div
        class="hidden sm:flex items-center gap-4 px-4 h-9 border-t border-c-border bg-c-elev text-2xs-var text-c-tx3"
        aria-hidden="true"
      >
        <span><kbd class="mono">↑ ↓</kbd> move</span>
        <span><kbd class="mono">↵</kbd> open</span>
        <span><kbd class="mono">Esc</kbd> close</span>
        <span class="ml-auto"
          ><kbd class="mono">{{ modKey }} K</kbd> opens this anywhere</span
        >
      </div>
    </div>
  </div>
</template>
