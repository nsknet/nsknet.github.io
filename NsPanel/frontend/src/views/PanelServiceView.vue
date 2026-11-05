<script setup lang="ts">
/** Run NsPanel itself as a systemd service: install, version, updates, restart. */
import { storeToRefs } from "pinia";
import { computed, nextTick, onUnmounted, ref, watch } from "vue";

import { ApiError, endpoints, fetchData } from "@/api/client";
import type { PanelServiceStatus } from "@/api/types";
import Badge from "@/components/ui/Badge.vue";
import Btn from "@/components/ui/Btn.vue";
import Card from "@/components/ui/Card.vue";
import LIcon from "@/components/ui/LIcon.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Skeleton from "@/components/ui/Skeleton.vue";
import StatusBadge from "@/components/ui/StatusBadge.vue";
import { useJobRunner } from "@/composables/useJobs";
import { usePanelStore } from "@/stores/panel";
import { useUiStore } from "@/stores/ui";
import { ANY_IP, generatePassword, toggleSubnet } from "@/utils/secrets";

const ui = useUiStore();
const { run } = useJobRunner();
const panelStore = usePanelStore();
const { status, loaded } = storeToRefs(panelStore);

const MIN_PASSWORD = 12;
/** An update check older than this is redone when the page opens. */
const RECHECK_MS = 15 * 60 * 1000;
const API = endpoints.panel;

// ── Install / reconfigure form ───────────────────────────────────────────────

const reconfiguring = ref(false);
const showForm = computed(
  () => loaded.value && (!status.value.installed || reconfiguring.value),
);

const password = ref(generatePassword());
const showPassword = ref(true);
const port = ref(7778);
const selected = ref<Record<string, boolean>>({});

function resetForm(): void {
  const s = status.value;
  password.value = generatePassword();
  port.value = s.installed ? s.port : s.default_port;
  const current = new Set(s.subnets);
  selected.value = Object.fromEntries(
    s.subnet_choices.map((choice) => [
      choice.cidr,
      s.installed && current.size ? current.has(choice.cidr) : choice.default,
    ]),
  );
}

const chosenSubnets = computed(() =>
  status.value.subnet_choices
    .map((c) => c.cidr)
    .filter((cidr) => selected.value[cidr]),
);

function copy(text: string, what: string): void {
  navigator.clipboard
    .writeText(text)
    .then(() => ui.addToast({ t: `${what} copied`, k: "ok" }))
    .catch(() => ui.addToast({ t: "Could not copy", k: "warn" }));
}

function startReconfigure(): void {
  resetForm();
  reconfiguring.value = true;
}

function submit(): void {
  const secret = password.value.trim();
  if (secret.length < MIN_PASSWORD) {
    ui.addToast({
      t: "Password too short",
      d: `The service is reachable over the LAN — use at least ${MIN_PASSWORD} characters.`,
      k: "warn",
    });
    return;
  }
  if (!chosenSubnets.value.length) {
    ui.addToast({
      t: "Select a firewall scope",
      d: "Pick at least one subnet.",
      k: "warn",
    });
    return;
  }
  const s = status.value;
  const restartsSelf = s.is_self;
  const newPort = port.value;
  void run(
    `${API}/install`,
    {
      password: secret,
      port: newPort,
      allowed_subnets: chosenSubnets.value.join(","),
    },
    {
      onDone: () => {
        reconfiguring.value = false;
        if (!restartsSelf) return;
        if (newPort !== s.current_port) moveToPort(newPort);
        else void waitForRestart();
      },
    },
  );
}

// ── Version & updates ────────────────────────────────────────────────────────

const checking = ref(false);
const update = computed(() => status.value.update);
const hasUpdate = computed(
  () => !!update.value && !update.value.stale && update.value.behind > 0,
);

/** Pulled but not restarted: the page runs older code than the service has on disk. */
const restartPending = computed(() => {
  const s = status.value;
  return (
    s.is_self &&
    !!s.running_commit &&
    !!s.installed_commit &&
    s.running_commit.hash !== s.installed_commit.hash
  );
});

