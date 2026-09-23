<script setup lang="ts">
import { computed } from 'vue';

import Badge from './Badge.vue';
import type { Tone } from './types';

const props = withDefaults(defineProps<{ status?: string }>(), { status: '' });

const TONES: Record<string, Tone> = {
  running: 'ok',
  ok: 'ok',
  active: 'ok',
  installed: 'ok',
  stopped: 'muted',
  inactive: 'muted',
  'not installed': 'muted',
  failed: 'danger',
  enabled: 'info',
  disabled: 'muted',
};

const tone = computed<Tone>(() => TONES[props.status] ?? 'muted');
</script>

<template>
  <Badge :tone="tone" dot>{{ status }}</Badge>
</template>
