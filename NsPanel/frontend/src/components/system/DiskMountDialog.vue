<script setup lang="ts">
/** Mount a filesystem, optionally for good via /etc/fstab. */
import { computed, ref } from 'vue';

import type { DiskNode } from '@/api/system';
import BaseDialog from '@/components/ui/BaseDialog.vue';
import Btn from '@/components/ui/Btn.vue';
import Field from '@/components/ui/Field.vue';
import LIcon from '@/components/ui/LIcon.vue';
import { useJobRunner } from '@/composables/useJobs';

import { MOUNT_POINT } from './disks';

const props = defineProps<{ node: DiskNode }>();
const emit = defineEmits<{ close: [] }>();

const { run } = useJobRunner();

const initial = `/mnt/${props.node.label || props.node.name}`.replace(/[^A-Za-z0-9/_.-]/g, '-');
const mountpoint = ref(initial);
const persist = ref(true);
const touched = ref(false);
const submitted = ref(false);
const pending = ref(false);

const RESERVED = [
  '/',
  '/boot',
  '/etc',
  '/usr',
  '/var',
  '/bin',
  '/sbin',
  '/lib',
  '/proc',
  '/sys',
  '/dev',
  '/run',
  '/root',
  '/tmp',
];

const error = computed(() => {
  const value = mountpoint.value.trim().replace(/\/+$/, '');
  if (!value) return 'Enter an absolute path, e.g. /mnt/data.';
  if (!MOUNT_POINT.test(value)) return 'Use an absolute path of letters, digits, / _ . - (e.g. /mnt/data).';
  if (value.split('/').includes('..')) return 'The path cannot contain "..".';
  if (RESERVED.includes(value)) return `${value} is a system directory; mounting over it hides its contents.`;
  return '';
});

async function submit(): Promise<void> {
  submitted.value = true;
  if (error.value) return;
  const target = mountpoint.value.trim().replace(/\/+$/, '');
  pending.value = true;
  const result = await run(
    '/api/v1/system/disk/mount',
    { device: props.node.path, mountpoint: target, persist: persist.value },
    { title: `Mount ${props.node.path} → ${target}` },
  );
  pending.value = false;
  if (result) emit('close');
}
</script>

<template>
  <BaseDialog
    :title="`Mount ${node.path}`"
    :description="`${node.fstype} filesystem${node.label ? ` labelled ${node.label}` : ''}.`"
    icon="plug"
    tone="accent"
    size="sm"
    :dirty="mountpoint !== initial"
    :closable="!pending"
    @close="emit('close')"
  >
    <form id="disk-mount" class="flex flex-col gap-4" novalidate @submit.prevent="submit">
      <Field
        v-slot="f"
        label="Mount point"
        required
        :error="submitted || touched ? error : ''"
        help="Absolute path. The directory is created if it does not exist."
      >
        <input
          :id="f.id"
          v-model="mountpoint"
          class="input mono"
          autocomplete="off"
          spellcheck="false"
          placeholder="/mnt/data"
          data-autofocus
          :aria-describedby="f.describedBy"
          :aria-invalid="f.invalid"
          @blur="touched = true"
        />
      </Field>
      <div class="flex flex-col gap-1">
        <label class="flex items-center gap-2 text-sm-var text-c-tx cursor-pointer">
          <input
            v-model="persist"
            type="checkbox"
            class="w-4 h-4 accent-c-accent"
            aria-describedby="disk-mount-persist"
          />
          Mount again at boot (<span class="mono">/etc/fstab</span>)
        </label>
        <p id="disk-mount-persist" class="m-0 pl-6 text-xs-var text-c-tx2">
          Adds a UUID entry with <span class="mono">nofail</span>. <span class="mono">/etc/fstab</span> is
          backed up first, checked after the edit, and restored if the check fails.
        </p>
      </div>
    </form>
    <template #footer>
      <Btn :disabled="pending" @click="emit('close')">Cancel</Btn>
      <Btn type="submit" form="disk-mount" variant="primary" :loading="pending">
        <LIcon name="plug" /> Mount
      </Btn>
    </template>
  </BaseDialog>
</template>
