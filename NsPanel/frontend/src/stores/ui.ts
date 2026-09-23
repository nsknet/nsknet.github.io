/** Cross-screen UI state: theme, sidebar, toasts and the four modal dialogs. */
import { defineStore } from 'pinia';
import { ref } from 'vue';

import type { InstallParam, NetworkInterface } from '@/api/types';

export type ToastKind = 'ok' | 'info' | 'warn' | 'danger';

export interface Toast {
  id: number;
  t: string;
  d: string;
  k: ToastKind;
}

export interface Overlay {
  jobId: string | null;
  title: string;
  onDone: (() => void) | null;
}

export interface Confirm {
  title: string;
  body: string;
  onYes: () => void;
}

export interface InstallDialogTool {
  id: string;
  name: string;
  requiresPassword: boolean;
  firewallPorts: number[];
  installParams: InstallParam[];
}

export interface InstallDialog {
  tool: InstallDialogTool;
  mode: 'install' | 'password';
  onConfirm: (values: Record<string, string>) => void;
}

export interface NetworkDialog {
  iface: string;
  current: NetworkInterface;
  onConfirm: (values: Record<string, string>) => void;
}

const TOAST_MS = 3700;

function readBool(key: string, fallback: boolean): boolean {
  try {
    const stored = localStorage.getItem(key);
    return stored === null ? fallback : stored === '1';
  } catch {
    return fallback;
  }
}

function writeBool(key: string, value: boolean): void {
  try {
    localStorage.setItem(key, value ? '1' : '0');
  } catch {
    /* private mode — the preference simply does not persist */
  }
}

export const useUiStore = defineStore('ui', () => {
  const theme = ref<'light' | 'dark'>(readBool('themeDark', false) ? 'dark' : 'light');
  const sidebarOpen = ref(readBool('sidebarOpen', false));
  const toasts = ref<Toast[]>([]);
  const overlay = ref<Overlay | null>(null);
  const confirm = ref<Confirm | null>(null);
  const installDialog = ref<InstallDialog | null>(null);
  const networkDialog = ref<NetworkDialog | null>(null);

  function applyTheme(): void {
    const dark = theme.value === 'dark';
    document.body.classList.toggle('theme-dark', dark);
    document.body.classList.toggle('theme-light', !dark);
  }

  function toggleTheme(): void {
    theme.value = theme.value === 'dark' ? 'light' : 'dark';
    writeBool('themeDark', theme.value === 'dark');
    applyTheme();
  }

  function toggleSidebar(): void {
    sidebarOpen.value = !sidebarOpen.value;
    writeBool('sidebarOpen', sidebarOpen.value);
  }

  function addToast({ t = '', d = '', k = 'info' as ToastKind } = {}): void {
    const id = Date.now() + Math.random();
    toasts.value.push({ id, t, d, k });
    setTimeout(() => {
      const index = toasts.value.findIndex((toast) => toast.id === id);
      if (index >= 0) toasts.value.splice(index, 1);
    }, TOAST_MS);
  }

  function openOverlay(options: Partial<Overlay> = {}): void {
    overlay.value = {
      jobId: options.jobId ?? null,
      title: options.title ?? 'Running…',
      onDone: options.onDone ?? null,
    };
  }

  function confirmThen(title: string, body: string, onYes: () => void): void {
    confirm.value = { title, body, onYes };
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
    sidebarOpen,
    toasts,
    overlay,
    confirm,
    installDialog,
    networkDialog,
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
