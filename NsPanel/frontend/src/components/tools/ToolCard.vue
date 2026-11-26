<script setup lang="ts">
/** One tool: logo, name, description, version, service state, ports, and its actions. */
import { computed } from 'vue';

import type { Tool } from '@/api/types';
import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import LIcon from '@/components/ui/LIcon.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import ToolLogo from '@/components/ui/ToolLogo.vue';

const props = defineProps<{ tool: Tool; busy?: boolean }>();
const emit = defineEmits<{ install: []; reinstall: []; uninstall: []; password: [] }>();

const dim = computed(() => !props.tool.installed || ['stopped', 'inactive'].includes(props.tool.state));

/** Installed: the ports it listens on; available: the ports an install opens. */
const ports = computed(() =>
  props.tool.installed
    ? props.tool.ports
    : props.tool.firewallPorts.length
      ? props.tool.firewallPorts.join(', ')
      : null,
);

const facts = computed(() => {
  const rows: { key: string; label: string; value: string }[] = [];
  if (props.tool.installed) rows.push({ key: 'version', label: 'Version', value: props.tool.version ?? '—' });
  if (ports.value)
    rows.push({ key: 'ports', label: props.tool.installed ? 'Ports' : 'Opens', value: ports.value });
  for (const [label, value] of props.tool.diag ?? []) rows.push({ key: `diag-${label}`, label, value });
  return rows;
});

const headingId = computed(() => `tool-${props.tool.id}-name`);
</script>

<template>
  <Card
    as="article"
    :tone="tool.installed ? (tool.state === 'failed' ? 'danger' : 'default') : 'muted'"
    :class="['flex flex-col gap-3 p-4 min-w-0', tool.installed ? '' : 'border-dashed']"
    :aria-labelledby="headingId"
  >
    <div class="flex items-start gap-3 min-w-0">
      <ToolLogo :logo="tool.logo" :name="tool.name" :color="tool.color" :dim="dim" />
      <div class="flex-1 min-w-0">
        <div class="flex items-start justify-between gap-2 min-w-0">
          <h2
            :id="headingId"
            class="m-0 text-base-var font-semibold tracking-[-0.01em] truncate"
            :title="tool.name"
          >
            {{ tool.name }}
          </h2>
          <StatusBadge v-if="tool.installed" :status="tool.state" />
          <Badge v-else tone="neutral">available</Badge>
        </div>
        <p class="m-0 mt-0.5 text-xs-var text-c-tx2 leading-normal">{{ tool.desc }}</p>
      </div>
    </div>

    <dl
      v-if="facts.length"
      class="m-0 grid grid-cols-[auto_1fr] gap-x-3.5 gap-y-1.5 pt-2.5 border-t border-c-border text-xs-var"
    >
      <template v-for="fact in facts" :key="fact.key">
        <dt class="text-c-tx2">{{ fact.label }}</dt>
        <dd class="m-0 mono tabular-nums text-c-tx min-w-0 break-all">{{ fact.value }}</dd>
      </template>
    </dl>

    <div v-if="!tool.installed && tool.requiresPassword" class="flex flex-wrap gap-1.5">
      <Badge tone="neutral"><LIcon is="width:12px;height:12px" name="key-round" /> asks for a password</Badge>
    </div>

    <div class="flex flex-wrap items-center gap-1.5 mt-auto pt-1">
      <template v-if="tool.installed">
        <Btn sm :disabled="busy" @click="emit('reinstall')"> <LIcon name="rotate-cw" /> Re-install </Btn>
        <Btn v-if="tool.canChangePassword" sm :disabled="busy" @click="emit('password')">
          <LIcon name="key-round" /> Password
        </Btn>
        <Btn
          v-if="tool.canUninstall"
          sm
          variant="danger"
          class="ml-auto"
          :disabled="busy"
          :aria-label="`Uninstall ${tool.name}`"
          @click="emit('uninstall')"
        >
          <LIcon name="trash-2" /> Uninstall
        </Btn>
      </template>
      <Btn v-else sm variant="primary" :disabled="busy" @click="emit('install')">
        <LIcon name="download" /> Install
      </Btn>
      <span v-if="busy" class="inline-flex items-center gap-1.5 text-xs-var text-c-tx2" role="status">
        <span
          class="w-3 h-3 rounded-full border-[1.5px] border-c-bstrong border-t-c-accent animate-spin"
          aria-hidden="true"
        ></span>
        Job running…
      </span>
    </div>
  </Card>
</template>
