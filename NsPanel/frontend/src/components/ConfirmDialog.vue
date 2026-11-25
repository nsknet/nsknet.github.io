<script setup lang="ts">
/** Confirmation for any consequential action.
 *
 * `danger` actions get a red verb button ("Delete rule", not "Continue"), and
 * `typeToConfirm` makes the operator type a name (a disk, a rule, a service)
 * before the button enables — for things that cannot be undone.
 */
import { computed, ref } from 'vue';

import type { Confirm } from '@/stores/ui';

import BaseDialog from './ui/BaseDialog.vue';
import Btn from './ui/Btn.vue';

const props = defineProps<{ confirm: Confirm }>();
const emit = defineEmits<{ close: [] }>();

const typed = ref('');
const needsTyping = computed(() => !!props.confirm.typeToConfirm);
const canConfirm = computed(
  () => !needsTyping.value || typed.value.trim() === props.confirm.typeToConfirm,
);

function onYes(): void {
  if (!canConfirm.value) return;
  emit('close');
  props.confirm.onYes?.();
}
</script>

<template>
  <BaseDialog
    :title="confirm.title"
    size="sm"
    :icon="confirm.danger ? 'triangle-alert' : 'info'"
    :tone="confirm.danger ? 'danger' : 'accent'"
    @close="emit('close')"
  >
    <p class="m-0 text-sm-var text-c-tx2 whitespace-pre-line">{{ confirm.body }}</p>
    <ul v-if="confirm.details?.length" class="mt-3 mb-0 pl-5 text-sm-var text-c-tx2 flex flex-col gap-1">
      <li v-for="detail in confirm.details" :key="detail">{{ detail }}</li>
    </ul>
    <form v-if="needsTyping" class="mt-4" @submit.prevent="onYes">
      <label for="confirm-typed" class="block text-sm-var text-c-tx mb-1.5">
        Type <span class="mono font-semibold select-all">{{ confirm.typeToConfirm }}</span> to confirm
      </label>
      <input
        id="confirm-typed"
        v-model="typed"
        class="input mono"
        autocomplete="off"
        autocapitalize="off"
        spellcheck="false"
        data-autofocus
      />
    </form>
    <template #footer>
      <Btn @click="emit('close')">Cancel</Btn>
      <Btn
        :variant="confirm.danger ? 'danger-solid' : 'primary'"
        :disabled="!canConfirm"
        :data-autofocus="needsTyping ? undefined : ''"
        @click="onYes"
      >
        {{ confirm.confirmLabel || 'Continue' }}
      </Btn>
    </template>
  </BaseDialog>
</template>
