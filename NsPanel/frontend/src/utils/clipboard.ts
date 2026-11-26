/** Copy text and say so — the single copy helper for every screen. */
import { useUiStore } from '@/stores/ui';

export async function copyText(text: string, what = 'Text'): Promise<boolean> {
  const ui = useUiStore();
  try {
    await navigator.clipboard.writeText(text);
    ui.addToast({ t: `${what} copied`, k: 'ok' });
    return true;
  } catch (error) {
    // Clipboard API needs a secure context (https or localhost).
    ui.addToast({
      t: `Could not copy ${what.toLowerCase()}`,
      d: error instanceof Error ? error.message : 'The browser blocked clipboard access.',
      k: 'warn',
    });
    return false;
  }
}
