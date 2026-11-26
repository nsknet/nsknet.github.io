<script setup lang="ts">
/** Delete a Cloudflare tunnel service together with its Cloudflare side
 *  (DNS record, ingress rule, the tunnel itself). Needs the API token again. */
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';

import type { Tunnel } from '@/api/types';
import CloudflareTokenHelp from '@/components/CloudflareTokenHelp.vue';
import BaseDialog from '@/components/ui/BaseDialog.vue';
import Btn from '@/components/ui/Btn.vue';
import Field from '@/components/ui/Field.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PasswordField from '@/components/ui/PasswordField.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useUiStore } from '@/stores/ui';
import { apiPath } from '@/utils/format';
import { required } from '@/utils/validate';

const props = defineProps<{ name: string; tunnel: Tunnel }>();
const emit = defineEmits<{ close: [] }>();

const router = useRouter();
const ui = useUiStore();
const { run } = useJobRunner();

const formEl = ref<HTMLFormElement | null>(null);
const token = ref('');

// PasswordField's root is a wrapper, so [data-autofocus] cannot reach its input.
onMounted(() => formEl.value?.querySelector<HTMLInputElement>('input')?.focus());
const submitted = ref(false);
const pending = ref(false);
const tokenError = computed(() => (submitted.value ? required(token.value, 'Cloudflare API token') : ''));

function submit(): void {
  submitted.value = true;
  if (tokenError.value || pending.value) return;
  ui.confirmThen(`Delete tunnel ${props.tunnel.hostname}?`, 'This cannot be undone.', () => void remove(), {
    danger: true,
    confirmLabel: 'Delete tunnel',
    typeToConfirm: props.name,
    details: [
      `Stops and disables ${props.name} and deletes its unit file`,
      `Removes the DNS record for ${props.tunnel.hostname} and its ingress rule on Cloudflare`,
      'Deletes the tunnel itself if no other hostname uses it',
    ],
  });
}

async function remove(): Promise<void> {
  pending.value = true;
  try {
    const result = await run(
      apiPath`/api/v1/services/${props.name}/tunnel-delete`,
      { api_token: token.value.trim() },
      { title: `Deleting tunnel ${props.name}`, onSuccess: () => void router.push('/apps') },
    );
    if (result) emit('close');
  } finally {
    pending.value = false;
  }
}
</script>

<template>
  <BaseDialog
    title="Delete tunnel and clean up Cloudflare"
    :description="name"
    icon="cloud-off"
    tone="danger"
    :dirty="!!token"
    :closable="!pending"
    @close="emit('close')"
  >
    <form
      id="tunnel-delete-form"
      ref="formEl"
      class="flex flex-col gap-4"
      novalidate
      @submit.prevent="submit"
    >
      <p class="m-0 text-sm-var text-c-tx2">
        Stops the service, removes the DNS record
        <span class="mono text-c-tx">{{ tunnel.hostname }}</span> and its ingress rule, deletes the tunnel
        when nothing else uses it, then removes the local unit file.
      </p>
      <Field v-slot="f" label="Cloudflare API token" required :error="tokenError">
        <PasswordField
          :id="f.id"
          v-model="token"
          autocomplete="off"
          placeholder="Paste the API token"
          :described-by="f.describedBy"
          :invalid="f.invalid"
        />
      </Field>
      <CloudflareTokenHelp note="Used once to delete the tunnel — not stored on the server." />
    </form>
    <template #footer>
      <Btn :disabled="pending" @click="emit('close')">Cancel</Btn>
      <Btn type="submit" form="tunnel-delete-form" variant="danger-solid" :loading="pending">
        <LIcon name="trash-2" /> Delete tunnel
      </Btn>
    </template>
  </BaseDialog>
</template>
