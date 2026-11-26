<script setup lang="ts">
/** The one modal shell: backdrop, panel, header, body and footer slots.
 *
 * Accessible by construction (role="dialog", aria-modal, labelled by its
 * title, focus trapped, Escape closes only the top dialog — see useDialog).
 * `dirty` makes Escape and backdrop clicks ask before discarding input.
 */
import { computed, ref, useId } from 'vue';

import { useDialog } from '@/composables/useDialog';

import LIcon from './LIcon.vue';

const props = withDefaults(
  defineProps<{
    title: string;
    /** Optional line under the title. */
    description?: string;
    size?: 'sm' | 'md' | 'lg' | 'xl';
    /** Lucide icon shown before the title. */
    icon?: string;
    tone?: 'default' | 'danger' | 'warn' | 'accent';
    /** Unsaved input: closing asks first. */
    dirty?: boolean;
    /** False while an action runs: the dialog cannot be closed. */
    closable?: boolean;
  }>(),
  { description: '', size: 'md', icon: '', tone: 'default', dirty: false, closable: true },
);
const emit = defineEmits<{ close: [] }>();

const panel = ref<HTMLElement | null>(null);
const titleId = useId();
const descId = useId();

const WIDTH = { sm: 'max-w-[420px]', md: 'max-w-[540px]', lg: 'max-w-[720px]', xl: 'max-w-[960px]' };
const ICON_TONE = {
  default: 'bg-c-subtle text-c-tx2',
  danger: 'bg-c-dngsoft text-c-danger',
  warn: 'bg-c-warnsoft text-c-warn',
  accent: 'bg-c-acsoft text-c-actx',
};

const widthClass = computed(() => WIDTH[props.size]);

function requestClose(): void {
  if (!props.closable) return;
  if (props.dirty && !window.confirm('Discard your changes?')) return;
  emit('close');
}

useDialog(panel, requestClose);

defineExpose({ requestClose });
</script>

<template>
  <!-- Backdrop click closes; the keyboard path is Esc via the dialog stack. -->
  <!-- eslint-disable-next-line vuejs-accessibility/no-static-element-interactions -->
  <div
    class="fixed inset-0 z-[200] flex items-end sm:items-center justify-center p-0 sm:p-6 bg-c-overlay backdrop-blur-[2px] animate-fade"
    @mousedown.self="requestClose"
  >
    <div
      ref="panel"
      role="dialog"
      aria-modal="true"
      :aria-labelledby="titleId"
      :aria-describedby="description ? descId : undefined"
      tabindex="-1"
      :class="[
        'w-full flex flex-col max-h-[92vh] bg-c-card border border-c-border shadow-lg animate-pop outline-none',
        'rounded-t-theme-lg sm:rounded-theme-lg',
        widthClass,
      ]"
    >
      <header class="flex items-start gap-3 px-5 pt-5 pb-3">
        <div
          v-if="icon"
          :class="['w-9 h-9 shrink-0 rounded-[10px] grid place-items-center', ICON_TONE[tone]]"
          aria-hidden="true"
        >
          <LIcon is="width:18px;height:18px" :name="icon" />
        </div>
        <div class="min-w-0 flex-1">
          <h2 :id="titleId" class="m-0 text-base font-semibold tracking-[-0.01em] leading-snug">
            {{ title }}
          </h2>
          <p v-if="description" :id="descId" class="m-0 mt-1 text-sm-var text-c-tx2">
            {{ description }}
          </p>
        </div>
        <button
          v-if="closable"
          type="button"
          class="shrink-0 -mr-1.5 -mt-1 w-8 h-8 grid place-items-center rounded-md text-c-tx3 hover:text-c-tx hover:bg-c-hover"
          aria-label="Close"
          @click="requestClose"
        >
          <LIcon is="width:16px;height:16px" name="x" />
        </button>
      </header>

      <div class="px-5 pb-4 overflow-y-auto min-h-0 flex-1">
        <slot />
      </div>

      <footer
        v-if="$slots.footer"
        class="flex flex-wrap items-center justify-end gap-2 px-5 py-3.5 border-t border-c-border bg-c-elev rounded-b-theme-lg"
      >
        <slot name="footer" />
      </footer>
    </div>
  </div>
</template>
