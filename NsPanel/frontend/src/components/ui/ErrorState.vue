<script setup lang="ts">
/** Shown where data should be when loading it failed — never "empty". */
import Btn from './Btn.vue';
import LIcon from './LIcon.vue';

withDefaults(defineProps<{ message: string; title?: string; retrying?: boolean }>(), {
  title: 'Could not load this',
  retrying: false,
});
const emit = defineEmits<{ retry: [] }>();
</script>

<template>
  <div class="text-center py-8 px-6" role="alert">
    <div class="w-11 h-11 rounded-xl bg-c-dngsoft grid place-items-center mx-auto mb-3">
      <LIcon is="width:20px;height:20px;color:var(--danger)" name="cloud-off" />
    </div>
    <div class="text-c-tx font-medium text-sm-var">{{ title }}</div>
    <div class="text-xs-var text-c-tx2 mt-1 max-w-md mx-auto break-words">{{ message }}</div>
    <Btn class="mt-4" sm :loading="retrying" @click="emit('retry')">
      <LIcon name="refresh-cw" /> Try again
    </Btn>
  </div>
</template>
