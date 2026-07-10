"use client";

import { useState } from "react";
import ChatPanel from "@/components/ChatPanel";
import UploadPanel from "@/components/UploadPanel";

export type Provider = "anthropic" | "openai" | "nim";

export default function Home() {
  const [provider, setProvider] = useState<Provider>("anthropic");

  return (
    <div className="flex flex-col h-screen">
      <header
        className="flex items-center justify-between px-6 py-3 border-b"
        style={{ background: "var(--surface)", borderColor: "var(--border)" }}
      >
        <div>
          <span
            className="text-xs font-mono tracking-widest uppercase"
            style={{ color: "var(--accent)" }}
          >
            RAG Demo
          </span>
          <h1 className="text-base font-semibold" style={{ color: "var(--text)" }}>
            pgvector · LangChain · Vercel AI SDK
          </h1>
        </div>

        <div className="flex items-center gap-2">
          <span className="text-xs font-mono uppercase tracking-wider" style={{ color: "var(--text-2)" }}>
            Provider
          </span>
          {(["anthropic", "openai", "nim"] as Provider[]).map((p) => (
            <button
              key={p}
              onClick={() => setProvider(p)}
              className="px-3 py-1 rounded text-xs font-mono transition-colors"
              style={{
                background: provider === p ? "var(--accent)" : "var(--bg)",
                color: provider === p ? "#fff" : "var(--text-2)",
                border: `1px solid ${provider === p ? "var(--accent)" : "var(--border)"}`,
              }}
            >
              {p === "nim" ? "NVIDIA NIM" : p === "anthropic" ? "Anthropic" : "OpenAI"}
            </button>
          ))}
        </div>
      </header>

      <div className="flex flex-1 overflow-hidden">
        <div
          className="w-80 shrink-0 border-r overflow-y-auto"
          style={{ background: "var(--surface)", borderColor: "var(--border)" }}
        >
          <UploadPanel />
        </div>
        <div className="flex-1 overflow-hidden">
          <ChatPanel provider={provider} />
        </div>
      </div>
    </div>
  );
}
