import type { model } from "../wailsjs/go/models";

export type Account = model.Account;
export type AccountStatus = model.AccountStatus;
export type Database = model.Database;
export type Snapshot = model.Snapshot;
export type BackupPlanSummary = model.BackupPlanSummary;
export type AWSBackupPlanRef = model.AWSBackupPlanRef;
export type Schedule = model.Schedule;
export type Activity = model.Activity;

export type DBKind = "instance" | "cluster";
export type SnapshotSource = "manual" | "automated" | "aws-backup";
export type ScheduleSource = "automated-window" | "aws-backup-rule";
export type RestoreSource = "snapshot" | "pitr" | "recovery-point";
export type AccountState = "ok" | "expired" | "error";

/** Go `time.Time` fields reach the frontend as ISO-8601 strings (or
 * null/undefined for an omitted pointer). */
export type ISODate = string | null | undefined;

export function parseDate(v: ISODate): Date | null {
  if (!v) return null;
  const d = new Date(v as unknown as string);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function ago(v: ISODate): string {
  const d = parseDate(v);
  if (!d) return "—";
  const diffMs = Date.now() - d.getTime();
  const future = diffMs < 0;
  const secs = Math.abs(diffMs) / 1000;
  const units: [number, string][] = [
    [60, "s"],
    [60, "m"],
    [24, "h"],
    [30, "d"],
  ];
  let value = secs;
  let unit = "s";
  for (const [size, label] of units) {
    if (value < size) {
      unit = label;
      break;
    }
    value /= size;
    unit = label;
  }
  const n = Math.max(1, Math.round(value));
  return future ? `in ${n}${unit}` : `${n}${unit} ago`;
}

export function dateFull(v: ISODate): string {
  const d = parseDate(v);
  if (!d) return "—";
  return d.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

export function dateInput(v: ISODate): string {
  const d = parseDate(v);
  if (!d) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function sizeGB(gb: number): string {
  if (!gb) return "0 GB";
  if (gb >= 1024) {
    const tb = gb / 1024;
    return (Number.isInteger(tb) ? tb.toFixed(0) : tb.toFixed(1)) + " TB";
  }
  return gb + " GB";
}

export const engineLabels: Record<string, string> = {
  "aurora-postgresql": "Aurora PostgreSQL",
  "aurora-mysql": "Aurora MySQL",
  postgres: "PostgreSQL",
  mysql: "MySQL",
  mariadb: "MariaDB",
  oracle: "Oracle",
  sqlserver: "SQL Server",
};
export function engineLabel(engine: string): string {
  return engineLabels[engine] ?? engine;
}

export const sourceLabels: Record<SnapshotSource, string> = {
  manual: "Manual",
  automated: "Automated",
  "aws-backup": "AWS Backup",
};

export const scheduleSourceLabels: Record<ScheduleSource, string> = {
  "automated-window": "Automated window",
  "aws-backup-rule": "AWS Backup rule",
};

export const restoreSourceLabels: Record<RestoreSource, string> = {
  snapshot: "Snapshot",
  pitr: "Point in time",
  "recovery-point": "AWS Backup recovery point",
};

export type Tone = "ok" | "warn" | "danger" | "neutral" | "info";

export function statusTone(status: string): Tone {
  const s = status.toLowerCase();
  if (["available", "completed", "active", "ok"].includes(s)) return "ok";
  if (
    ["creating", "running", "backing-up", "pending", "modifying", "loading", "copying"].includes(s)
  )
    return "info";
  if (["failed", "error", "incompatible-restore"].includes(s)) return "danger";
  if (["stopped", "stopping"].includes(s)) return "warn";
  return "neutral";
}

export function isProd(db: Database): boolean {
  return (db.tags?.env ?? "").toLowerCase() === "prod";
}

export function kindLabel(kind: string): string {
  return kind === "cluster" ? "Cluster" : "Instance";
}

export function suggestSnapshotName(dbId: string): string {
  const now = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${dbId}-manual-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(
    now.getHours(),
  )}${pad(now.getMinutes())}`;
}

export function regionsLabel(regions: string[] | undefined): string {
  return regions && regions.length ? regions.join(", ") : "—";
}

export const accountPalette = [
  "#2563eb",
  "#16a34a",
  "#d97706",
  "#7c3aed",
  "#0891b2",
  "#db2777",
  "#64748b",
];

export function slugify(name: string): string {
  return (
    name
      .trim()
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "") || "account"
  );
}

export function uniqueId(base: string, taken: Set<string>): string {
  if (!taken.has(base)) return base;
  let n = 2;
  while (taken.has(`${base}-${n}`)) n++;
  return `${base}-${n}`;
}

export function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return "?";
  return (parts[0][0] + (parts[1]?.[0] ?? "")).toUpperCase();
}

/** Minimum AWS Backup lifecycle retention the app will submit; mirrors the
 * backend guard so the form never offers a value the service would reject. */
export const MIN_AWS_BACKUP_RETENTION_DAYS = 7;
/** Minimum automated-backup retention; retention can only be raised, never
 * set to 0, per the product's no-delete invariant. */
export const MIN_AUTOMATED_RETENTION_DAYS = 1;
