<script setup lang="ts">
/** Change the host timezone: a searchable list of every IANA zone the host
 *  knows (GET /system/timezones, loaded the first time the picker opens). */
import { storeToRefs } from 'pinia';
import { computed, onMounted, ref, watch } from 'vue';

import Btn from '@/components/ui/Btn.vue';
import ErrorState from '@/components/ui/ErrorState.vue';
import Field from '@/components/ui/Field.vue';
import LIcon from '@/components/ui/LIcon.vue';
import { useJobRunner } from '@/composables/useJobs';
import { useSystemStore } from '@/stores/system';
import { useUiStore } from '@/stores/ui';

const props = defineProps<{ current: string }>();
const emit = defineEmits<{ done: [] }>();

const ui = useUiStore();
const { run } = useJobRunner();
const system = useSystemStore();
const { timezones, loadingTimezones, timezonesLoaded, timezonesError } = storeToRefs(system);

const query = ref('');
const selected = ref('');
const pending = ref(false);
const submitted = ref(false);

const MAX_SHOWN = 80;

const matches = computed(() => {
  const words = query.value.trim().toLowerCase().replace(/\s+/g, '_').split('_').filter(Boolean);
  if (!words.length) return timezones.value;
  return timezones.value.filter((zone) => {
    const name = zone.toLowerCase();
    return words.every((word) => name.includes(word));
  });
});
const shown = computed(() => matches.value.slice(0, MAX_SHOWN));

// Keep the choice inside what the search shows; a single match is the choice.
watch(shown, (zones) => {
  if (zones.length === 1) selected.value = zones[0];
  else if (selected.value && !zones.includes(selected.value)) selected.value = '';
});

const error = computed(() => {
  if (!submitted.value) return '';
  if (!selected.value) return 'Pick a timezone from the list.';
  if (selected.value === props.current) return 'That is already the current timezone.';
  return '';
});

onMounted(() => {
  if (!timezonesLoaded.value) void system.loadTimezones();
});

function apply(): void {
  submitted.value = true;
  if (error.value) return;
  const zone = selected.value;
  ui.confirmThen(
    `Set the timezone to ${zone}?`,
    `The host clock changes from ${props.current || 'unknown'} to ${zone}.`,
    async () => {
      pending.value = true;
      const result = await run('/api/v1/system/set-timezone', { tz: zone }, { title: `Set timezone → ${zone}` });
      pending.value = false;
      if (result) emit('done');
    },
    {
      confirmLabel: 'Set timezone',
      details: [
        'Log timestamps, cron schedules and systemd timers use the new zone from now on.',
        'The time itself (UTC) does not change.',
      ],
    },
  );
}
</script>

<template>
  <div class="flex flex-col gap-3">
    <ErrorState
      v-if="timezonesError && !timezonesLoaded"
      title="Could not load the timezone list"
      :message="timezonesError"
      :retrying="loadingTimezones"
      @retry="system.loadTimezones()"
    />
    <template v-else>
      <Field
        v-slot="f"
        label="Search"
        :help="
          loadingTimezones && !timezonesLoaded
            ? 'Loading timezones…'
            : `${matches.length} of ${timezones.length} zones${matches.length > MAX_SHOWN ? ` · first ${MAX_SHOWN} shown, type to narrow` : ''}`
        "
      >
        <input
          :id="f.id"
          v-model="query"
          type="search"
          class="input"
          autocomplete="off"
          spellcheck="false"
          placeholder="City or region, e.g. Ho Chi Minh, Berlin"
          data-autofocus
          :aria-describedby="f.describedBy"
        />
      </Field>
      <Field v-slot="f" label="Timezone" :error="error" required>
        <select
          :id="f.id"
          v-model="selected"
          class="input mono"
          size="7"
          :aria-describedby="f.describedBy"
          :aria-invalid="f.invalid"
          :disabled="!timezonesLoaded"
        >
          <option value="" disabled>{{ shown.length ? 'Choose a timezone' : 'No zone matches the search' }}</option>
          <option v-for="zone in shown" :key="zone" :value="zone">
            {{ zone }}{{ zone === current ? ' (current)' : '' }}
          </option>
        </select>
      </Field>
      <div class="flex flex-wrap gap-2 justify-end">
        <Btn :disabled="pending" @click="emit('done')">Cancel</Btn>
        <Btn variant="primary" :loading="pending" :disabled="!timezonesLoaded" @click="apply">
          <LIcon name="clock" /> Set timezone
        </Btn>
      </div>
    </template>
  </div>
</template>
