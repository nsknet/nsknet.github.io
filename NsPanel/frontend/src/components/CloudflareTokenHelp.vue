<script setup lang="ts">
/** Collapsible note listing the Cloudflare API token permissions a tunnel needs. */
import { ref, useId } from 'vue';

import LIcon from './ui/LIcon.vue';

withDefaults(defineProps<{ note?: string }>(), {
  note: 'Used once — not stored on the server.',
});

const open = ref(false);
const panelId = useId();

const PERMISSIONS = [
  { scope: 'Account', name: 'Cloudflare Tunnel', level: 'Edit' },
  { scope: 'Zone', name: 'DNS', level: 'Edit' },
  { scope: 'Zone', name: 'Zone', level: 'Read' },
];
</script>

<template>
  <div class="flex flex-col gap-1.5">
    <div class="flex items-center justify-between flex-wrap gap-x-3 gap-y-1 text-xs-var text-c-tx3">
      <span>{{ note }}</span>
      <button
        type="button"
        class="inline-flex items-center gap-1 text-c-tx2 hover:text-c-tx rounded-sm"
        :aria-expanded="open"
        :aria-controls="panelId"
        @click="open = !open"
      >
        <LIcon is="width:13px;height:13px" name="info" />
        Required permissions
        <LIcon is="width:13px;height:13px" :name="open ? 'chevron-up' : 'chevron-down'" />
      </button>
    </div>

    <div
      v-if="open"
      :id="panelId"
      class="p-3 rounded-theme bg-c-subtle border border-c-border text-xs-var flex flex-col gap-2.5 animate-fade"
    >
      <p class="m-0 text-c-tx2 leading-relaxed">
        Create one at
        <a
          href="https://dash.cloudflare.com/profile/api-tokens"
          target="_blank"
          rel="noopener noreferrer"
          class="text-c-actx font-medium underline underline-offset-2"
          >dash.cloudflare.com<span class="sr-only"> (opens in a new tab)</span></a
        >: <span class="text-c-tx font-medium">API Tokens</span> →
        <span class="text-c-tx font-medium">Create Token</span> →
        <span class="text-c-tx font-medium">Create Custom Token</span>, with:
      </p>
      <ul class="m-0 p-0 list-none flex flex-col gap-1">
        <li
          v-for="permission in PERMISSIONS"
          :key="`${permission.scope}-${permission.name}`"
          class="flex items-center justify-between gap-2 px-2.5 py-1.5 rounded-theme-sm bg-c-bg border border-c-border"
        >
          <span class="text-c-tx2">
            <span class="font-medium text-c-tx">{{ permission.scope }}</span> ›
            {{ permission.name }}
          </span>
          <span
            :class="[
              'mono text-2xs-var font-medium px-1.5 py-0.5 rounded border',
              permission.level === 'Edit'
                ? 'bg-c-acsoft text-c-actx border-transparent'
                : 'bg-c-subtle text-c-tx2 border-c-border',
            ]"
            >{{ permission.level }}</span
          >
        </li>
      </ul>
    </div>
  </div>
</template>
