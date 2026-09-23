<script setup lang="ts">
/** The only button styling in the app. */
import { computed } from 'vue';

const props = withDefaults(
  defineProps<{
    variant?: 'default' | 'primary' | 'ghost' | 'danger' | 'success' | 'warn' | 'info';
    sm?: boolean;
    square?: boolean;
  }>(),
  { variant: 'default', sm: false, square: false },
);

const BASE =
  'inline-flex items-center justify-center gap-1.5 font-medium leading-none whitespace-nowrap rounded-lg border transition-[background-color,border-color,color,box-shadow,transform] duration-150 ease-out select-none active:scale-[0.97] disabled:opacity-50 disabled:pointer-events-none disabled:active:scale-100 focus-visible:outline-none focus-visible:shadow-[0_0_0_3px_color-mix(in_oklab,var(--accent)_30%,transparent)] [&_svg]:w-4 [&_svg]:h-4 [&_svg]:shrink-0';

const VARIANT: Record<string, string> = {
  default:
    'bg-c-bg border-c-border text-c-tx shadow-sm hover:bg-c-hover hover:border-c-bstrong active:bg-c-subtle',
  primary:
    'bg-c-accent border-transparent text-c-acfg shadow-sm hover:bg-c-achover hover:shadow-md active:shadow-sm',
  ghost: 'border-transparent text-c-tx2 hover:bg-c-hover hover:text-c-tx active:bg-c-subtle',
  danger:
    'bg-c-bg border-c-border text-c-danger shadow-sm hover:bg-c-dngsoft hover:border-c-danger active:bg-c-dngsoft',
  success:
    'bg-c-oksoft border-[color-mix(in_oklab,var(--ok)_20%,transparent)] text-c-ok shadow-sm hover:bg-[color-mix(in_oklab,var(--ok)_18%,transparent)] hover:border-[color-mix(in_oklab,var(--ok)_50%,transparent)] active:bg-c-oksoft',
  warn: 'bg-c-warnsoft border-[color-mix(in_oklab,var(--warn)_20%,transparent)] text-c-warn shadow-sm hover:bg-[color-mix(in_oklab,var(--warn)_18%,transparent)] hover:border-[color-mix(in_oklab,var(--warn)_50%,transparent)] active:bg-c-warnsoft',
  info: 'bg-c-infosoft border-[color-mix(in_oklab,var(--info)_20%,transparent)] text-c-info shadow-sm hover:bg-[color-mix(in_oklab,var(--info)_18%,transparent)] hover:border-[color-mix(in_oklab,var(--info)_50%,transparent)] active:bg-c-infosoft',
};

const cls = computed(() => [
  BASE,
  VARIANT[props.variant] ?? VARIANT.default,
  props.sm ? 'h-7 text-xs-var' : 'h-9 text-sm-var',
  props.square ? (props.sm ? 'w-7' : 'w-9') : props.sm ? 'px-2.5' : 'px-3.5',
]);
</script>

<template>
  <button :class="cls"><slot /></button>
</template>
