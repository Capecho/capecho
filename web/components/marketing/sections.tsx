import { cn } from "@/lib/utils";

/** Editorial chapter rail — a mono ordinal + hairline (web/DESIGN.md §5). */
export function ChapterRail({ children }: { children: React.ReactNode }) {
  return (
    <div className="mb-7 flex items-center gap-4 font-mono text-[12.5px] font-medium uppercase tracking-[0.16em] text-ink-2">
      <span>{children}</span>
      <span className="h-px flex-1 bg-border" />
    </div>
  );
}

/** Two-column ledger wrapper. */
export function Ledger({ children }: { children: React.ReactNode }) {
  return <div className="mt-7 grid gap-[18px] md:grid-cols-2">{children}</div>;
}

/** A ledger column: mono label + bulleted serif lines + optional note. */
export function LedgerCol({
  label,
  accent = false,
  items,
  note,
}: {
  label: string;
  accent?: boolean;
  items: React.ReactNode[];
  note?: React.ReactNode;
}) {
  return (
    <div className="rounded-xl border border-border p-6">
      <div
        className={cn(
          "mb-3.5 font-mono text-[11px] uppercase tracking-[0.1em]",
          accent ? "text-primary" : "text-ink-2"
        )}
      >
        {label}
      </div>
      <ul className="space-y-1">
        {items.map((it, i) => (
          <li
            key={i}
            className="relative py-2 pl-[18px] font-serif text-[14.5px] leading-snug text-foreground"
          >
            <span className="absolute left-[3px] font-bold text-primary">·</span>
            {it}
          </li>
        ))}
      </ul>
      {note && (
        <p className="mt-3 font-serif text-[13px] italic leading-snug text-ink-2">
          {note}
        </p>
      )}
    </div>
  );
}
