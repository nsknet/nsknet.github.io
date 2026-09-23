<script setup lang="ts">
/** The raised surface every panel, table wrapper and tile sits on.
 *  Cards use --bg-card over the --bg-canvas page, plus a border and a soft
 *  shadow, so neighbouring cards always read as separate objects. */
import { computed } from 'vue';
import { RouterLink, type RouteLocationRaw } from 'vue-router';

const props = withDefaults(
  defineProps<{
    /** Render as a RouterLink to this location (implies interactive). */
    to?: RouteLocationRaw;
    /** Hover lift + focus ring, for cards that are themselves clickable. */
    interactive?: boolean;
    tone?: 'default' | 'danger' | 'warn' | 'muted';
    /** Element to render when there is no `to`. */
    as?: string;
  }>(),
  { to: undefined, interactive: false, tone: 'default', as: 'div' },
);

const BASE = 'bg-c-card border rounded-theme shadow-card';

const TONE: Record<string, string> = {
  default: 'border-c-border',
  danger:
    'border-[color-mix(in_oklab,var(--danger)_35%,var(--border))] bg-[color-mix(in_oklab,var(--danger)_4%,var(--bg-card))]',
  warn: 'border-[color-mix(in_oklab,var(--warn)_35%,var(--border))] bg-[color-mix(in_oklab,var(--warn)_4%,var(--bg-card))]',
  muted: 'border-c-border bg-c-elev shadow-none',
};

const INTERACTIVE =
  'cursor-pointer text-inherit no-underline transition-[transform,box-shadow,border-color,background-color] duration-150 ease-out hover:-translate-y-px hover:shadow-card-hover hover:border-c-bstrong active:translate-y-0 focus-visible:outline-none focus-visible:shadow-[0_0_0_3px_color-mix(in_oklab,var(--accent)_30%,transparent)]';

const cls = computed(() => [
  BASE,
  TONE[props.tone] ?? TONE.default,
  props.interactive || props.to ? INTERACTIVE : '',
]);
</script>

<template>
  <RouterLink v-if="to" :to="to" :class="cls"><slot /></RouterLink>
  <component :is="as" v-else :class="cls"><slot /></component>
</template>
