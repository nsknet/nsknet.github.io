<script setup lang="ts">
/** All nginx virtual hosts. */
import { storeToRefs } from 'pinia';
import { useRouter } from 'vue-router';

import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import LIcon from '@/components/ui/LIcon.vue';
import Spinner from '@/components/ui/Spinner.vue';
import StatusBadge from '@/components/ui/StatusBadge.vue';
import TypeChip from '@/components/ui/TypeChip.vue';
import { useReload } from '@/composables/useScreenData';
import { useSitesStore } from '@/stores/sites';
import { useUiStore } from '@/stores/ui';

const router = useRouter();
const ui = useUiStore();
const reload = useReload();
const { sites, loading } = storeToRefs(useSitesStore());

async function refresh(): Promise<void> {
  await reload();
  ui.addToast({ t: 'Sites refreshed', k: 'info' });
}
</script>

<template>
  <section>
    <div class="flex items-end justify-between gap-6 mb-6">
      <div>
        <h1 class="text-[22px] font-semibold tracking-[-0.02em] mb-1">Sites</h1>
        <div class="text-sm-var text-c-tx2">
          {{ sites.length }} virtual hosts · Nginx <Badge tone="ok" dot>active</Badge>
        </div>
      </div>
      <div class="flex gap-2">
        <Btn @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
        <Btn variant="primary" @click="router.push('/sites/new')">
          <LIcon name="plus" /> Create site
        </Btn>
      </div>
    </div>

    <div class="bg-c-bg border border-c-border rounded-theme overflow-hidden">
      <table class="tbl">
        <thead>
          <tr>
            <th>Name</th>
            <th>Type</th>
            <th>Access</th>
            <th>Status</th>
            <th class="num">PID</th>
            <th>Mem (MB)</th>
            <th>CPU (%)</th>
            <th>Modified</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="loading && !sites.length">
            <td colspan="9" class="muted" style="text-align: center; padding: 32px 0">
              <Spinner label="Loading sites…" />
            </td>
          </tr>
          <tr v-else-if="!sites.length">
            <td colspan="9" class="muted" style="text-align: center; padding: 32px 0">
              No sites yet — use <strong>Create site</strong> to add one.
            </td>
          </tr>
          <tr
            v-for="site in sites"
            :key="site.slug"
            class="row-click"
            @click="router.push(`/sites/${site.slug}`)"
          >
            <td>
              <strong>{{ site.name }}</strong>
            </td>
            <td><TypeChip :type="site.type" /></td>
            <td class="mono muted">{{ site.access }}</td>
            <td><StatusBadge :status="site.status" /></td>
            <td class="num muted">{{ site.pid || '—' }}</td>
            <td class="num">{{ site.mem != null ? site.mem.toFixed(1) : '—' }}</td>
            <td class="num">{{ site.cpu != null ? site.cpu.toFixed(1) : '—' }}</td>
            <td class="muted">{{ site.modified }}</td>
            <td><LIcon name="chevron-right" is="width:14px;height:14px;color:var(--text-3)" /></td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>
</template>
