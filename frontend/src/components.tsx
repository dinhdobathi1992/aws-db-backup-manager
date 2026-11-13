import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import {
  AlertTriangle,
  CheckCircle2,
  Info,
  Lock,
  ShieldCheck,
  Unlock,
  X,
  XCircle,
} from "lucide-react";
import { accountPalette, initials, type Tone } from "./lib";

// ---------------------------------------------------------------------------
// Layout atoms
// ---------------------------------------------------------------------------

export function Card({
  children,
  className,
  title,
  action,
}: {
  children: ReactNode;
  className?: string;
  title?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className={"card" + (className ? " " + className : "")}>
      {(title || action) && (
        <div className="card-head">
          {title && <h3>{title}</h3>}
          {action}
        </div>
      )}
      {children}
    </div>
  );
}

export function Stat({
  label,
  value,
  sub,
  tone = "neutral",
}: {
  label: string;
  value: ReactNode;
  sub?: ReactNode;
  tone?: Tone;
}) {
  return (
    <div className={"stat tone-" + tone}>
      <span className="stat-label">{label}</span>
      <span className="stat-value">{value}</span>
      {sub && <span className="stat-sub">{sub}</span>}
    </div>
  );
}

export function Empty({
  icon,
  title,
  text,
  action,
}: {
  icon?: ReactNode;
  title: string;
  text?: string;
  action?: ReactNode;
}) {
  return (
    <div className="empty">
      {icon && <div className="empty-icon">{icon}</div>}
      <div className="empty-title">{title}</div>
      {text && <div className="empty-text">{text}</div>}
      {action}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Badges / pills
// ---------------------------------------------------------------------------

const toneIcon: Record<Tone, ReactNode> = {
  ok: <CheckCircle2 size={12} />,
  info: <Info size={12} />,
  warn: <AlertTriangle size={12} />,
  danger: <XCircle size={12} />,
  neutral: <Info size={12} />,
};

export function Pill({ tone, children }: { tone: Tone; children: ReactNode }) {
  return (
    <span className={"pill tone-" + tone}>
      {toneIcon[tone]}
      {children}
    </span>
  );
}

export function StatusPill({ status, tone }: { status: string; tone: Tone }) {
  return <Pill tone={tone}>{status}</Pill>;
}

const sourceTone: Record<string, Tone> = {
  manual: "neutral",
  automated: "info",
  "aws-backup": "ok",
};

export function SourceBadge({ source, label }: { source: string; label: string }) {
  return <Pill tone={sourceTone[source] ?? "neutral"}>{label}</Pill>;
}

export function EncryptedBadge({ encrypted }: { encrypted: boolean }) {
  return (
    <span className={"chip " + (encrypted ? "tone-ok" : "tone-warn")}>
      {encrypted ? <Lock size={11} /> : <Unlock size={11} />}
      {encrypted ? "Encrypted" : "Not encrypted"}
    </span>
  );
}

export function ProdBadge() {
  return (
    <span className="chip tone-danger">
      <ShieldCheck size={11} /> Production
    </span>
  );
}

export function ReadOnlyBadge({ compact }: { compact?: boolean }) {
  return (
    <span className="ro-badge" title="Write actions are disabled for this account">
      <Lock size={10} />
      {compact ? "RO" : "Read-only"}
    </span>
  );
}

/** Wraps a write-action control and disables it when the owning account is
 * read-only, with a tooltip explaining why — a `disabled` button alone
 * doesn't reliably show its `title` in every browser. */
export function WriteGuard({ disabled, children }: { disabled: boolean; children: ReactNode }) {
  if (!disabled) return <>{children}</>;
  return (
    <span className="write-guard" title="Account is read-only">
      {children}
    </span>
  );
}

// ---------------------------------------------------------------------------
// Account avatar
// ---------------------------------------------------------------------------

export function colorForName(name: string): string {
  let hash = 0;
  for (let i = 0; i < name.length; i++) hash = (hash * 31 + name.charCodeAt(i)) >>> 0;
  return accountPalette[hash % accountPalette.length];
}

export function AccountAvatar({
  name,
  color,
  size = "md",
}: {
  name: string;
  color?: string;
  size?: "sm" | "md" | "lg";
}) {
  return (
    <span
      className={"avatar avatar-" + size}
      style={{ background: color || colorForName(name) }}
      title={name}
    >
      {initials(name)}
    </span>
  );
}

// ---------------------------------------------------------------------------
// Modal
// ---------------------------------------------------------------------------

export function Modal({
  title,
  children,
  close,
  wide,
}: {
  title: string;
  children: ReactNode;
  close: () => void;
  wide?: boolean;
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [close]);

  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && close()}>
      <div className={"modal" + (wide ? " modal-wide" : "")} role="dialog" aria-modal="true">
        <div className="modal-head">
          <h2>{title}</h2>
          <button className="icon-btn" onClick={close} aria-label="Close">
            <X size={16} />
          </button>
        </div>
        <div className="modal-body">{children}</div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Toasts
// ---------------------------------------------------------------------------

export type ToastKind = "success" | "error" | "info";
export interface ToastItem {
  id: number;
  kind: ToastKind;
  message: string;
}

interface ToastApi {
  push: (kind: ToastKind, message: string) => void;
}

const ToastContext = createContext<ToastApi>({ push: () => {} });
export const useToast = () => useContext(ToastContext);

let toastSeq = 1;

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<ToastItem[]>([]);

  const dismiss = useCallback((id: number) => {
    setToasts((ts) => ts.filter((t) => t.id !== id));
  }, []);

  const push = useCallback(
    (kind: ToastKind, message: string) => {
      const id = toastSeq++;
      setToasts((ts) => [...ts, { id, kind, message }]);
      window.setTimeout(() => dismiss(id), 5000);
    },
    [dismiss],
  );

  return (
    <ToastContext.Provider value={{ push }}>
      {children}
      <div className="toast-host">
        {toasts.map((t) => (
          <div key={t.id} className={"toast toast-" + t.kind} onClick={() => dismiss(t.id)}>
            {t.kind === "success" && <CheckCircle2 size={15} />}
            {t.kind === "error" && <XCircle size={15} />}
            {t.kind === "info" && <Info size={15} />}
            <span>{t.message}</span>
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}

// ---------------------------------------------------------------------------
// Command palette
// ---------------------------------------------------------------------------

export interface PaletteEntry {
  id: string;
  group: string;
  label: string;
  sublabel?: string;
  onSelect: () => void;
}

export function CommandPalette({
  open,
  onClose,
  entries,
}: {
  open: boolean;
  onClose: () => void;
  entries: PaletteEntry[];
}) {
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (open) {
      setQuery("");
      setIndex(0);
      requestAnimationFrame(() => inputRef.current?.focus());
    }
  }, [open]);

  const filtered = entries.filter((e) => {
    const q = query.trim().toLowerCase();
    if (!q) return true;
    return (e.label + " " + (e.sublabel ?? "")).toLowerCase().includes(q);
  });

  if (!open) return null;

  const choose = (e: PaletteEntry) => {
    e.onSelect();
    onClose();
  };

  return (
    <div className="overlay palette-overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="palette" role="dialog" aria-modal="true">
        <input
          ref={inputRef}
          className="palette-input"
          placeholder="Jump to an account or database…"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            setIndex(0);
          }}
          onKeyDown={(e) => {
            if (e.key === "Escape") onClose();
            else if (e.key === "ArrowDown") {
              e.preventDefault();
              setIndex((i) => Math.min(i + 1, filtered.length - 1));
            } else if (e.key === "ArrowUp") {
              e.preventDefault();
              setIndex((i) => Math.max(i - 1, 0));
            } else if (e.key === "Enter" && filtered[index]) {
              e.preventDefault();
              choose(filtered[index]);
            }
          }}
        />
        <div className="palette-list">
          {filtered.length === 0 && <div className="palette-empty">No matches</div>}
          {filtered.map((e, i) => (
            <button
              key={e.id}
              className={"palette-item" + (i === index ? " active" : "")}
              onMouseEnter={() => setIndex(i)}
              onClick={() => choose(e)}
            >
              <span className="palette-group">{e.group}</span>
              <span className="palette-label">{e.label}</span>
              {e.sublabel && <span className="palette-sub">{e.sublabel}</span>}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Simple table shell
// ---------------------------------------------------------------------------

export function Table({ children }: { children: ReactNode }) {
  return (
    <div className="table-wrap">
      <table className="table">{children}</table>
    </div>
  );
}
