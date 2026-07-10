"use client";

import { useChat } from "ai/react";
import { useEffect, useRef } from "react";
import type { Provider } from "@/app/page";

export default function ChatPanel({ provider }: { provider: Provider }) {
  const { messages, input, handleInputChange, handleSubmit, isLoading, setMessages } =
    useChat({
      api: "/api/chat",
      body: { provider },
    });

  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-center justify-between px-4 py-2 border-b" style={{ borderColor: "var(--border)" }}>
        <span className="text-xs font-mono uppercase tracking-wider" style={{ color: "var(--text-2)" }}>
          Chat
        </span>
        <button
          onClick={() => setMessages([])}
          className="text-xs px-2 py-1 rounded"
          style={{ color: "var(--text-2)", border: "1px solid var(--border)" }}
        >
          Clear
        </button>
      </div>

      <div className="flex-1 overflow-y-auto px-4 py-4 flex flex-col gap-4">
        {messages.length === 0 && (
          <p className="text-sm text-center mt-8" style={{ color: "var(--text-2)" }}>
            Ingest documents on the left, then ask questions here.
          </p>
        )}

        {messages.map((m) => (
          <div
            key={m.id}
            className={`flex ${m.role === "user" ? "justify-end" : "justify-start"}`}
          >
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
        ))}

        {isLoading && (
          <div className="flex justify-start">
            <div
              className="rounded-lg px-4 py-2.5 text-sm"
              style={{ background: "var(--surface)", border: "1px solid var(--border)", color: "var(--text-2)" }}
            >
              <span className="animate-pulse">Retrieving + generating…</span>
            </div>
          </div>
        )}

        <div ref={bottomRef} />
      </div>

      <form
        onSubmit={handleSubmit}
        className="flex gap-2 px-4 py-3 border-t"
        style={{ borderColor: "var(--border)" }}
      >
        <input
          value={input}
          onChange={handleInputChange}
          placeholder="Ask a question about your documents…"
          className="flex-1 rounded px-3 py-2 text-sm"
          style={{
            background: "var(--bg)",
            border: "1px solid var(--border)",
            color: "var(--text)",
          }}
        />
        <button
          type="submit"
          disabled={isLoading || !input.trim()}
          className="px-4 py-2 rounded text-sm font-medium transition-opacity"
          style={{
            background: "var(--accent)",
            color: "#fff",
            opacity: isLoading || !input.trim() ? 0.5 : 1,
          }}
        >
          Send
        </button>
      </form>
    </div>
  );
}
