<script setup lang="ts">
/** Change the admin password in a dialog (the shell mounts it; Settings →
 *  Security has the same form inline). Other browsers are signed out by the server. */
import { onMounted, ref } from 'vue';

import ChangePasswordForm from './settings/ChangePasswordForm.vue';
import BaseDialog from './ui/BaseDialog.vue';

const emit = defineEmits<{ close: [] }>();

const dirty = ref(false);
const pending = ref(false);
const body = ref<HTMLElement | null>(null);

function onState(state: { dirty: boolean; pending: boolean }): void {
  dirty.value = state.dirty;
  pending.value = state.pending;
}

// BaseDialog focuses its close button; start in the first field instead.
onMounted(() => body.value?.querySelector<HTMLElement>('input')?.focus());
</script>

<template>
  <BaseDialog
    title="Change admin password"
    description="Every other browser signed in to this panel is signed out."
    icon="key-round"
    tone="accent"
    size="sm"
    :dirty="dirty"
    :closable="!pending"
    @close="emit('close')"
  >
    <div ref="body">
      <ChangePasswordForm show-cancel @done="emit('close')" @cancel="emit('close')" @state="onState" />
    </div>
  </BaseDialog>
</template>