async function checkNow(quiet = false): Promise<void> {
  if (checking.value) return;
  checking.value = true;
  try {
    await panelStore.checkUpdates();
    if (!quiet) {
      const u = status.value.update;
      ui.addToast(
        u?.error
          ? { t: "Update check failed", d: u.error, k: "danger" }
          : u?.behind
            ? {
                t: `${u.behind} new commit${u.behind > 1 ? "s" : ""}`,
                k: "info",
              }
            : { t: "Up to date", k: "ok" },
      );
    }
  } catch (error) {
    if (!quiet) {
      ui.addToast({
        t: "Update check failed",
        d: error instanceof Error ? error.message : String(error),
        k: "danger",
      });
    }
  } finally {
    checking.value = false;
  }
}

// Recheck when the page opens if the last check is missing, stale or old.
let autoChecked = false;
watch(
  () => [loaded.value, status.value.installed] as const,
  ([isLoaded, installed]) => {
    if (!isLoaded) return;
    if (!reconfiguring.value) resetForm();
    if (!installed || autoChecked) return;
    autoChecked = true;
    const u = status.value.update;
    const age = u ? Date.now() - Date.parse(u.checked_at) : Infinity;
    if (!u || u.stale || !(age < RECHECK_MS)) void checkNow(true);
  },
  { immediate: true },
);

function runUpdate(): void {
  const s = status.value;
  ui.confirmThen(
    "Update and restart NsPanel?",
    `Pulls ${update.value?.behind ?? 0} commit(s) from ${s.branch}, reinstalls dependencies and ` +
      "restarts the service. If the new version fails its checks, nothing is restarted.",
    () => {
      void run(
        `${API}/update`,
        {},
        {
          onDone: () => {
            if (s.is_self) void waitForRestart();
          },
        },
      );
    },
  );
}

function restart(): void {
  const s = status.value;
  void run(
    `${API}/restart`,
    {},
    {
      onDone: () => {
        if (s.is_self) void waitForRestart();
      },
    },
  );
}

function uninstall(): void {
  ui.confirmThen(
    "Uninstall the NsPanel service?",
    `Stops and removes the service on port ${status.value.port}, its firewall rules, /etc/nspanel and ` +
      `${status.value.repo_dir}. The panel you are on is not affected.`,
    () => void run(`${API}/uninstall`),
  );
}

// ── Self-restart: wait for the service to come back, then load the new bundle ─

const restarting = ref(false);
let cancelled = false;
onUnmounted(() => {
  cancelled = true;
});

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function reloadPage(): Promise<void> {
  // The finished job lives in the process that just exited — do not reopen it.
  ui.overlay = null;
  await nextTick();
  window.location.reload();
}

/** The restart is scheduled a few seconds after the job ends: wait for the
 *  panel to go away and answer again (or to report a new running commit). */
async function waitForRestart(): Promise<void> {
  restarting.value = true;
  const before = status.value.running_commit?.hash;
  const started = Date.now();
  let sawDown = false;
  while (!cancelled && Date.now() - started < 60_000) {
    await sleep(1500);
    try {
      const next = await fetchData<PanelServiceStatus>(API);
      if (
        sawDown ||
        (next.running_commit && next.running_commit.hash !== before)
      ) {
        await reloadPage();
        return;
      }
    } catch (error) {
      // 401 after a password change still means it is back up.
      if (error instanceof ApiError && error.status === 401) {
        await reloadPage();
        return;
      }
      sawDown = true;
    }
    // Never went down: the job failed before restarting (e.g. a rolled-back update).
    if (!sawDown && Date.now() - started > 15_000) break;
  }
  restarting.value = false;
  if (!cancelled) void panelStore.load();
}

function moveToPort(newPort: number): void {
  restarting.value = true;
  const target = `${window.location.protocol}//${window.location.hostname}:${newPort}/#/panel`;
  ui.addToast({ t: "Service moved", d: `Opening ${target}`, k: "info" });
  ui.overlay = null;
  setTimeout(() => {
    window.location.href = target;
  }, 6000);
}

// ── Display helpers ──────────────────────────────────────────────────────────

function fmtDate(value: string | null | undefined): string {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
}

