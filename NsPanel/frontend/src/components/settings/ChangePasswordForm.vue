<script setup lang="ts">
/** Change the admin password: current, new (≥ 12), repeat. The server signs
 *  out every other browser and keeps this one signed in.
 *
 * Used inline on Settings → Security and inside ChangePasswordDialog. Reports
 * `state` ({dirty, pending}) so a dialog can guard closing. */
import { computed, reactive, ref, useId, watch } from 'vue';

import { ApiError } from '@/api/client';
import Alert from '@/components/ui/Alert.vue';
import Btn from '@/components/ui/Btn.vue';
import Field from '@/components/ui/Field.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PasswordField from '@/components/ui/PasswordField.vue';
import { useAuthStore } from '@/stores/auth';
import { useUiStore } from '@/stores/ui';
import { first, password as passwordRule, PASSWORD_MIN, required } from '@/utils/validate';

withDefaults(defineProps<{ showCancel?: boolean }>(), { showCancel: false });
const emit = defineEmits<{ done: []; cancel: []; state: [state: { dirty: boolean; pending: boolean }] }>();

const auth = useAuthStore();
const ui = useUiStore();
const formId = useId();

const current = ref('');
const next = ref('');
const repeat = ref('');
const pending = ref(false);
const serverError = ref('');
const submitted = ref(false);
const touched = reactive({ current: false, next: false, repeat: false });

const dirty = computed(() => !!(current.value || next.value || repeat.value));
watch([dirty, pending], () => emit('state', { dirty: dirty.value, pending: pending.value }), { immediate: true });

const currentError = computed(() => required(current.value, 'Your current password'));
const nextError = computed(() =>
  first(
    required(next.value, 'A new password'),
    passwordRule(next.value, PASSWORD_MIN),
    next.value.trim() !== next.value ? 'The password must not start or end with a space.' : '',
    next.value && next.value === current.value ? 'Use a password different from the current one.' : '',
  ),
);
const repeatError = computed(() =>
  repeat.value !== next.value ? 'The passwords do not match.' : required(repeat.value, 'The repeated password'),
);

const shown = (key: keyof typeof touched, message: string) => (submitted.value || touched[key] ? message : '');

function reset(): void {
  current.value = '';
  next.value = '';
  repeat.value = '';
  submitted.value = false;
  touched.current = touched.next = touched.repeat = false;
}

async function submit(): Promise<void> {
  submitted.value = true;
  serverError.value = '';
  if (currentError.value || nextError.value || repeatError.value || pending.value) return;
  pending.value = true;
  try {
    const message = await auth.changePassword(current.value, next.value);
    ui.addToast({ t: 'Password changed', d: message, k: 'ok' });
    reset();
    emit('done');
  } catch (err) {
    serverError.value = err instanceof ApiError || err instanceof Error ? err.message : String(err);
  } finally {
    pending.value = false;
  }
}
</script>

<template>
  <form :id="formId" class="flex flex-col gap-4" novalidate @submit.prevent="submit">
    <Field label="Current password" :error="shown('current', currentError)" required v-slot="f">
      <PasswordField
        :id="f.id"
        v-model="current"
        :described-by="f.describedBy"
        :invalid="f.invalid"
        autocomplete="current-password"
        @focusout="touched.current = true"
      />
    </Field>
    <Field
      label="New password"
      :help="`At least ${PASSWORD_MIN} characters. It applies to every NsPanel on this host.`"
      :error="shown('next', nextError)"
      required
      v-slot="f"
    >
      <PasswordField
        :id="f.id"
        v-model="next"
        :described-by="f.describedBy"
        :invalid="f.invalid"
        generate
        copy
        @focusout="touched.next = true"
      />
    </Field>
    <Field label="Repeat the new password" :error="shown('repeat', repeat || submitted ? repeatError : '')" required v-slot="f">
      <PasswordField
        :id="f.id"
        v-model="repeat"
        :described-by="f.describedBy"
        :invalid="f.invalid"
        @focusout="touched.repeat = true"
      />
    </Field>

    <Alert v-if="serverError" tone="danger">{{ serverError }}</Alert>

    <div class="flex flex-wrap justify-end gap-2">
      <Btn v-if="showCancel" :disabled="pending" @click="emit('cancel')">Cancel</Btn>
      <Btn variant="primary" type="submit" :loading="pending">
        <LIcon name="key-round" /> Change password
      </Btn>
    </div>
  </form>
</template>
