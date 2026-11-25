/** Cross-screen UI state: theme, sidebar, toasts, the command palette and the four modal dialogs. */
import { defineStore } from 'pinia';
import { computed, ref, watch } from 'vue';

import type { InstallParam, NetworkInterface } from '@/api/types';

export type ToastKind = 'ok' | 'info' | 'warn' | 'danger';

export interface Toast {
  id: number;
  t: string;
  d: string;
  k: ToastKind;
  /** Times the same toast was raised while it was showing. */
  count: number;
}

export type ThemeMode = 'system' | 'light' | 'dark';

export interface Overlay {
  jobId: string | null;
  title: string;
  /** Called when the job finishes; `ok` is false for a non-zero exit. */
  onDone: ((ok: boolean, exitCode: number) => void) | null;
}

export interface ConfirmOptions {
  /** Red button and warning icon: the action deletes or stops something. */
  danger?: boolean;
  /** Verb on the confirm button, e.g. "Delete rule". Defaults to "Continue". */
  confirmLabel?: string;
  /** The operator must type this exactly before the button enables. */
  typeToConfirm?: string;
  /** Extra facts shown as a list: what is affected, what cannot be undone. */
  details?: string[];
}

export interface Confirm extends ConfirmOptions {
  title: string;
  body: string;
  onYes: () => void;
}

export interface InstallDialogTool {
  id: string;
  name: string;
  requiresPassword: boolean;
  firewallPorts: number[];
  allowPublic?: boolean;
  installParams: InstallParam[];
}

export interface InstallDialog {
  tool: InstallDialogTool;
  mode: 'install' | 'password';
  /** Return false (or a promise of false) to keep the dialog open, e.g. when the request failed. */
  onConfirm: (values: Record<string, string>) => void | boolean | Promise<boolean | void>;
}

export interface NetworkDialog {
  iface: string;
  current: NetworkInterface;
  onConfirm: (values: Record<string, string>) => void;
}

const TOAST_MS = 4500;
const THEME_KEY = 'nspanel.theme';
/** How long colours cross-fade after a theme flip (see .theme-switching in theme.css). */
const THEME_FADE_MS = 250;

function readBool(key: string, fallback: boolean): boolean {
  try {
    const stored = localStorage.getItem(key);
    return stored === null ? fallback : stored === '1';
  } catch {
    return fallback;
  }
}

/** The open job dialog survives a reload (F5) through sessionStorage — per tab. */
const OVERLAY_KEY = 'nspanel.overlay';

function readOverlay(): Overlay | null {
  try {
    const raw = sessionStorage.getItem(OVERLAY_KEY);
    if (!raw) return null;
    const saved = JSON.parse(raw) as { jobId?: unknown; title?: unknown };
    if (typeof saved.jobId !== 'string') return null;
    return { jobId: saved.jobId, title: String(saved.title ?? 'Running…'), onDone: null };
  } catch {
    return null;
  }
}

function writeOverlay(overlay: Overlay | null): void {
  try {
    if (overlay?.jobId) {
      sessionStorage.setItem(
        OVERLAY_KEY,
        JSON.stringify({ jobId: overlay.jobId, title: overlay.title }),
      );
    } else {
      sessionStorage.removeItem(OVERLAY_KEY);
    }
  } catch {
    /* storage blocked — the dialog simply does not come back after a reload */
  }
}

function writeBool(key: string, value: boolean): void {
  try {
    localStorage.setItem(key, value ? '1' : '0');
  } catch {
    /* private mode — the preference simply does not persist */
  }
}

function readThemeMode(): ThemeMode {
  try {
    const stored = localStorage.getItem(THEME_KEY);
    if (stored === 'light' || stored === 'dark' || stored === 'system') return stored;
    return localStorage.getItem('themeDark') === '1' ? 'dark' : 'system';
  } catch {
    return 'system';
  }
}

// Absent in some embedded browsers and in tests.
const systemDark =
  typeof window.matchMedia === 'function' ? window.matchMedia('(prefers-color-scheme: dark)') : null;

