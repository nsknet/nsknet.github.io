<script setup lang="ts">
/** All nginx virtual hosts. */
import { storeToRefs } from 'pinia';
import { useRouter } from 'vue-router';

import Badge from '@/components/ui/Badge.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import Skeleton from '@/components/ui/Skeleton.vue';
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
    <PageHeader title="Sites">
      <template #subtitle>
        {{ sites.length }} virtual hosts · Nginx <Badge tone="ok" dot>active</Badge>
      </template>
      <Btn @click="refresh"><LIcon name="refresh-cw" /> Refresh</Btn>
      <Btn variant="primary" @click="router.push('/sites/new')">
        <LIcon name="plus" /> Create site
      </Btn>
    </PageHeader>

    <Card class="overflow-clip">
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
            <td colspan="9" style="padding: 0; height: auto"><Skeleton :count="4" /></td>
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
            <td class="w-8">
              <LIcon
                name="chevron-right"
                class="row-hint"
                is="width:14px;height:14px;color:var(--text-2)"
              />
            </td>
          </tr>
        </tbody>
      </table>
    </Card>
  </section>
</template>
