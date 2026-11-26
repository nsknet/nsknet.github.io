export type Tone = 'ok' | 'warn' | 'danger' | 'info' | 'accent' | 'muted' | 'neutral';

/** One row of a KeyValueList. */
export interface KeyValueItem {
  key: string;
  label: string;
  value?: string | number | null;
  mono?: boolean;
  /** Copy button next to the value. */
  copy?: boolean;
}

/** One tab of a Tabs strip. */
export interface TabItem {
  key: string;
  label: string;
  icon?: string;
  /** Small count or status shown after the label. */
  badge?: string | number;
}

/** One column of a DataTable. */
export interface Column<Row = Record<string, unknown>> {
  key: string;
  label: string;
  /** Sort by this column; `sortValue` overrides what is compared. */
  sortable?: boolean;
  sortValue?: (row: Row) => string | number;
  /** Direction of the first click (numbers people scan from the top: 'desc'). */
  sortFirst?: 'asc' | 'desc';
  align?: 'left' | 'right' | 'center';
  /** Extra classes for the cells (e.g. 'mono', 'num'). */
  class?: string;
  /** Hidden below the md breakpoint. */
  hideOnMobile?: boolean;
  /** Visually hidden header (an icon or action column). */
  srOnlyLabel?: boolean;
}