export const useUiStore = defineStore('ui', () => {
  const themeMode = ref<ThemeMode>(readThemeMode());
  const systemPrefersDark = ref(systemDark?.matches ?? false);
  systemDark?.addEventListener('change', (event) => {
    systemPrefersDark.value = event.matches;
    if (themeMode.value === 'system') applyTheme(true);
  });
  const theme = computed<'light' | 'dark'>(() =>
    themeMode.value === 'system' ? (systemPrefersDark.value ? 'dark' : 'light') : themeMode.value,
  );
  /** Drawer state on narrow screens (the rail is hidden below md). */
  const mobileNavOpen = ref(false);
  const sidebarOpen = ref(readBool('sidebarOpen', false));
  const toasts = ref<Toast[]>([]);
  const overlay = ref<Overlay | null>(readOverlay());
  watch(overlay, writeOverlay);
  const confirm = ref<Confirm | null>(null);
  const installDialog = ref<InstallDialog | null>(null);
  const networkDialog = ref<NetworkDialog | null>(null);
  const paletteOpen = ref(false);

  let fadeTimer: ReturnType<typeof setTimeout> | undefined;

  function applyTheme(animate = false): void {
    const dark = theme.value === 'dark';
    const root = document.documentElement;
    if (animate) {
      document.body.classList.add('theme-switching');
      clearTimeout(fadeTimer);
      fadeTimer = setTimeout(() => document.body.classList.remove('theme-switching'), THEME_FADE_MS);
    }
    root.classList.toggle('theme-dark', dark);
    root.classList.toggle('theme-light', !dark);
  }

  function setThemeMode(mode: ThemeMode): void {
    themeMode.value = mode;
    try {
      localStorage.setItem(THEME_KEY, mode);
      localStorage.removeItem('themeDark');
    } catch {
      /* private mode — the preference simply does not persist */
    }
    applyTheme(true);
  }

  /** system → light → dark → system */
  function toggleTheme(): void {
    const next: Record<ThemeMode, ThemeMode> = { system: 'light', light: 'dark', dark: 'system' };
    setThemeMode(next[themeMode.value]);
  }

  function toggleSidebar(): void {
    sidebarOpen.value = !sidebarOpen.value;
    writeBool('sidebarOpen', sidebarOpen.value);
  }

  function dismissToast(id: number): void {
    const index = toasts.value.findIndex((toast) => toast.id === id);
    if (index >= 0) toasts.value.splice(index, 1);
  }

  /** Errors stay until dismissed; others fade. A repeat of a showing toast
   *  bumps its counter instead of stacking a copy (e.g. a poll while offline). */
  function addToast({ t = '', d = '', k = 'info' as ToastKind } = {}): void {
    const same = toasts.value.find((toast) => toast.t === t && toast.d === d && toast.k === k);
    if (same) {
      same.count += 1;
      return;
    }
    const id = Date.now() + Math.random();
    toasts.value.push({ id, t, d, k, count: 1 });
    if (toasts.value.length > 5) toasts.value.shift();
    if (k !== 'danger') setTimeout(() => dismissToast(id), TOAST_MS);
  }

  function openOverlay(options: Partial<Overlay> = {}): void {
    overlay.value = {
      jobId: options.jobId ?? null,
      title: options.title ?? 'Running…',
      onDone: options.onDone ?? null,
    };
  }

  function confirmThen(
    title: string,
    body: string,
    onYes: () => void,
    options: ConfirmOptions = {},
  ): void {
    confirm.value = { title, body, onYes, ...options };
  }

  function openInstallDialog(
    tool: InstallDialogTool,
    onConfirm: InstallDialog['onConfirm'],
    mode: InstallDialog['mode'] = 'install',
  ): void {
    installDialog.value = { tool, onConfirm, mode };
  }

  function openNetworkDialog(
    iface: string,
    current: NetworkInterface,
    onConfirm: NetworkDialog['onConfirm'],
  ): void {
    networkDialog.value = { iface, current, onConfirm };
  }

  return {
    theme,
    themeMode,
    setThemeMode,
    mobileNavOpen,
    sidebarOpen,
    toasts,
    dismissToast,
    overlay,
    confirm,
    installDialog,
    networkDialog,
    paletteOpen,
    applyTheme,
    toggleTheme,
    toggleSidebar,
    addToast,
    openOverlay,
    confirmThen,
    openInstallDialog,
    openNetworkDialog,
  };
});
