<script setup lang="ts">
/** Block devices: disks and their partitions, usage, mount/unmount and format. */
import { storeToRefs } from 'pinia';
import { computed, ref } from 'vue';

import type { DiskNode } from '@/api/system';
import DiskFormatDialog from '@/components/system/DiskFormatDialog.vue';
import DiskMountDialog from '@/components/system/DiskMountDialog.vue';
import DiskUnmountDialog from '@/components/system/DiskUnmountDialog.vue';
import {
  canMount,
  deviceSummary,
  flatten,
  formatBlock,
  formattable,
  isMounted,
  unmountBlock,
  type DiskRow,
} from '@/components/system/disks';
import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import CardHeader from '@/components/ui/CardHeader.vue';
import DataTable from '@/components/ui/DataTable.vue';
import LIcon from '@/components/ui/LIcon.vue';
import MetricCard from '@/components/ui/MetricCard.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import type { Column } from '@/components/ui/types';
import { useRefresh } from '@/composables/useRefresh';
import { useSystemStore } from '@/stores/system';
import { gb, usageTone } from '@/utils/format';

const { refresh, refreshing } = useRefresh();
const system = useSystemStore();
const { disks, loadingDisks, disksError, host } = storeToRefs(system);

const rows = computed(() => flatten(disks.value));
const diskCount = computed(() => disks.value.filter((d) => d.type === 'disk').length);

const columns: Column<DiskRow>[] = [
  { key: 'name', label: 'Device' },
  { key: 'size_gb', label: 'Size', align: 'right', class: 'num' },
  { key: 'fstype', label: 'Filesystem', hideOnMobile: true },
  { key: 'mountpoint', label: 'Mounted on' },
  { key: 'use_percent', label: 'Usage', hideOnMobile: true, class: 'min-w-[160px]' },
  { key: 'actions', label: 'Actions', srOnlyLabel: true, align: 'right' },
];

type Dialog = { kind: 'mount' | 'unmount' | 'format'; node: DiskNode } | null;
const dialog = ref<Dialog>(null);

function reasonId(row: DiskRow): string {
  return `format-lock-${row.kname || row.name}`;
}
</script>

