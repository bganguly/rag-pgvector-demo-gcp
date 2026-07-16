"use client";

import { useEffect, useState } from "react";

const TOPICS = [
  { id: "fed",      label: "Federal Reserve",          slug: "Federal_Reserve" },
  { id: "inflation",label: "Inflation",                slug: "Inflation" },
  { id: "rate",     label: "Interest Rate",            slug: "Interest_rate" },
  { id: "qe",       label: "Quantitative Easing",      slug: "Quantitative_easing" },
  { id: "policy",   label: "Monetary Policy",          slug: "Monetary_policy" },
  { id: "gdp",      label: "Gross Domestic Product",   slug: "Gross_domestic_product" },
  { id: "cpi",      label: "Consumer Price Index",     slug: "Consumer_price_index" },
  { id: "treasury", label: "US Treasury Securities",   slug: "United_States_Treasury_security" },
];

type Status = "idle" | "fetching" | "ingesting" | "done" | "error";
type TState = {
  status: Status;
  chunks?:     number;
  estChunks?:  number;
  startedAt?:  number;
  errorMsg?:   string;
};

const STATUS_ICON: Record<Status, string>            = { idle: "", fetching: "↓", ingesting: "⊙", done: "✓", error: "✗" };
const STATUS_LABEL: Partial<Record<Status, string>>  = { fetching: "Fetching…", ingesting: "Embedding…" };
const STATUS_COLOR: Record<Status, string>           = {
  idle:      "var(--text-2)",
  fetching:  "var(--accent)",
  ingesting: "var(--accent)",
  done:      "#22c55e",
  error:     "#ef4444",
};

function blank(): Record<string, TState> {
  return Object.fromEntries(TOPICS.map((t) => [t.id, { status: "idle" as Status }]));
}

function estimateChunks(textLen: number): number {
  if (textLen <= 800) return 1;
  return Math.ceil((textLen - 800) / 650) + 1;
}

async function fetchWikiText(slug: string): Promise<string> {
  const r = await fetch(
    `https://en.wikipedia.org/w/api.php?action=query&titles=${slug}&prop=extracts&explaintext=true&format=json&origin=*`
  );
  const d    = await r.json();
  const pages = d?.query?.pages ?? {};
  const page  = Object.values(pages)[0] as Record<string, unknown>;
  return (page?.extract as string) ?? "";
}

