/** Modal dialog behaviour shared by every dialog: a stack, focus and Escape.
 *
 * - Only the top-most dialog reacts to Escape (one keydown listener for all).
 * - Focus moves into the dialog on open, Tab cycles inside it, and focus goes
 *   back to whatever had it when the dialog closes.
 * - The page behind stops scrolling while any dialog is open.
 */
import { onBeforeMount, onMounted, onUnmounted, type Ref } from 'vue';

interface Entry {
  id: number;
  el: Ref<HTMLElement | null>;
  onEscape: () => void;
}

const stack: Entry[] = [];
let nextId = 1;
let listening = false;

const FOCUSABLE = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',');

function focusables(root: HTMLElement): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
    (el) => el.offsetParent !== null || el === document.activeElement,
  );
}

function onKeydown(event: KeyboardEvent): void {
  const top = stack[stack.length - 1];
  if (!top) return;
  if (event.key === 'Escape') {
    event.preventDefault();
    event.stopPropagation();
    top.onEscape();
    return;
  }
  if (event.key !== 'Tab' || !top.el.value) return;
  const items = focusables(top.el.value);
  if (!items.length) {
    event.preventDefault();
    return;
  }
  const first = items[0];
  const last = items[items.length - 1];
  const active = document.activeElement as HTMLElement | null;
  if (event.shiftKey && (active === first || !top.el.value.contains(active))) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && (active === last || !top.el.value.contains(active))) {
    event.preventDefault();
    first.focus();
  }
}

/** True while any dialog is open (e.g. so global shortcuts stay quiet). */
export function dialogOpen(): boolean {
  return stack.length > 0;
}

export function useDialog(el: Ref<HTMLElement | null>, onEscape: () => void): void {
  const entry: Entry = { id: nextId++, el, onEscape };
  let previousFocus: HTMLElement | null = null;

  // Registered before mount: a parent dialog's beforeMount runs before its
  // children's, so a dialog nested in another's template lands above it.
  onBeforeMount(() => {
    previousFocus = document.activeElement as HTMLElement | null;
    stack.push(entry);
  });

  onMounted(() => {
    if (!listening) {
      document.addEventListener('keydown', onKeydown, true);
      listening = true;
    }
    document.body.style.overflow = 'hidden';
    // Prefer an element marked [data-autofocus], else the first focusable one.
    const root = el.value;
    if (root) {
      const preferred = root.querySelector<HTMLElement>('[data-autofocus]');
      (preferred ?? focusables(root)[0] ?? root).focus();
    }
  });

  onUnmounted(() => {
    const index = stack.findIndex((item) => item.id === entry.id);
    if (index >= 0) stack.splice(index, 1);
    if (!stack.length) {
      document.body.style.overflow = '';
      document.removeEventListener('keydown', onKeydown, true);
      listening = false;
    }
    if (previousFocus && document.contains(previousFocus)) previousFocus.focus();
  });
}