<template>
  <section>
    <PageHeader
      title="Storage"
      :subtitle="
        rows.length
          ? `${diskCount} disk${diskCount === 1 ? '' : 's'} · ${rows.length} block devices`
          : 'Disks, partitions and mount points.'
      "
    >
      <Btn :loading="refreshing" @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
    </PageHeader>

    <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-4 max-w-[720px]">
      <MetricCard
        label="Root filesystem /"
        icon="hard-drive"
        :value="host.disk.used.toFixed(1)"
        :unit="`/ ${host.disk.total.toFixed(1)} GB`"
        :sub="`${Math.round(host.disk.pct)}% used · ${gb(Math.max(0, host.disk.total - host.disk.used))} free`"
        :percent="host.disk.pct"
      />
      <MetricCard
        label="Swap"
        icon="layers"
        :value="host.swap.total > 0 ? host.swap.used.toFixed(1) : 'Off'"
        :unit="host.swap.total > 0 ? `/ ${host.swap.total.toFixed(1)} GB` : ''"
        :sub="host.swap.total > 0 ? `${Math.round(host.swap.pct)}% used` : 'Set up swap on the Host screen'"
        :percent="host.swap.total > 0 ? host.swap.pct : null"
      />
    </div>

    <Card class="overflow-clip">
      <CardHeader title="Block devices" icon="hard-drive" subtitle="From lsblk" />
      <DataTable
        :columns="columns"
        :rows="rows"
        :row-key="(row) => `${row.level}:${row.path}:${row.mountpoint}`"
        label="Disks and partitions"
        :loading="loadingDisks"
        :error="disksError"
        empty-icon="hard-drive"
        empty-title="No block devices reported"
        empty-hint="lsblk is not available on this host (for example when the panel runs off Linux)."
        @retry="system.loadDisks()"
      >
        <template #cell-name="{ row }">
          <div
            class="flex items-start gap-2 min-w-[180px] max-w-[340px] whitespace-normal"
            :style="{ paddingLeft: `${row.level * 18}px` }"
          >
            <LIcon
              is="width:14px;height:14px;margin-top:3px;flex-shrink:0;color:var(--text-3)"
              :name="row.level === 0 ? 'hard-drive' : 'box'"
            />
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-1.5">
                <span class="mono" :class="row.level === 0 ? 'font-semibold' : ''">{{ row.path }}</span>
                <Badge tone="muted">{{ row.type }}</Badge>
                <Badge v-if="row.system" tone="accent">system</Badge>
                <Badge v-if="row.removable" tone="info">removable</Badge>
                <Badge v-if="row.readonly" tone="neutral">read-only</Badge>
              </div>
              <div v-if="row.label || deviceSummary(row)" class="text-xs-var text-c-tx2 mt-0.5 truncate">
                <span v-if="row.label" class="mono">{{ row.label }}</span>
                <span v-if="row.label && deviceSummary(row)"> · </span>{{ deviceSummary(row) }}
              </div>
              <div class="md:hidden text-xs-var text-c-tx2 mt-0.5 mono">{{ row.fstype }}</div>
              <div
                v-if="formattable(row) && formatBlock(row)"
                :id="reasonId(row)"
                class="text-xs-var text-c-tx3 mt-0.5 flex items-center gap-1"
              >
                <LIcon is="width:11px;height:11px;flex-shrink:0" name="lock" />
                <span>{{ formatBlock(row) }}</span>
              </div>
            </div>
          </div>
        </template>
        <template #cell-size_gb="{ row }">
          <span class="tabular-nums whitespace-nowrap">{{ row.size_gb ? gb(row.size_gb) : '—' }}</span>
        </template>
        <template #cell-fstype="{ row }">
          <span class="mono text-c-tx2">{{ row.fstype || '—' }}</span>
        </template>
        <template #cell-mountpoint="{ row }">
          <span class="mono" :class="row.mountpoint ? '' : 'text-c-tx3'">{{ row.mountpoint || '—' }}</span>
        </template>
        <template #cell-use_percent="{ row }">
          <template v-if="row.use_percent !== null">
            <div class="text-xs-var text-c-tx2 tabular-nums whitespace-nowrap">
              {{ gb(row.used_gb) }} of {{ gb(row.size_gb) }} · {{ Math.round(row.use_percent) }}%
            </div>
            <div
              :class="['bar !mt-1.5', `bar-${usageTone(row.use_percent)}`]"
              role="meter"
              :aria-label="`${row.path} usage`"
              :aria-valuenow="Math.round(row.use_percent)"
              aria-valuemin="0"
              aria-valuemax="100"
            >
              <span :style="{ width: `${Math.min(100, row.use_percent)}%` }"></span>
            </div>
          </template>
          <span v-else class="text-c-tx3">—</span>
        </template>
        <template #cell-actions="{ row }">
          <div class="flex items-center justify-end gap-1.5 whitespace-nowrap">
            <template v-if="isMounted(row)">
              <Btn
                v-if="!unmountBlock(row)"
                sm
                :aria-label="`Unmount ${row.mountpoint}`"
                @click="dialog = { kind: 'unmount', node: row }"
              >
                <LIcon name="eject" /> Unmount
              </Btn>
            </template>
            <Btn
              v-else-if="canMount(row)"
              sm
              :aria-label="`Mount ${row.path}`"
              @click="dialog = { kind: 'mount', node: row }"
            >
              <LIcon name="plug" /> Mount
            </Btn>
            <Btn
              v-if="formattable(row)"
              variant="danger"
              sm
              :disabled="!!formatBlock(row)"
              :aria-label="`Format ${row.path}`"
              :aria-describedby="formatBlock(row) ? reasonId(row) : undefined"
              @click="dialog = { kind: 'format', node: row }"
            >
              <LIcon name="eraser" /> Format
            </Btn>
          </div>
        </template>
      </DataTable>
    </Card>

    <DiskMountDialog v-if="dialog?.kind === 'mount'" :node="dialog.node" @close="dialog = null" />
    <DiskUnmountDialog v-if="dialog?.kind === 'unmount'" :node="dialog.node" @close="dialog = null" />
    <DiskFormatDialog v-if="dialog?.kind === 'format'" :node="dialog.node" @close="dialog = null" />
  </section>
</template>
