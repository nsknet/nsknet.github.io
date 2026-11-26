<script setup lang="ts">
/** Label/value pairs as a definition list. Values can be overridden per key
 *  with a `#value-<key>` slot (badges, links, buttons). */

import { copyText } from '@/utils/clipboard';

import type { KeyValueItem } from './types';

import LIcon from './LIcon.vue';

withDefaults(defineProps<{ items: KeyValueItem[]; labelWidth?: string }>(), { labelWidth: '140px' });
</script>

<template>
  <dl
    class="m-0 grid grid-cols-1 sm:[grid-template-columns:var(--kv-label)_1fr] gap-x-4 gap-y-1 sm:gap-y-2.5 text-sm-var"
    :style="{ '--kv-label': labelWidth }"
  >
    <template v-for="item in items" :key="item.key">
      <dt class="text-c-tx2 font-medium pt-1.5 sm:pt-0">{{ item.label }}</dt>
      <dd class="m-0 min-w-0 flex items-center gap-1.5 break-words">
        <slot :name="`value-${item.key}`" :item="item">
          <span :class="[item.mono ? 'mono text-xs-var' : '', 'min-w-0 break-all']">{{
            item.value === null || item.value === undefined || item.value === '' ? '—' : item.value
          }}</span>
          <button
            v-if="item.copy && item.value"
            type="button"
            class="shrink-0 w-6 h-6 grid place-items-center rounded text-c-tx3 hover:text-c-tx hover:bg-c-hover"
            :aria-label="`Copy ${item.label}`"
            @click="copyText(String(item.value), item.label)"
          >
            <LIcon is="width:12px;height:12px" name="copy" />
          </button>
        </slot>
      </dd>
    </template>
  </dl>
</template>
