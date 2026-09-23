<script setup lang="ts">
/** Collapsible note listing the Cloudflare API token permissions a tunnel needs. */
import { ref } from 'vue';

import LIcon from './ui/LIcon.vue';

withDefaults(defineProps<{ note?: string }>(), {
  note: 'Used once — not stored on the server.',
});

const open = ref(false);

const PERMISSIONS = [
  { scope: 'Account', name: 'Cloudflare Tunnel', level: 'Edit' },
  { scope: 'Zone', name: 'DNS', level: 'Edit' },
  { scope: 'Zone', name: 'Zone', level: 'Read' },
];
</script>

<template>
  <div class="flex flex-col gap-1.5 mt-0.5">
    <div class="flex items-center justify-between text-[11px] text-c-tx3 flex-wrap gap-1">
      <span>{{ note }}</span>
      <button
        type="button"
        class="text-c-tx2 hover:text-c-tx inline-flex items-center gap-1 transition-colors cursor-pointer select-none bg-transparent border-0 p-0 text-[11px]"
        @click="open = !open"
      >
        <LIcon name="info" is="width:11px;height:11px" />
        <span>{{ open ? 'Hide requirements' : 'Required permissions' }}</span>
        <LIcon :name="open ? 'chevron-up' : 'chevron-down'" is="width:11px;height:11px" />
      </button>
    </div>

    <div
      v-if="open"
      class="p-2.5 rounded-lg bg-c-subtle border border-c-border text-[11px] flex flex-col gap-2 animate-fade"
    >
      <div class="flex items-start gap-1.5 text-c-tx2">
        <LIcon
          name="key-round"
          is="width:13px;height:13px;color:var(--accent);margin-top:2px;flex-shrink:0"
        />
        <div class="leading-relaxed">
          Create at
          <a
            href="https://dash.cloudflare.com/profile/api-tokens"
            target="_blank"
            rel="noopener noreferrer"
            class="text-c-actx hover:underline font-medium"
            >dash.cloudflare.com</a
          >: <span class="text-c-tx font-medium">API Tokens</span> &rarr;
          <span class="text-c-tx font-medium">Create Token</span> &rarr;
          <span class="text-c-tx font-medium">Create Custom Token</span>
        </div>
      </div>
      <div>
        <div class="text-[10px] font-medium uppercase tracking-[0.05em] text-c-tx3 mb-1">
          Required permissions
        </div>
        <div class="flex flex-col gap-1">
          <div
            v-for="permission in PERMISSIONS"
            :key="`${permission.scope}-${permission.name}`"
            class="flex items-center justify-between px-2.5 py-1 rounded bg-c-bg border border-c-border"
          >
            <span class="text-c-tx2">
              <span class="font-medium text-c-tx">{{ permission.scope }}</span> &rsaquo;
              {{ permission.name }}
            </span>
            <span
              :class="[
                'mono text-[10px] font-medium px-1.5 py-0.5 rounded border',
                permission.level === 'Edit'
                  ? 'bg-c-acsoft text-c-actx border-transparent'
                  : 'bg-c-subtle text-c-tx2 border-c-border',
              ]"
              >{{ permission.level }}</span
            >
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