function ago(value: string | null | undefined): string {
  if (!value) return "never";
  const seconds = Math.max(0, (Date.now() - Date.parse(value)) / 1000);
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} h ago`;
  return `${Math.floor(seconds / 86400)} d ago`;
}

const otherCommits = computed(() => {
  const u = update.value;
  return u ? Math.max(0, u.total_behind - u.behind) : 0;
});
</script>

<template>
  <section>
    <PageHeader title="Panel service">
      <template #subtitle>
        Run NsPanel as a systemd service on the LAN, and keep it up to date from
        GitHub.
      </template>
      <Btn v-if="status.installed && !showForm" @click="startReconfigure">
        <LIcon name="pencil" /> Reconfigure
      </Btn>
    </PageHeader>

    <div
      v-if="restarting"
      class="flex items-center gap-2.5 mb-3 py-2.5 px-3.5 rounded-theme border border-c-border bg-c-infosoft text-c-info text-sm-var"
      role="status"
    >
      <span
        class="w-3.5 h-3.5 rounded-full border-[1.5px] border-c-bstrong border-t-c-accent animate-spin"
      ></span>
      Restarting the panel — this page reloads when it is back.
    </div>

    <Card v-if="!loaded" class="p-4"><Skeleton :count="5" /></Card>

    <!-- Install / reconfigure -->
    <Card v-else-if="showForm" class="overflow-clip max-w-[640px]">
      <div
        class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border"
      >
        <h3
          class="m-0 text-sm-var font-semibold tracking-[-0.01em] flex items-center gap-2"
        >
          <LIcon name="rocket" is="width:14px;height:14px" />
          {{
            status.installed
              ? "Reconfigure the service"
              : "Install as a service"
          }}
        </h3>
        <span class="text-xs-var text-c-tx3 mono">{{
          status.repo_dir || "/opt/nspanel"
        }}</span>
      </div>
      <div class="p-4 flex flex-col gap-4">
        <p class="m-0 text-sm-var text-c-tx2">
          Clones the panel from GitHub ({{ status.branch }}) into its own
          directory, starts it with systemd on boot, and opens the port in UFW
          for the networks you pick.
          <template v-if="status.installed && status.is_self">
            Saving restarts the panel you are on.
          </template>
        </p>

        <div>
          <label class="block text-xs-var text-c-tx2 mb-1.5">
            <span class="uppercase tracking-[0.05em] text-[10px] font-medium">
              Password for user admin
            </span>
          </label>
          <div class="flex items-center gap-1.5">
            <div class="relative flex-1">
              <input
                v-model="password"
                :type="showPassword ? 'text' : 'password'"
                class="input mono w-full pr-8"
                autocomplete="new-password"
                spellcheck="false"
                aria-label="Password"
              />
              <button
                type="button"
                class="absolute right-1.5 top-1/2 -translate-y-1/2 text-c-tx3 hover:text-c-tx p-1"
                :aria-label="showPassword ? 'Hide' : 'Show'"
                @click="showPassword = !showPassword"
              >
                <LIcon
                  :name="showPassword ? 'eye-off' : 'eye'"
                  is="width:14px;height:14px"
                />
              </button>
            </div>
            <Btn
              title="Generate a random password"
              @click="password = generatePassword()"
            >
              <LIcon name="dices" /> Generate
            </Btn>
            <Btn
              square
              title="Copy password"
              aria-label="Copy password"
              @click="copy(password, 'Password')"
            >
              <LIcon name="copy" />
            </Btn>
          </div>
          <div class="text-[11px] text-c-tx3 mt-1.5">
            At least {{ MIN_PASSWORD }} characters. Stored in
            /etc/nspanel/nspanel.env (root only) — copy it now, the panel does
            not show it again.
          </div>
        </div>

        <div>
          <label class="block text-xs-var text-c-tx2 mb-1.5">
            <span class="uppercase tracking-[0.05em] text-[10px] font-medium"
              >Port</span
            >
          </label>
          <input
            v-model.number="port"
            type="number"
            min="1024"
            max="65535"
            class="input mono"
            style="max-width: 140px"
            aria-label="Port"
          />
        </div>

        <div>
          <label class="block text-xs-var text-c-tx2 mb-1.5">
            <span class="uppercase tracking-[0.05em] text-[10px] font-medium">
              Open port {{ port }} to
            </span>
          </label>
          <div
            class="flex flex-col gap-1 border border-c-border rounded-theme p-1.5 bg-c-elev"
          >
            <label
              v-for="option in status.subnet_choices"
              :key="option.cidr"
              :class="[
                'flex items-center gap-2.5 px-2 py-1.5 rounded-theme cursor-pointer select-none hover:bg-c-hover',
                option.cidr === ANY_IP && selected[option.cidr]
                  ? 'text-c-warn'
                  : '',
              ]"
            >
              <input
                type="checkbox"
                class="w-3.5 h-3.5 accent-c-accent rounded shrink-0"
                :checked="selected[option.cidr]"
                @change="toggleSubnet(selected, option.cidr)"
              />
              <span class="text-sm-var flex-1">{{ option.label }}</span>
              <span class="mono text-[11px] text-c-tx3 tabular-nums">{{
                option.cidr
              }}</span>
            </label>
          </div>
          <div
            v-if="selected[ANY_IP]"
            class="flex items-start gap-1.5 text-[11px] text-c-warn mt-1.5"
          >
            <LIcon
              name="triangle-alert"
              is="width:12px;height:12px;margin-top:1px;flex-shrink:0"
            />
            <span
              >Anyone who can reach this server could try the panel login.</span
            >
          </div>
          <div class="text-[11px] text-c-tx3 mt-1.5">
            UFW rules only — UFW itself is not switched on if it is off.
          </div>
        </div>

        <div
          class="flex items-start gap-2 text-[11px] text-c-tx2 py-2 px-2.5 rounded-theme bg-c-subtle border border-c-border"
        >
          <LIcon
            name="info"
            is="width:13px;height:13px;margin-top:1px;flex-shrink:0"
          />
          <span>
            The service speaks plain HTTP: anyone on the same network segment
            could read the password in transit. Use a strong one, or put an
            nginx site with SSL in front of it.
          </span>
        </div>

        <div class="flex justify-end gap-1.5">
          <Btn v-if="status.installed" @click="reconfiguring = false"
            >Cancel</Btn
          >
          <Btn variant="primary" @click="submit">
            <LIcon :name="status.installed ? 'check' : 'download'" />
            {{ status.installed ? "Save & restart" : "Install service" }}
          </Btn>
        </div>
      </div>
    </Card>

    <!-- Installed -->
    <div v-else class="grid grid-cols-1 lg:grid-cols-2 gap-3">
      <Card class="overflow-clip">
        <div
          class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border"
        >
          <h3
            class="m-0 text-sm-var font-semibold tracking-[-0.01em] flex items-center gap-2"
          >
            <LIcon name="server" is="width:14px;height:14px" /> Service
          </h3>
          <div class="flex items-center gap-1.5">
            <Badge v-if="status.is_self" tone="accent">this panel</Badge>
            <StatusBadge :status="status.active" />
            <StatusBadge :status="status.enabled" />
          </div>
        </div>
        <div class="p-4">
          <dl
            class="grid grid-cols-1 sm:grid-cols-[120px_1fr] gap-y-2.5 gap-x-4 text-sm-var m-0"
          >
            <dt class="text-c-tx2 font-medium">Open at</dt>
            <dd class="m-0 flex flex-col gap-1">
              <span
                v-for="url in status.urls"
                :key="url"
                class="flex items-center gap-1.5"
              >
                <a
                  :href="url"
                  target="_blank"
                  rel="noopener"
                  class="mono text-xs-var text-c-actx underline underline-offset-2"
                  >{{ url }}</a
                >
                <button
                  class="text-c-tx3 hover:text-c-tx p-0.5"
                  :aria-label="`Copy ${url}`"
                  @click="copy(url, 'URL')"
                >
                  <LIcon name="copy" is="width:12px;height:12px" />
                </button>
              </span>
              <span v-if="!status.urls.length" class="text-c-tx3">—</span>
            </dd>
            <dt class="text-c-tx2 font-medium">Firewall</dt>
            <dd class="m-0 mono text-xs-var">
              {{ status.subnets.join(", ") || "—" }}
            </dd>
            <dt class="text-c-tx2 font-medium">Directory</dt>
            <dd class="m-0 mono text-xs-var break-all">
              {{ status.repo_dir }}
            </dd>
            <dt class="text-c-tx2 font-medium">Installed</dt>
            <dd class="m-0 text-xs-var">{{ fmtDate(status.installed_at) }}</dd>
          </dl>
          <div class="flex flex-wrap gap-1.5 mt-4">
            <Btn sm @click="restart"><LIcon name="rotate-cw" /> Restart</Btn>
            <Btn v-if="!status.is_self" sm variant="danger" @click="uninstall">
              <LIcon name="octagon-x" /> Uninstall
            </Btn>
          </div>
        </div>
      </Card>

      <Card class="overflow-clip">
        <div
          class="flex items-center justify-between gap-3 py-3.5 px-4 border-b border-c-border"
        >
          <h3
            class="m-0 text-sm-var font-semibold tracking-[-0.01em] flex items-center gap-2"
          >
            <LIcon name="git-merge" is="width:14px;height:14px" /> Version
          </h3>
          <span class="text-xs-var text-c-tx3 mono">{{ status.branch }}</span>
        </div>
        <div class="p-4">
          <dl
            class="grid grid-cols-1 sm:grid-cols-[120px_1fr] gap-y-2.5 gap-x-4 text-sm-var m-0"
          >
            <dt class="text-c-tx2 font-medium">Installed</dt>
            <dd class="m-0">
              <template v-if="status.installed_commit">
                <span
                  class="mono text-xs-var select-all"
                  :title="status.installed_commit.hash"
                  >{{ status.installed_commit.short }}</span
                >
                <span class="text-c-tx2">
                  · {{ status.installed_commit.subject }}</span
                >
              </template>
              <span v-else class="text-c-tx3">unknown</span>
            </dd>
            <dt class="text-c-tx2 font-medium">Commit date</dt>
            <dd class="m-0 text-xs-var">
              {{ fmtDate(status.installed_commit?.date) }}
            </dd>
            <dt class="text-c-tx2 font-medium">Last updated</dt>
            <dd class="m-0 text-xs-var">{{ fmtDate(status.updated_at) }}</dd>
          </dl>

          <div
            v-if="restartPending"
            class="flex items-center gap-2 mt-3 py-2 px-2.5 rounded-theme bg-c-warnsoft text-c-warn text-xs-var"
          >
            <LIcon
              name="triangle-alert"
              is="width:13px;height:13px;flex-shrink:0"
            />
            <span class="flex-1">
              Running {{ status.running_commit?.short }}, but
              {{ status.installed_commit?.short }} is on disk.
            </span>
            <Btn sm variant="warn" @click="restart">Restart</Btn>
          </div>

          <div class="mt-4 pt-3 border-t border-c-border">
            <div class="flex items-center gap-2 mb-2">
              <span
                class="text-xs-var font-semibold uppercase tracking-[0.06em] text-c-tx2"
                >Updates</span
              >
              <Badge v-if="checking" tone="muted">checking…</Badge>
              <Badge v-else-if="update?.error" tone="danger"
                >check failed</Badge
              >
              <Badge v-else-if="hasUpdate" tone="info">
                {{ update?.behind }} new commit{{
                  (update?.behind ?? 0) > 1 ? "s" : ""
                }}
              </Badge>
              <Badge v-else-if="update && !update.stale" tone="ok"
                >up to date</Badge
              >
              <span class="ml-auto text-[11px] text-c-tx3">
                checked {{ ago(update?.checked_at) }}
              </span>
              <Btn sm variant="ghost" :disabled="checking" @click="checkNow()">
                <LIcon name="refresh-cw" /> Check now
              </Btn>
            </div>

            <div
              v-if="update?.error"
              class="text-xs-var text-c-danger mono break-all"
            >
              {{ update.error }}
            </div>
            <ul
              v-else-if="hasUpdate"
              class="m-0 p-0 list-none flex flex-col gap-1"
            >
              <li
                v-for="commit in update?.commits"
                :key="commit.hash"
                class="flex items-baseline gap-2 text-xs-var"
              >
                <span class="mono text-c-tx3">{{ commit.short }}</span>
                <span class="flex-1 min-w-0 truncate" :title="commit.subject">{{
                  commit.subject
                }}</span>
                <span class="text-c-tx3 tabular-nums">{{
                  fmtDate(commit.date)
                }}</span>
              </li>
            </ul>
            <div
              v-else-if="update && !update.stale"
              class="text-xs-var text-c-tx3"
            >
              Latest on {{ status.branch }}:
              {{ update.remote_commit?.short ?? "—" }}
              <template v-if="otherCommits">
                · {{ otherCommits }} newer commit{{
                  otherCommits > 1 ? "s" : ""
                }}
                outside the panel, no update needed
              </template>
            </div>

            <div v-if="hasUpdate" class="flex justify-end mt-3">
              <Btn variant="primary" sm @click="runUpdate">
                <LIcon name="download" /> Update &amp; restart
              </Btn>
            </div>
          </div>
        </div>
      </Card>
    </div>
  </section>
</template>
