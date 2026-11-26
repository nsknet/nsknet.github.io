/** Types for the Activity and Settings screens that are not part of the API
 *  envelope itself (rendered rows, form values). Raw API shapes stay in types.ts. */

/** One `key=value` pair of an audit entry's detail. `key` is '' for free text. */
export interface AuditDetailPart {
  key: string;
  value: string;
}

/** One audit log line, ready to render (GET /api/v1/logs → `{ts,action,detail,user,ip}`). */
export interface AuditRow {
  /** Position in the loaded list — entries have no id of their own. */
  id: number;
  /** As stored (UTC ISO 8601, or a legacy free-form stamp). */
  ts: string;
  action: string;
  /** The part of `action` before the first dot: `service`, `tool`, … */
  namespace: string;
  /** The detail split into chips. */
  detail: AuditDetailPart[];
  /** The detail as stored, for search and copy. */
  rawDetail: string;
  user: string;
  ip: string;
}

/** What POST /api/v1/panel/install takes. `password` is omitted to keep the current one. */
export interface PanelInstallValues {
  password?: string;
  port: number;
  allowed_subnets: string;
  tls: boolean;
}

/** Where the panel will answer after a reconfigure. */
export interface PanelTarget {
  port: number;
  /** `https:` or `http:` */
  scheme: string;
}
