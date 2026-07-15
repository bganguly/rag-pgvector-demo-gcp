"use client";

import { useChat } from "ai/react";
import { useEffect, useRef, useState } from "react";
import type { Provider } from "@/app/page";

interface Chunk {
  content: string;
  source: string;
  score: number;
}

const SUGGESTED = [
  "How does the Fed control inflation?",
  "What is quantitative easing?",
  "How does rising interest rates affect the economy?",
  "What components make up GDP?",
  "How is the Consumer Price Index calculated?",
];

export default function ChatPanel({ provider, ingested }: { provider: Provider; ingested: boolean }) {
  const { messages, input, handleInputChange, isLoading, setMessages, setInput, append } =
    useChat({ api: "/api/chat", body: { provider } });

  const [ctxByExchange, setCtxByExchange] = useState<Chunk[][]>([]);
  const [expanded, setExpanded]           = useState<Set<number>>(new Set());
  const [showSuggestions, setShowSuggestions] = useState(true);
  const bottomRef                         = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  async function submitQuery(query: string) {
    const q = query.trim();
    if (!q || isLoading) return;

    const exchangeIdx = messages.filter((m) => m.role === "user").length;

    try {
      const res = await fetch("/api/retrieve", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query: q, k: 5 }),
      });
      if (res.ok) {
        const { chunks } = await res.json();
        setCtxByExchange((prev) => {
          const next = [...prev];
          next[exchangeIdx] = chunks ?? [];
          return next;
        });
      }
    } catch { /* silent — chat still works */ }

    setInput("");
    await append({ role: "user", content: q });
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    await submitQuery(input);
  }

  function toggleCtx(idx: number) {
    setExpanded((prev) => {
      const next = new Set(prev);
      next.has(idx) ? next.delete(idx) : next.add(idx);
      return next;
    });
  }

  return (
    <div className="flex flex-col h-full">
      <div
        className="flex items-center justify-between px-4 py-2 border-b"
        style={{ borderColor: "var(--border)" }}
      >
        <span className="text-xs font-mono uppercase tracking-wider" style={{ color: "var(--text-2)" }}>
          Query
        </span>
        <button
          onClick={() => { setMessages([]); setCtxByExchange([]); setExpanded(new Set()); setShowSuggestions(true); }}
          className="text-xs px-2 py-1 rounded"
          style={{ color: "var(--text-2)", border: "1px solid var(--border)" }}
        >
          Clear
        </button>
      </div>

      <div className="flex-1 overflow-y-auto px-4 py-4 flex flex-col gap-3">
        {messages.length === 0 && (
          <div className="flex flex-col gap-2 mt-6 items-center text-center">
            {ingested ? (
              <p className="text-sm" style={{ color: "var(--text-2)" }}>
                Knowledge base ready — pick a question below or type your own.
              </p>
            ) : (
              <>
                <p className="text-sm" style={{ color: "var(--text-2)" }}>
                  Select topics and click <span style={{ color: "var(--accent)" }}>Load Selected</span> on the left,
                  then ask a question.
                </p>
                <p className="text-xs mt-1" style={{ color: "var(--text-2)", opacity: 0.55 }}>
                  Or try a question now — answers will be from the model&apos;s general knowledge.
                </p>
              </>
            )}
          </div>
        )}

        {messages.map((m, i) => {
          const usersBefore  = messages.slice(0, i).filter((x) => x.role === "user").length;
          const exchangeIdx  = m.role === "user" ? usersBefore : usersBefore - 1;
          const chunks       = ctxByExchange[exchangeIdx];

          return (
            <div key={m.id} className="flex flex-col gap-1.5">
              <div className={`flex ${m.role === "user" ? "justify-end" : "justify-start"}`}>
                <div
                  className="max-w-[80%] rounded-lg px-4 py-2.5 text-sm leading-relaxed"
                  style={
                    m.role === "user"
                      ? { background: "var(--accent)", color: "#fff" }
                      : { background: "var(--surface)", border: "1px solid var(--border)", color: "var(--text)" }
                  }
                >
                  <p className="whitespace-pre-wrap">{m.content}</p>
                </div>
              </div>

              {m.role === "user" && chunks && chunks.length > 0 && (
                <div className="flex justify-end">
                  <div className="max-w-[80%] w-full">
                    <button
                      onClick={() => toggleCtx(exchangeIdx)}
                      className="text-xs flex items-center gap-1.5 mb-1 ml-auto"
                      style={{ color: "var(--text-2)" }}
                    >
                      <span style={{ color: "var(--accent)" }}>⊙</span>
                      Retrieved {chunks.length} chunks
                      <span style={{ opacity: 0.5 }}>{expanded.has(exchangeIdx) ? "▲" : "▼"}</span>
                    </button>
                    {expanded.has(exchangeIdx) && (
                      <div
                        className="rounded text-xs flex flex-col divide-y p-0 overflow-hidden"
                        style={{ border: "1px solid var(--border)", "--tw-divide-color": "var(--border)" } as React.CSSProperties}
                      >
                        {chunks.map((c, ci) => (
                          <div key={ci} className="flex flex-col gap-1 p-2.5" style={{ background: "var(--bg)" }}>
                            <div className="flex items-center justify-between">
                              <span className="font-mono" style={{ color: "var(--accent)" }}>
                                [{ci + 1}] {c.source}
                              </span>
                              <span style={{ color: "var(--text-2)" }}>score {c.score}</span>
                            </div>
                            <p className="leading-relaxed" style={{ color: "var(--text-2)" }}>
                              {c.content.length > 220 ? c.content.slice(0, 220) + "…" : c.content}
                            </p>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                </div>
              )}
            </div>
          );
        })}

        {isLoading && (
          <div className="flex justify-start">
            <div
              className="rounded-lg px-4 py-2.5 text-sm"
              style={{ background: "var(--surface)", border: "1px solid var(--border)", color: "var(--text-2)" }}
            >
              <span className="animate-pulse">Generating…</span>
            </div>
          </div>
        )}

        <div ref={bottomRef} />
      </div>

      {/* Persistent suggestions strip */}
      <div className="border-t" style={{ borderColor: "var(--border)" }}>
        <button
          onClick={() => setShowSuggestions((v) => !v)}
          className="flex items-center justify-between w-full px-4 py-2"
        >
          <span className="text-[10px] font-mono uppercase tracking-wider" style={{ color: "var(--text-2)" }}>
            Sample questions
          </span>
          <span className="text-[10px] font-mono" style={{ color: "var(--text-2)" }}>
            {showSuggestions ? "▲" : "▼"}
          </span>
        </button>
        {showSuggestions && (
          <div className="px-4 pb-3 flex flex-wrap gap-1.5">
            {SUGGESTED.map((q) => (
              <button
                key={q}
                onClick={() => submitQuery(q)}
                disabled={isLoading}
                className="px-2.5 py-1 rounded text-xs text-left transition-opacity"
                style={{
                  background: "var(--surface)",
                  border: "1px solid var(--border)",
                  color: "var(--text-2)",
                  opacity: isLoading ? 0.4 : 1,
                }}
              >
                {q}
              </button>
            ))}
          </div>
        )}
      </div>

      <form
        onSubmit={onSubmit}
        className="flex gap-2 px-4 py-3 border-t"
        style={{ borderColor: "var(--border)" }}
      >
        <input
          value={input}
          onChange={handleInputChange}
          placeholder="Ask about the knowledge base…"
          className="flex-1 rounded px-3 py-2 text-sm"
          style={{ background: "var(--bg)", border: "1px solid var(--border)", color: "var(--text)" }}
        />
        <button
          type="submit"
          disabled={isLoading || !input.trim()}
          className="px-4 py-2 rounded text-sm font-medium transition-opacity"
          style={{ background: "var(--accent)", color: "#fff", opacity: isLoading || !input.trim() ? 0.5 : 1 }}
        >
          Ask
        </button>
      </form>
    </div>
  );
}
