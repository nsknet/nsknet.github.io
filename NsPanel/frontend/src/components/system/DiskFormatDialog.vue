<script setup lang="ts">
/** Format a free device: choose the filesystem and label, then confirm by
 *  typing the device path. The backend refuses (409) a device in use. */
import { computed, ref } from 'vue';

import type { DiskNode } from '@/api/system';
import Alert from '@/components/ui/Alert.vue';
import BaseDialog from '@/components/ui/BaseDialog.vue';
import Btn from '@/components/ui/Btn.vue';
import Field from '@/components/ui/Field.vue';
import LIcon from '@/components/ui/LIcon.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useSystemStore } from '@/stores/system';
import { useUiStore } from '@/stores/ui';
import { gb } from '@/utils/format';

import { deviceSummary, FS_TYPES, LABEL, type FsType } from './disks';

const props = defineProps<{ node: DiskNode }>();
const emit = defineEmits<{ close: [] }>();

const ui = useUiStore();
const { run } = useJobRunner();

const FS_HELP: Record<FsType, string> = {
  ext4: 'The Linux default. Use this unless you have a reason not to.',
  xfs: 'Good for large files; cannot be shrunk later.',
  btrfs: 'Snapshots and checksums.',
  vfat: 'Readable by Windows and macOS (FAT32, files up to 4 GB).',
  ntfs: 'For drives shared with Windows.',
  ext3: 'Older ext; prefer ext4.',
  ext2: 'No journal; prefer ext4.',
};

const fstype = ref<FsType>(FS_TYPES.includes(props.node.fstype as FsType) ? (props.node.fstype as FsType) : 'ext4');
const label = ref(props.node.label);
const pending = ref(false);

const labelError = computed(() => {
  const value = label.value.trim();
  if (!value) return '';
  if (!LABEL.test(value)) return 'Letters, digits, . _ - only, up to 32 characters.';
  if (fstype.value === 'vfat' && value.length > 11) return 'FAT labels are at most 11 characters.';
  if (fstype.value === 'xfs' && value.length > 12) return 'XFS labels are at most 12 characters.';
  if (fstype.value.startsWith('ext') && value.length > 16) return 'ext labels are at most 16 characters.';
  return '';
});

const partitions = computed(() => (props.node.children ?? []).length);

async function format(): Promise<void> {
  pending.value = true;
  const result = await run(
    '/api/v1/system/disk/format',
    { device: props.node.path, fstype: fstype.value, label: label.value.trim() },
    { title: `Format ${props.node.path} as ${fstype.value}` },
  );
  pending.value = false;
  if (result) emit('close');
  // A 409 means the device became busy: show its current state.
  else void useSystemStore().loadDisks({ silent: true });
}

function submit(): void {
  if (labelError.value) return;
  const node = props.node;
  const summary = deviceSummary(node);
  ui.confirmThen(
    `Erase ${node.path}?`,
    `${node.path} is formatted as ${fstype.value}. All data on it will be erased. This cannot be undone.`,
    () => void format(),
    {
      danger: true,
      confirmLabel: 'Erase and format',
      typeToConfirm: node.path,
      details: [
        `Size: ${gb(node.size_gb)}${node.type === 'disk' ? ' (whole disk)' : ''}`,
        `Model: ${summary || 'unknown'}`,
        `Current label: ${node.label || 'none'} · filesystem: ${node.fstype || 'none'}`,
        ...(partitions.value
          ? [`Its ${partitions.value} partition${partitions.value === 1 ? '' : 's'} and the partition table are destroyed.`]
          : []),
        'All data on the device will be erased.',
      ],
    },
  );
}
</script>

<template>
  <BaseDialog
    :title="`Format ${node.path}`"
    :description="`${gb(node.size_gb)}${deviceSummary(node) ? ` · ${deviceSummary(node)}` : ''}`"
    icon="eraser"
    tone="danger"
    :closable="!pending"
    @close="emit('close')"
  >
    <form id="disk-format" class="flex flex-col gap-4" novalidate @submit.prevent="submit">
      <Alert tone="danger" title="Everything on this device is erased">
        <template v-if="node.fstype || node.label">
          It now holds a <span class="mono">{{ node.fstype || 'unknown' }}</span> filesystem{{
            node.label ? ` labelled ${node.label}` : ''
          }}.
        </template>
        <template v-if="partitions"> Its {{ partitions }} partition{{ partitions === 1 ? '' : 's' }} are removed too.</template>
        You will type the device path to confirm.
      </Alert>
      <Field v-slot="f" label="Filesystem" :help="FS_HELP[fstype]">
        <select :id="f.id" v-model="fstype" class="input" data-autofocus :aria-describedby="f.describedBy">
          <option v-for="fs in FS_TYPES" :key="fs" :value="fs">{{ fs }}</option>
        </select>
      </Field>
      <Field v-slot="f" label="Label" :error="labelError" help="Optional. Shown by lsblk and file managers.">
        <input
          :id="f.id"
          v-model="label"
          class="input mono"
          autocomplete="off"
          spellcheck="false"
          placeholder="data"
          :aria-describedby="f.describedBy"
          :aria-invalid="f.invalid"
        />
      </Field>
    </form>
    <template #footer>
      <Btn :disabled="pending" @click="emit('close')">Cancel</Btn>
      <Btn type="submit" form="disk-format" variant="danger" :loading="pending">
        <LIcon name="eraser" /> Format…
      </Btn>
    </template>
  </BaseDialog>
</template>
