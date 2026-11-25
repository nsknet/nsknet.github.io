<script setup lang="ts">
/** A labelled form field: label, control (slot), help text and error.
 *
 * The slot receives `{ id, describedBy, invalid }` to bind on the control, so
 * the label and messages are wired for screen readers without repetition:
 *
 *   <Field label="Port" :error="portError" help="1024–65535" v-slot="f">
 *     <input :id="f.id" v-model="port" class="input" :aria-describedby="f.describedBy" :aria-invalid="f.invalid" />
 *   </Field>
 */
import { computed, useId } from 'vue';

const props = withDefaults(
  defineProps<{
    label: string;
    help?: string;
    error?: string;
    required?: boolean;
    /** Visually hide the label (it stays for screen readers). */
    hideLabel?: boolean;
  }>(),
  { help: '', error: '', required: false, hideLabel: false },
);

const id = useId();
const helpId = `${id}-help`;
const errorId = `${id}-error`;
const describedBy = computed(
  () => [props.error ? errorId : '', props.help ? helpId : ''].filter(Boolean).join(' ') || undefined,
);
</script>

<template>
  <div class="flex flex-col gap-1.5 min-w-0">
    <label :for="id" :class="['text-sm-var font-medium text-c-tx', hideLabel ? 'sr-only' : '']">
      {{ label }}<span v-if="required" class="text-c-danger ml-0.5" aria-hidden="true">*</span>
    </label>
    <slot :id="id" :described-by="describedBy" :invalid="!!error || undefined" />
    <p v-if="error" :id="errorId" class="m-0 text-xs-var text-c-danger">{{ error }}</p>
    <p v-if="help" :id="helpId" class="m-0 text-xs-var text-c-tx3">{{ help }}</p>
  </div>
</template>
