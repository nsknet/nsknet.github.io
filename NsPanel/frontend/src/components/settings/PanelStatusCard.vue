<script setup lang="ts">
/** The installed service: where it answers, how it is exposed, and restart / uninstall. */
import { computed } from 'vue';

import type { PanelServiceStatus } from '@/api/types';
import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import CardHeader from '@/components/ui/CardHeader.vue';
import KeyValueList from '@/components/ui/KeyValueList.vue';
import LIcon from '@/components/ui/LIcon.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import type { KeyValueItem } from '@/components/ui/types';
import { copyText } from '@/utils/clipboard';
import { fmtDate } from '@/utils/format';

const props = defineProps<{ status: PanelServiceStatus; disabled?: boolean }>();
const emit = defineEmits<{ restart: []; uninstall: [] }>();

const items = computed<KeyValueItem[]>(() => [
  { key: 'urls', label: 'Open at' },
  { key: 'protocol', label: 'Protocol' },
  { key: 'firewall', label: 'Firewall', value: props.status.subnets.join(', '), mono: true },
  { key: 'dir', label: 'Directory', value: props.status.repo_dir, mono: true, copy: true },
  { key: 'installed', label: 'Installed', value: fmtDate(props.status.installed_at) },
]);
</script>

<template>
  <Card class="overflow-clip flex flex-col">
    <CardHeader title="Service" icon="server">
      <Badge v-if="status.is_self" tone="accent">this panel</Badge>
      <StatusBadge :status="status.active" />
      <StatusBadge :status="status.enabled" />
    </CardHeader>
    <div class="p-4 flex-1">
      <KeyValueList :items="items" label-width="110px">
        <template #value-urls>
          <ul v-if="status.urls.length" class="m-0 p-0 list-none flex flex-col gap-1 min-w-0">
            <li v-for="url in status.urls" :key="url" class="flex items-center gap-1 min-w-0">
              <a
                :href="url"
                target="_blank"
                rel="noopener"
                class="mono text-xs-var text-c-actx underline underline-offset-2 break-all"
                >{{ url }}</a
              >
              <button
                type="button"
                class="shrink-0 w-7 h-7 grid place-items-center rounded text-c-tx3 hover:text-c-tx hover:bg-c-hover"
                :aria-label="`Copy ${url}`"
                @click="copyText(url, 'URL')"
              >
                <LIcon name="copy" is="width:13px;height:13px" />
              </button>
            </li>
          </ul>
          <span v-else class="text-c-tx3">—</span>
        </template>
        <template #value-protocol>
          <Badge :tone="status.tls ? 'ok' : 'warn'">
            <LIcon :name="status.tls ? 'lock' : 'lock-open'" is="width:12px;height:12px" />
            {{ status.tls ? 'HTTPS (self-signed)' : 'HTTP — unencrypted' }}
          </Badge>
        </template>
      </KeyValueList>
    </div>
    <div class="flex flex-wrap gap-2 px-4 py-3 border-t border-c-border">
      <Btn sm :disabled="disabled" @click="emit('restart')"><LIcon name="rotate-cw" /> Restart</Btn>
      <Btn v-if="!status.is_self" sm variant="danger" class="ml-auto" :disabled="disabled" @click="emit('uninstall')">
        <LIcon name="trash-2" /> Uninstall
      </Btn>
      <p v-else class="m-0 ml-auto self-center text-xs-var text-c-tx3">
        Uninstall it from a panel started with run.sh.
      </p>
    </div>
  </Card>
</template>
