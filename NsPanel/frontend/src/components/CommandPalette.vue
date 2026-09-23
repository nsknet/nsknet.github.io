<script setup lang="ts">
/** Ctrl/⌘+K jump list: every screen plus each site, service and tool. */
import { storeToRefs } from 'pinia';
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue';
import { useRouter } from 'vue-router';

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

const query = ref('');
const active = ref(0);
const input = ref<HTMLInputElement | null>(null);
const list = ref<HTMLElement | null>(null);

const MAX_PER_GROUP = 6;

const entries = computed<Entry[]>(() => [
  ...navItems.map((item) => ({
    id: `nav:${item.key}`,
    group: 'Go to',
    label: item.label,
    hint: item.group,
    icon: item.icon,
    to: item.path,
  })),
  {
    id: 'action:new-site',
    group: 'Go to',
    label: 'Create site',
    hint: 'Sites',
    icon: 'plus',
    to: '/sites/new',
  },
  ...sites.value.map((site) => ({
    id: `site:${site.slug}`,
    group: 'Sites',
    label: site.name,
    hint: site.access,
    icon: 'globe',
    to: `/sites/${site.slug}`,
  })),
  ...services.value.map((service) => ({
    id: `service:${service.name}`,
    group: 'Services',
    label: service.name,
    hint: service.status,
    icon: 'server',
    to: `/services/${service.name}`,
  })),
  ...tools.value.map((tool) => ({
    id: `tool:${tool.id}`,
    group: 'Tools',
    label: tool.name,
    hint: tool.installed ? (tool.version ?? tool.state) : 'not installed',
    icon: 'wrench',
    to: `/tools?q=${encodeURIComponent(tool.name)}`,
  })),
]);

const results = computed<Entry[]>(() => {
  const q = query.value.trim().toLowerCase();
  const counts: Record<string, number> = {};
  return entries.value.filter((entry) => {
    if (q && !`${entry.label} ${entry.hint}`.toLowerCase().includes(q)) return false;
    counts[entry.group] = (counts[entry.group] ?? 0) + 1;
    return counts[entry.group] <= MAX_PER_GROUP;
  });
});

/** Results split into their headed sections, keeping each row's flat index. */
const sections = computed(() => {
  const out: { group: string; rows: { entry: Entry; index: number }[] }[] = [];
  results.value.forEach((entry, index) => {
    const last = out[out.length - 1];
    if (last?.group === entry.group) last.rows.push({ entry, index });
    else out.push({ group: entry.group, rows: [{ entry, index }] });
  });
  return out;
});

watch(query, () => (active.value = 0));

function go(entry: Entry | undefined): void {
  if (!entry) return;
  emit('close');
  void router.push(entry.to);
}

function move(step: number): void {
  const total = results.value.length;
  if (!total) return;
  active.value = (active.value + step + total) % total;
  void nextTick(() => {
    list.value?.querySelector(`[data-index="${active.value}"]`)?.scrollIntoView({ block: 'nearest' });
  });
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key === 'Escape') emit('close');
  else if (event.key === 'ArrowDown') {
    event.preventDefault();
    move(1);
  } else if (event.key === 'ArrowUp') {
    event.preventDefault();
    move(-1);
  } else if (event.key === 'Enter') {
    event.preventDefault();
    go(results.value[active.value]);
  }
}

onMounted(() => {
  document.addEventListener('keydown', onKeydown);
  void nextTick(() => input.value?.focus());
  // The palette searches data other screens own; fetch whatever is still missing.
  if (!sitesStore.loaded) void sitesStore.load();
  if (!servicesStore.loaded) void servicesStore.load();
  if (!toolsStore.loaded) void toolsStore.load();
});
onUnmounted(() => document.removeEventListener('keydown', onKeydown));
</script>

<template>
  <div
    class="fixed inset-0 z-[210] flex justify-center items-start pt-[12vh] px-4 bg-black/40 backdrop-blur-[4px] animate-fade"
    @click.self="emit('close')"
  >
    <div
      class="w-full max-w-[560px] bg-c-card border border-c-border rounded-theme-lg shadow-lg overflow-hidden animate-pop"
      role="dialog"
      aria-label="Command palette"
    >
      <div class="flex items-center gap-2.5 px-4 h-12 border-b border-c-border">
        <LIcon name="search" is="width:16px;height:16px;color:var(--text-3)" />
        <input
          ref="input"
          v-model="query"
          class="flex-1 bg-transparent outline-none border-0 text-sm-var text-c-tx placeholder:text-c-tx3"
          placeholder="Search screens, sites, services, tools…"
          autocomplete="off"
          spellcheck="false"
        />
        <kbd
          class="mono text-[10px] text-c-tx3 px-1.5 py-0.5 rounded border border-c-border bg-c-subtle"
          >ESC</kbd
        >
      </div>

      <div ref="list" class="max-h-[min(420px,60vh)] overflow-y-auto p-1.5">
        <div v-if="!results.length" class="text-center text-c-tx2 text-sm-var py-10">
          No results for “{{ query }}”
        </div>
        <div v-for="section in sections" :key="section.group" class="mb-1 last:mb-0">
          <div
            class="px-2.5 pt-2 pb-1 text-[10px] uppercase tracking-[0.08em] font-semibold text-c-tx3"
          >
            {{ section.group }}
          </div>
          <button
            v-for="row in section.rows"
            :key="row.entry.id"
            :data-index="row.index"
            :class="[
              'w-full flex items-center gap-2.5 px-2.5 h-9 rounded-md text-left border-0 bg-transparent text-c-tx text-sm-var',
              row.index === active ? 'bg-c-hover' : '',
            ]"
            @mouseenter="active = row.index"
            @click="go(row.entry)"
          >
            <LIcon :name="row.entry.icon" is="width:15px;height:15px;color:var(--text-2)" />
            <span class="truncate">{{ row.entry.label }}</span>
            <span class="ml-auto pl-3 truncate mono text-xs-var text-c-tx3 max-w-[45%]">{{
              row.entry.hint
            }}</span>
          </button>
        </div>
      </div>

      <div
        class="flex items-center gap-4 px-4 h-9 border-t border-c-border bg-c-elev text-[11px] text-c-tx3"
      >
        <span><kbd class="mono">↑↓</kbd> navigate</span>
        <span><kbd class="mono">↵</kbd> open</span>
        <span class="ml-auto"><kbd class="mono">Ctrl K</kbd> toggle</span>
      </div>
    </div>
  </div>
</template>
