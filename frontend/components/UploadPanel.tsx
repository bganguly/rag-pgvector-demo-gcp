"use client";

import { useRef, useState } from "react";

export default function UploadPanel({ onIngest }: { onIngest?: () => void }) {
  const [source, setSource] = useState("");
  const [text, setText]     = useState("");
  const [status, setStatus] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [open, setOpen]     = useState(false);
  const fileRef             = useRef<HTMLInputElement>(null);

  const hasContent = !!(fileRef.current?.files?.[0] || text.trim());
  const [fileSelected, setFileSelected] = useState(false);

  async function handleIngest(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setStatus(null);

    const fd   = new FormData();
    const file = fileRef.current?.files?.[0];
    if (file) {
      fd.append("file", file);
    } else if (text.trim()) {
      fd.append("text", text.trim());
    } else {
      setStatus("Provide a file or paste text.");
      setLoading(false);
      return;
    }
    fd.append("source", source || file?.name || "manual");

    try {
      const res  = await fetch("/api/ingest", { method: "POST", body: fd });
      const data = await res.json();
      if (res.ok) {
        setStatus(`✓ Ingested ${data.chunks} chunks from "${data.source}"`);
        setText("");
        setFileSelected(false);
        if (fileRef.current) fileRef.current.value = "";
        onIngest?.();
      } else {
        setStatus(`Error: ${data.detail ?? "ingestion failed"}`);
      }
    } catch {
      setStatus("Network error");
    } finally {
      setLoading(false);
    }
  }

  const canSubmit = fileSelected || !!text.trim();

  return (
    <div className="p-5">
      <button
        onClick={() => setOpen((v) => !v)}
        className="flex items-center justify-between w-full"
      >
        <div>
          <span className="text-xs font-mono uppercase tracking-widest" style={{ color: "var(--text-2)" }}>
            Custom Documents
          </span>
          <p className="text-xs mt-0.5 text-left" style={{ color: "var(--text-2)", opacity: 0.6 }}>
            optional — add your own text or files
          </p>
        </div>
        <span className="text-xs font-mono" style={{ color: "var(--text-2)" }}>
          {open ? "▲" : "▼"}
        </span>
      </button>

      {open && (
        <form onSubmit={handleIngest} className="flex flex-col gap-4 mt-4">
          <p className="text-xs leading-relaxed" style={{ color: "var(--text-2)", opacity: 0.75 }}>
            Supplement the Wikipedia knowledge base with your own documents — paste text or upload a file.
          </p>

          <div className="flex flex-col gap-1">
            <label className="text-xs" style={{ color: "var(--text-2)" }}>
              File (.txt, .md, .csv)
            </label>
            <input
              ref={fileRef}
              type="file"
              accept=".txt,.md,.csv"
              onChange={(e) => setFileSelected(!!e.target.files?.[0])}
              className="text-sm"
              style={{ color: "var(--text)" }}
            />
          </div>

          <div className="flex flex-col gap-1">
            <label className="text-xs" style={{ color: "var(--text-2)" }}>
              Or paste text
            </label>
            <textarea
              value={text}
              onChange={(e) => setText(e.target.value)}
              rows={5}
              placeholder="Paste document content here..."
              className="rounded p-2 text-sm resize-none"
              style={{
                background: "var(--bg)",
                border: "1px solid var(--border)",
                color: "var(--text)",
              }}
            />
          </div>

          <div className="flex flex-col gap-1">
            <label className="text-xs" style={{ color: "var(--text-2)" }}>
              Source label
            </label>
            <input
              type="text"
              value={source}
              onChange={(e) => setSource(e.target.value)}
              placeholder="e.g. fed-minutes-2024"
              className="rounded p-2 text-sm"
              style={{
                background: "var(--bg)",
                border: "1px solid var(--border)",
                color: "var(--text)",
              }}
            />
          </div>

          <button
            type="submit"
            disabled={loading || !canSubmit}
            className="rounded py-2 text-sm font-medium transition-opacity"
            style={{
              background: "var(--accent)",
              color: "#fff",
              opacity: loading || !canSubmit ? 0.4 : 1,
            }}
          >
            {loading ? "Ingesting…" : "Ingest"}
          </button>

          {status && (
            <p className="text-xs" style={{ color: "var(--text-2)" }}>
              {status}
            </p>
          )}
        </form>
      )}
    </div>
  );
}