export default function SeedPanel({ onReady }: { onReady?: () => void }) {
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [states, setStates]   = useState<Record<string, TState>>(blank);
  const [running, setRunning] = useState(false);
  const [total, setTotal]     = useState(0);
  const [tick, setTick]       = useState(0);

  useEffect(() => {
    if (!running) return;
    const id = setInterval(() => setTick((n) => n + 1), 1000);
    return () => clearInterval(id);
  }, [running]);

  const set = (id: string, u: Partial<TState>) =>
    setStates((p) => ({ ...p, [id]: { ...p[id], ...u } }));

  function toggleTopic(id: string) {
    if (running) return;
    setSelected((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  }

  function selectAll() { setSelected(new Set(TOPICS.map((t) => t.id))); }
  function clearAll()  { setSelected(new Set()); }

  async function load(clearFirst = false) {
    const batch = TOPICS.filter((t) => selected.has(t.id));
    if (!batch.length) return;

    setRunning(true);
    setTotal(0);
    setStates(blank());

    if (clearFirst) {
      await fetch("/api/reset", { method: "DELETE" }).catch(() => null);
    }

    let acc = 0;

    for (let i = 0; i < batch.length; i++) {
      const t = batch[i];
      if (i > 0) await new Promise((r) => setTimeout(r, 800));

      set(t.id, { status: "fetching" });
      try {
        const text = await fetchWikiText(t.slug);
        if (!text) throw new Error("empty");

        const estChunks = estimateChunks(text.length);
        set(t.id, { status: "ingesting", estChunks, startedAt: Date.now() });

        const fd = new FormData();
        fd.append("text", text);
        fd.append("source", `wikipedia/${t.slug}`);

        const res  = await fetch("/api/ingest", { method: "POST", body: fd });
        const data = await res.json();
        if (!res.ok) throw new Error(data.detail ?? data.Message ?? `HTTP ${res.status}`);

        acc += data.chunks ?? 0;
        setTotal(acc);
        set(t.id, { status: "done", chunks: data.chunks });
      } catch (e) {
        set(t.id, { status: "error", errorMsg: e instanceof Error ? e.message : "failed" });
      }
    }

    setRunning(false);
    onReady?.();
  }

  function toLoad() { return TOPICS.filter((t) => selected.has(t.id)); }
  const doneCount     = toLoad().filter((t) => states[t.id].status === "done").length;
  const allDone       = toLoad().length > 0 && doneCount === toLoad().length;
  const selectedCount = selected.size;

  return (
    <div className="flex flex-col gap-3 p-5">
      <div className="flex items-start justify-between">
        <div>
          <span className="text-xs font-mono uppercase tracking-widest" style={{ color: "var(--text-2)" }}>
            Knowledge Base
          </span>
          <p className="text-xs mt-0.5" style={{ color: "var(--text-2)" }}>
            Unstructured source · Wikipedia / Economics
          </p>
        </div>
        {!running && (
          <div className="flex gap-2 mt-0.5">
            <button onClick={selectAll} className="text-[10px] underline" style={{ color: "var(--text-2)" }}>All</button>
            <button onClick={clearAll}  className="text-[10px] underline" style={{ color: "var(--text-2)" }}>None</button>
          </div>
        )}
      </div>


      <div className="flex flex-wrap gap-1.5">
        {TOPICS.map((t) => {
          const s        = states[t.id];
          const isSel    = selected.has(t.id);
          const isActive = s.status === "fetching" || s.status === "ingesting";
          const isDone   = s.status === "done";
          const isError  = s.status === "error";

          const elapsed = s.status === "ingesting" && s.startedAt
            ? Math.floor((Date.now() - s.startedAt) / 1000)
            : 0;
          void tick;

          const bg     = isDone  ? "rgba(34,197,94,0.12)"
                       : isError ? "rgba(239,68,68,0.10)"
                       : isSel   ? "rgba(var(--accent-rgb), 0.15)"
                       : "transparent";
          const border  = isDone  ? "#22c55e55"
                        : isError ? "#ef444455"
                        : isSel   ? "var(--accent)"
                        : "var(--border)";
          const color   = isDone  ? "#22c55e"
                        : isError ? "#ef4444"
                        : isSel   ? "var(--accent)"
                        : "var(--text-2)";

          return (
            <button
              key={t.id}
              onClick={() => toggleTopic(t.id)}
              disabled={running}
              className="flex items-center gap-1.5 px-2.5 py-1 rounded text-xs transition-all"
              style={{
                background: bg,
                border: `1px solid ${border}`,
                color,
                opacity: running && !isSel ? 0.35 : 1,
                cursor:  running ? "default" : "pointer",
              }}
            >
              {(isActive || isDone || isError) && (
                <span
                  className={isActive ? "animate-pulse font-mono" : "font-mono"}
                  style={{ color: STATUS_COLOR[s.status] }}
                >
                  {STATUS_ICON[s.status]}
                </span>
              )}
              {t.label}
              {isDone && s.chunks != null && (
                <span style={{ opacity: 0.6, fontSize: "0.65rem" }}>{s.chunks}c</span>
              )}
              {s.status === "fetching" && (
                <span style={{ opacity: 0.7, fontSize: "0.65rem" }}>{STATUS_LABEL.fetching}</span>
              )}
              {s.status === "ingesting" && (
                <span style={{ opacity: 0.7, fontSize: "0.65rem" }}>
                  ~{s.estChunks}c · {elapsed}s
                </span>
              )}
            </button>
          );
        })}
      </div>

      {running && (
        <div className="text-xs text-center" style={{ color: "var(--text-2)" }}>
          {doneCount} / {toLoad().length} topics · {total} chunks indexed
        </div>
      )}

      {toLoad().some((t) => states[t.id].status === "error") && (
        <div className="text-xs rounded px-3 py-2" style={{ color: "#ef4444", background: "rgba(239,68,68,0.08)", border: "1px solid #ef444433" }}>
          {toLoad()
            .filter((t) => states[t.id].status === "error")
            .map((t) => (
              <div key={t.id}><strong>{t.label}:</strong> {states[t.id].errorMsg ?? "failed"}</div>
            ))}
        </div>
      )}

      {allDone ? (
        <>
          <div
            className="text-center text-xs py-2 rounded"
            style={{ color: "#22c55e", border: "1px solid #22c55e33" }}
          >
            ✓ Ready — ask a question in the chat
          </div>
          <div className="flex gap-3 justify-center">
            <button onClick={() => load(true)}  className="text-xs underline" style={{ color: "#ef4444" }}>
              Clear &amp; Re-index
            </button>
            <button onClick={() => load(false)} className="text-xs underline" style={{ color: "var(--text-2)" }}>
              Append
            </button>
          </div>
        </>
      ) : (
        <button
          onClick={() => load(false)}
          disabled={running || selectedCount === 0}
          className="rounded py-2 text-sm font-medium transition-opacity"
          style={{
            background: "var(--accent)",
            color:      "#fff",
            opacity:    running || selectedCount === 0 ? 0.5 : 1,
          }}
        >
          {running
            ? `Loading ${doneCount} / ${toLoad().length}…`
            : selectedCount === 0
            ? "Pick one or two topics above to get started"
            : `Load Selected (${selectedCount})`}
        </button>
      )}
    </div>
  );
}
