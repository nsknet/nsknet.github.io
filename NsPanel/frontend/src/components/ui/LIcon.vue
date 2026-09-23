<script setup lang="ts">
/** A Lucide icon by its kebab-case name. `is` takes an inline style string,
 *  matching the prop the templates already use. */
import { computed } from 'vue';

import { FALLBACK_ICON, ICONS } from './icons';

const props = withDefaults(defineProps<{ name: string; is?: string }>(), { is: '' });

const component = computed(() => ICONS[props.name] ?? FALLBACK_ICON);
</script>

<template>
  <component :is="component" :style="is || undefined" />
</template>
