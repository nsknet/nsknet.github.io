<script setup lang="ts">
/** The navigation: grouped links (real RouterLinks, so middle-click and the
 *  keyboard work), plus theme, password and sign-out at the bottom.
 *  `wide` shows labels; the mobile drawer always renders it wide. */
import { computed } from 'vue';
import { RouterLink, useRoute } from 'vue-router';

import { navGroups } from '@/router';
import { useAuthStore } from '@/stores/auth';
import { useUiStore } from '@/stores/ui';

import LIcon from './ui/LIcon.vue';

const props = withDefaults(defineProps<{ wide: boolean; showCollapse?: boolean }>(), { showCollapse: true });
const emit = defineEmits<{ navigate: [] }>();

const route = useRoute();
const ui = useUiStore();
const auth = useAuthStore();

const activeKey = computed(() => route.meta.rail ?? String(route.name ?? ''));

const THEME_ICON = { system: 'monitor', light: 'sun', dark: 'moon' } as const;
const THEME_LABEL = { system: 'Theme: system', light: 'Theme: light', dark: 'Theme: dark' } as const;

const itemClass = computed(() => ['rail-btn', { 'rail-btn--wide': props.wide }]);
</script>

<template>
  <nav
    :class="['h-full flex flex-col py-3 gap-0.5', wide ? 'items-stretch px-3' : 'items-center']"
    aria-label="Main"
  >
    <RouterLink
      to="/"
      :class="['flex items-center mb-3 no-underline text-inherit', wide ? 'gap-2.5 px-1' : 'justify-center']"
      aria-label="NsPanel overview"
      @click="emit('navigate')"
    >
      <span
        class="w-9 h-9 shrink-0 rounded-theme brand-mark text-white grid place-items-center font-bold text-sm tracking-[-0.04em] shadow-sm ring-1 ring-inset ring-white/15"
        aria-hidden="true"
        >N</span
      >
      <span v-if="wide" class="font-semibold text-sm tracking-[-0.02em] text-c-tx whitespace-nowrap"
        >NsPanel</span
      >
    </RouterLink>

    <div
      class="flex-1 min-h-0 overflow-y-auto overflow-x-hidden flex flex-col gap-0.5 w-full"
      :class="wide ? 'items-stretch' : 'items-center'"
    >
      <template v-for="(section, index) in navGroups" :key="section.group">
        <div
          v-if="wide && section.group !== 'Overview'"
          :class="[
            'px-2.5 pb-1 text-2xs-var uppercase tracking-[0.08em] font-semibold text-c-tx3 whitespace-nowrap',
            index ? 'pt-3' : '',
          ]"
        >
          {{ section.group }}
        </div>
        <div
          v-else-if="!wide && index"
          class="w-6 h-px bg-c-border my-1.5 self-center"
          aria-hidden="true"
        ></div>
        <RouterLink
          v-for="item in section.items"
          :key="item.key"
          :to="item.path"
          :class="[...itemClass, { active: activeKey === item.key }, wide ? '' : 'self-center']"
          :data-tip="wide ? null : item.label"
          :aria-label="wide ? undefined : item.label"
          :aria-current="activeKey === item.key ? 'page' : undefined"
          @click="emit('navigate')"
        >
          <LIcon :name="item.icon" />
          <span v-if="wide" class="rail-label">{{ item.label }}</span>
        </RouterLink>
      </template>
    </div>

    <div
      :class="['flex flex-col gap-0.5 pt-2 mt-1 border-t border-c-border w-full', wide ? '' : 'items-center']"
    >
      <button
        type="button"
        :class="itemClass"
        :data-tip="wide ? null : THEME_LABEL[ui.themeMode]"
        :aria-label="THEME_LABEL[ui.themeMode]"
        @click="ui.toggleTheme()"
      >
        <LIcon :name="THEME_ICON[ui.themeMode]" />
        <span v-if="wide" class="rail-label">{{ THEME_LABEL[ui.themeMode] }}</span>
      </button>
      <button
        type="button"
        :class="itemClass"
        :data-tip="wide ? null : 'Sign out'"
        :aria-label="wide ? undefined : 'Sign out'"
        @click="auth.logout()"
      >
        <LIcon name="log-out" />
        <span v-if="wide" class="rail-label">Sign out</span>
      </button>
      <button
        v-if="showCollapse"
        type="button"
        :class="itemClass"
        :data-tip="wide ? null : 'Expand'"
        :aria-label="wide ? 'Collapse sidebar' : 'Expand sidebar'"
        :aria-expanded="wide"
        @click="ui.toggleSidebar()"
      >
        <LIcon :name="wide ? 'panel-left-close' : 'panel-left-open'" />
        <span v-if="wide" class="rail-label">Collapse</span>
      </button>
      <div
        :class="['mono text-2xs-var text-c-tx3 pt-1', wide ? 'px-2.5' : 'text-center']"
        :title="`NsPanel ${auth.versionLabel}${auth.me?.version.commit_date ? ' · ' + auth.me.version.commit_date : ''}`"
      >
        {{ wide ? `NsPanel ${auth.versionLabel}` : auth.me?.version.commit.slice(0, 4) || 'v' }}
      </div>
    </div>
  </nav>
</template>
