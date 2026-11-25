<script setup lang="ts">
/** The signed-in account: session rules, password, theme, sign out, and which
 *  build of the panel is running. */
import { computed, useId } from 'vue';

import ChangePasswordForm from '@/components/settings/ChangePasswordForm.vue';
import Alert from '@/components/ui/Alert.vue';
import Btn from '@/components/ui/Btn.vue';
import Card from '@/components/ui/Card.vue';
import CardHeader from '@/components/ui/CardHeader.vue';
import KeyValueList from '@/components/ui/KeyValueList.vue';
import LIcon from '@/components/ui/LIcon.vue';
import PageHeader from '@/components/ui/PageHeader.vue';
import type { KeyValueItem } from '@/components/ui/types';
import { useAuthStore } from '@/stores/auth';
import { useUiStore, type ThemeMode } from '@/stores/ui';
import { copyText } from '@/utils/clipboard';
import { fmtDate } from '@/utils/format';

const auth = useAuthStore();
const ui = useUiStore();
const themeName = useId();

/** Mirrors config.py (SESSION_*, LOGIN_*). */
const POLICY = [
  { icon: 'timer', text: 'A session ends after 30 minutes without activity.' },
  { icon: 'clock', text: 'Every session ends 12 hours after sign-in, active or not.' },
  { icon: 'shield-alert', text: '5 failed sign-ins from one IP address lock that address out for 15 minutes.' },
  { icon: 'log-out', text: 'Changing the password signs out every other browser.' },
];

const THEMES: { value: ThemeMode; label: string; icon: string; hint: string }[] = [
  { value: 'system', label: 'System', icon: 'monitor', hint: 'Follow the operating system' },
  { value: 'light', label: 'Light', icon: 'sun', hint: 'Always light' },
  { value: 'dark', label: 'Dark', icon: 'moon', hint: 'Always dark' },
];

const version = computed(() => auth.me?.version ?? null);

const versionItems = computed<KeyValueItem[]>(() => {
  const v = version.value;
  return [
    { key: 'version', label: 'Version', value: v?.version ?? __APP_VERSION__, mono: true },
    { key: 'commit', label: 'Commit', value: v?.commit || null, mono: true, copy: true },
    { key: 'date', label: 'Commit date', value: v?.commit_date ? fmtDate(v.commit_date) : null },
    { key: 'branch', label: 'Branch', value: v?.branch || null, mono: true },
    { key: 'bundle', label: 'Interface' },
  ];
});

const versionText = computed(() => {
  const v = version.value;
  if (!v) return auth.versionLabel;
  return [
    `NsPanel ${auth.versionLabel}`,
    `commit ${v.commit || 'unknown'}${v.dirty ? ' (modified)' : ''}`,
    v.commit_date ? `date ${v.commit_date}` : '',
    v.branch ? `branch ${v.branch}` : '',
    `frontend ${v.frontend_commit ? v.frontend_commit.slice(0, 12) : 'unknown'}, bundle ${
      v.dist_frontend_commit ? v.dist_frontend_commit.slice(0, 12) : 'unknown'
    }${auth.bundleStale ? ' (stale)' : ''}`,
  ]
    .filter(Boolean)
    .join('\n');
});

function signOut(): void {
  void auth.logout();
}

function reload(): void {
  window.location.reload();
}
</script>

<template>
  <section>
    <PageHeader title="Security" subtitle="Your session, the admin password and how the panel looks.">
      <Btn variant="danger" @click="signOut"><LIcon name="log-out" /> Sign out</Btn>
    </PageHeader>

    <div class="grid grid-cols-1 lg:grid-cols-2 gap-3 items-start">
      <div class="flex flex-col gap-3 min-w-0">
        <Card class="overflow-clip">
          <CardHeader title="Session" icon="user" />
          <div class="p-4 flex flex-col gap-4">
            <div class="flex items-center gap-3 min-w-0">
              <div class="w-10 h-10 rounded-full bg-c-acsoft text-c-actx grid place-items-center shrink-0" aria-hidden="true">
                <LIcon name="user" is="width:18px;height:18px" />
              </div>
              <div class="min-w-0">
                <div class="text-sm-var text-c-tx2">Signed in as</div>
                <div class="font-semibold truncate">{{ auth.me?.username ?? '—' }}</div>
              </div>
            </div>
            <ul class="m-0 p-0 list-none flex flex-col gap-2.5">
              <li v-for="rule in POLICY" :key="rule.text" class="flex items-start gap-2.5 text-sm-var text-c-tx2">
                <LIcon :name="rule.icon" is="width:15px;height:15px;margin-top:2px;flex-shrink:0;color:var(--text-3)" />
                <span>{{ rule.text }}</span>
              </li>
            </ul>
          </div>
        </Card>

        <Card class="overflow-clip">
          <CardHeader title="Appearance" icon="sun" />
          <fieldset class="m-0 p-4 border-0 min-w-0">
            <legend class="sr-only">Theme</legend>
            <div class="grid grid-cols-1 sm:grid-cols-3 gap-2">
              <label
                v-for="theme in THEMES"
                :key="theme.value"
                :class="[
                  'flex items-center gap-2.5 p-3 rounded-theme border cursor-pointer select-none transition-colors',
                  'has-[:focus-visible]:shadow-[0_0_0_3px_var(--focus)]',
                  ui.themeMode === theme.value
                    ? 'border-c-accent bg-c-acsoft text-c-tx'
                    : 'border-c-border bg-c-bg text-c-tx2 hover:border-c-bstrong hover:text-c-tx',
                ]"
              >
                <input
                  type="radio"
                  class="sr-only"
                  :name="themeName"
                  :value="theme.value"
                  :checked="ui.themeMode === theme.value"
                  @change="ui.setThemeMode(theme.value)"
                />
                <LIcon :name="theme.icon" is="width:16px;height:16px;flex-shrink:0" />
                <span class="min-w-0">
                  <span class="block text-sm-var font-medium">{{ theme.label }}</span>
                  <span class="block text-xs-var text-c-tx3">{{ theme.hint }}</span>
                </span>
              </label>
            </div>
            <p class="m-0 mt-2.5 text-xs-var text-c-tx3">Stored in this browser only.</p>
          </fieldset>
        </Card>

        <Card class="overflow-clip">
          <CardHeader title="Version" icon="git-merge">
            <Btn sm variant="ghost" @click="copyText(versionText, 'Version details')">
              <LIcon name="copy" /> Copy
            </Btn>
          </CardHeader>
          <div class="p-4 flex flex-col gap-3">
            <KeyValueList :items="versionItems" label-width="110px">
              <template #value-bundle>
                <span v-if="auth.bundleStale" class="text-c-warn text-sm-var">Out of date</span>
                <span v-else class="text-sm-var">Current</span>
              </template>
            </KeyValueList>
            <Alert v-if="auth.bundleStale" tone="warn" title="Newer interface available">
              The panel runs newer code than this page was built from.
              <template #action><Btn sm variant="warn" @click="reload">Reload</Btn></template>
            </Alert>
            <p v-if="version?.dirty" class="m-0 text-xs-var text-c-tx3">
              The checkout has local changes that are not committed.
            </p>
          </div>
        </Card>
      </div>

      <Card class="overflow-clip min-w-0">
        <CardHeader title="Change password" icon="key-round" />
        <div class="p-4">
          <ChangePasswordForm />
        </div>
      </Card>
    </div>
  </section>
</template>
