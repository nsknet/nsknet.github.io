/** What the Storage screen may do with a block device, and why not. */
import type { DiskNode } from '@/api/system';

export const FS_TYPES = ['ext4', 'xfs', 'btrfs', 'vfat', 'ntfs', 'ext3', 'ext2'] as const;
export type FsType = (typeof FS_TYPES)[number];

/** Signatures that mean the device belongs to something else (not mountable). */
const MEMBER_FSTYPES = new Set(['swap', 'LVM2_member', 'linux_raid_member', 'crypto_LUKS', 'zfs_member']);

/** core/validators.py MOUNT */
export const MOUNT_POINT = /^\/[A-Za-z0-9][A-Za-z0-9/_.-]{0,127}$/;
/** routes/system.py _LABEL_RE */
export const LABEL = /^[A-Za-z0-9._-]{1,32}$/;

export interface DiskRow extends DiskNode {
  level: number;
}

/** Depth-first: each disk followed by its partitions. */
export function flatten(nodes: DiskNode[], level = 0, out: DiskRow[] = []): DiskRow[] {
  for (const node of nodes) {
    out.push({ ...node, level });
    flatten(node.children ?? [], level + 1, out);
  }
  return out;
}

export function isMounted(node: DiskNode): boolean {
  return !!node.mountpoint && node.mountpoint !== '[SWAP]';
}

export function canMount(node: DiskNode): boolean {
  return (
    !node.mountpoint &&
    !!node.fstype &&
    !MEMBER_FSTYPES.has(node.fstype) &&
    !(node.children ?? []).length &&
    node.path.startsWith('/dev/')
  );
}

/** Why Unmount is not offered for a mounted node, or ''. */
export function unmountBlock(node: DiskNode): string {
  if (['/', '/boot', '/boot/efi'].includes(node.mountpoint)) return `${node.mountpoint} is a system mount`;
  return '';
}

export function formattable(node: DiskNode): boolean {
  return ['disk', 'part', 'lvm'].includes(node.type) && node.path.startsWith('/dev/');
}

/** Why Format is locked, or '' when the device looks free. */
export function formatBlock(node: DiskNode): string {
  if (node.system) return 'System device: holds /, /boot or swap';
  if (node.in_use) return `In use: ${node.in_use}`;
  if (node.readonly) return 'Read-only device';
  return '';
}

export function deviceSummary(node: DiskNode): string {
  const vendor = node.vendor && !node.model.includes(node.vendor) ? node.vendor : '';
  return [vendor, node.model].filter(Boolean).join(' ');
}
