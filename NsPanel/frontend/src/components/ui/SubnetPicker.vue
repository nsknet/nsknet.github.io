<script setup lang="ts">
/** Which networks a port is opened to (UFW). "Any IP" clears the others and
 *  is shown with a warning; `allowPublic=false` hides it entirely. */
import { computed } from 'vue';

import { ANY_IP, SUBNET_OPTIONS, toggleSubnet } from '@/utils/secrets';

import LIcon from './LIcon.vue';

const selected = defineModel<Record<string, boolean>>({ required: true });
const props = withDefaults(
  defineProps<{
    /** Extra choices first, e.g. this host's own LANs: [{cidr, label}]. */
    choices?: { cidr: string; label: string }[];
    allowPublic?: boolean;
    legend?: string;
  }>(),
  { choices: () => [], allowPublic: true, legend: 'Open to' },
);

const options = computed(() => {
  const seen = new Set<string>();
  return [...props.choices, ...SUBNET_OPTIONS].filter((option) => {
    if (seen.has(option.cidr)) return false;
    seen.add(option.cidr);
    return props.allowPublic || option.cidr !== ANY_IP;
  });
});
</script>

<template>
  <fieldset class="m-0 p-0 border-0 min-w-0">
    <legend class="text-sm-var font-medium text-c-tx mb-1.5 p-0">{{ legend }}</legend>
    <div class="flex flex-col gap-0.5 border border-c-border rounded-theme p-1 bg-c-elev">
      <label
        v-for="option in options"
        :key="option.cidr"
        :class="[
          'flex items-center gap-2.5 px-2 py-1.5 rounded-theme-sm cursor-pointer select-none hover:bg-c-hover',
          option.cidr === ANY_IP && selected[option.cidr] ? 'text-c-warn' : '',
        ]"
      >
        <input
          type="checkbox"
          class="w-4 h-4 accent-c-accent shrink-0"
          :checked="!!selected[option.cidr]"
          @change="toggleSubnet(selected, option.cidr)"
        />
        <span class="text-sm-var flex-1 min-w-0">{{ option.label }}</span>
        <span class="mono text-xs-var text-c-tx3 tabular-nums">{{ option.cidr }}</span>
      </label>
    </div>
    <p
      v-if="selected[ANY_IP]"
      class="flex items-start gap-1.5 m-0 mt-1.5 text-xs-var text-c-warn"
      role="status"
    >
      <LIcon is="width:13px;height:13px;margin-top:2px;flex-shrink:0" name="triangle-alert" />
      Every IP on the internet can reach this port.
    </p>
    <p class="m-0 mt-1.5 text-xs-var text-c-tx3">
      UFW rules only — UFW itself is not switched on if it is off.
    </p>
  </fieldset>
</template>
