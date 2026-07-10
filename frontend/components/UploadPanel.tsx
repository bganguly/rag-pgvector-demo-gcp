"use client";

import { useRef, useState } from "react";

export default function UploadPanel() {
  const [source, setSource] = useState("");
  const [text, setText] = useState("");
  const [status, setStatus] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  async function handleIngest(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setStatus(null);

    const fd = new FormData();
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
      const res = await fetch("/api/ingest", { method: "POST", body: fd });
      const data = await res.json();
      if (res.ok) {
        setStatus(`✓ Ingested ${data.chunks} chunks from "${data.source}"`);
        setText("");
        if (fileRef.current) fileRef.current.value = "";
      } else {
        setStatus(`Error: ${data.detail ?? "ingestion failed"}`);
      }
    } catch {
      setStatus("Network error");
    } finally {
      setLoading(false);
    }
  }

  return (
    <form onSubmit={handleIngest} className="flex flex-col gap-4 p-5">
      <div>
        <span
          className="text-xs font-mono uppercase tracking-widest"
          style={{ color: "var(--text-2)" }}
        >
          Ingest Documents
        </span>
      </div>

      <div className="flex flex-col gap-1">
        <label className="text-xs" style={{ color: "var(--text-2)" }}>
          File (.txt, .md)
        </label>
        <input
          ref={fileRef}
          type="file"
          accept=".txt,.md,.csv"
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
          rows={6}
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
        disabled={loading}
        className="rounded py-2 text-sm font-medium transition-opacity"
        style={{
          background: "var(--accent)",
          color: "#fff",
          opacity: loading ? 0.6 : 1,
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
  );
}
