<script setup lang="ts">
/** Password input with show/hide, and optional Generate and Copy buttons.
 *  Hidden by default: shoulder-surfing a screen share is a real risk. */
import { ref } from 'vue';

import { copyText } from '@/utils/clipboard';
import { generatePassword } from '@/utils/secrets';

import LIcon from './LIcon.vue';

const model = defineModel<string>({ required: true });
const props = withDefaults(
  defineProps<{
    id?: string;
    describedBy?: string;
    invalid?: boolean;
    autocomplete?: string;
    generate?: boolean;
    copy?: boolean;
    placeholder?: string;
  }>(),
  {
    id: undefined,
    describedBy: undefined,
    invalid: undefined,
    autocomplete: 'new-password',
    generate: false,
    copy: false,
    placeholder: '',
  },
);

const visible = ref(false);

function regenerate(): void {
  model.value = generatePassword();
  visible.value = true;
}
</script>

<template>
  <div class="flex items-center gap-1.5">
    <div class="relative flex-1 min-w-0">
      <input
        :id="props.id"
        v-model="model"
        :type="visible ? 'text' : 'password'"
        class="input mono pr-10"
        :autocomplete="autocomplete"
        :placeholder="placeholder"
        :aria-describedby="describedBy"
        :aria-invalid="invalid"
        spellcheck="false"
        autocapitalize="off"
      />
      <button
        type="button"
        class="absolute right-1 top-1/2 -translate-y-1/2 w-8 h-8 grid place-items-center rounded-md text-c-tx3 hover:text-c-tx hover:bg-c-hover"
        :aria-label="visible ? 'Hide password' : 'Show password'"
        :aria-pressed="visible"
        @click="visible = !visible"
      >
        <LIcon :name="visible ? 'eye-off' : 'eye'" is="width:16px;height:16px" />
      </button>
    </div>
    <button
      v-if="generate"
      type="button"
      class="h-9 px-2.5 inline-flex items-center gap-1.5 rounded-lg border border-c-border bg-c-bg text-sm-var text-c-tx2 hover:text-c-tx hover:bg-c-hover"
      @click="regenerate"
    >
      <LIcon name="dices" is="width:15px;height:15px" /> Generate
    </button>
    <button
      v-if="copy"
      type="button"
      class="h-9 w-9 grid place-items-center rounded-lg border border-c-border bg-c-bg text-c-tx2 hover:text-c-tx hover:bg-c-hover"
      aria-label="Copy password"
      :disabled="!model"
      @click="copyText(model, 'Password')"
    >
      <LIcon name="copy" is="width:15px;height:15px" />
    </button>
  </div>
</template>
