<script setup lang="ts">
/** Unmount a filesystem, optionally removing its /etc/fstab entry. */
import { ref } from 'vue';

import type { DiskNode } from '@/api/system';
import Alert from '@/components/ui/Alert.vue';
import BaseDialog from '@/components/ui/BaseDialog.vue';
import Btn from '@/components/ui/Btn.vue';
import LIcon from '@/components/ui/LIcon.vue';
import { useJobRunner } from '@/composables/useJobs';

const props = defineProps<{ node: DiskNode }>();
const emit = defineEmits<{ close: [] }>();

const { run } = useJobRunner();
const removeFstab = ref(true);
const pending = ref(false);

async function submit(): Promise<void> {
  pending.value = true;
  const target = props.node.mountpoint || props.node.path;
  const result = await run(
    '/api/v1/system/disk/unmount',
    { target, remove_fstab: removeFstab.value },
    { title: `Unmount ${target}` },
  );
  pending.value = false;
  if (result) emit('close');
}
</script>

<template>
  <BaseDialog
    :title="`Unmount ${node.mountpoint}?`"
    :description="`${node.path} · ${node.fstype}`"
    icon="eject"
    tone="warn"
    size="sm"
    :closable="!pending"
    @close="emit('close')"
  >
    <form id="disk-unmount" class="flex flex-col gap-4" novalidate @submit.prevent="submit">
      <Alert tone="warn">
        Programs using files under <span class="mono">{{ node.mountpoint }}</span> lose access. The unmount fails
        if a process still has files open there.
      </Alert>
      <div class="flex flex-col gap-1">
        <label class="flex items-center gap-2 text-sm-var text-c-tx cursor-pointer">
          <input
            v-model="removeFstab"
            type="checkbox"
            class="w-4 h-4 accent-c-accent"
            aria-describedby="disk-unmount-fstab"
            data-autofocus
          />
          Also remove its <span class="mono">/etc/fstab</span> entry
        </label>
        <p id="disk-unmount-fstab" class="m-0 pl-6 text-xs-var text-c-tx2">
          {{
            removeFstab
              ? 'It will not be mounted again at boot. /etc/fstab is backed up and checked after the edit.'
              : 'It is mounted again at the next boot if /etc/fstab lists it.'
          }}
        </p>
      </div>
    </form>
    <template #footer>
      <Btn :disabled="pending" @click="emit('close')">Cancel</Btn>
      <Btn type="submit" form="disk-unmount" variant="danger" :loading="pending">
        <LIcon name="eject" /> Unmount
      </Btn>
    </template>
  </BaseDialog>
</template>
