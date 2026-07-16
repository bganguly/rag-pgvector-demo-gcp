import { streamText } from "ai";
import { anthropic } from "@ai-sdk/anthropic";
import { createOpenAI } from "@ai-sdk/openai";

const nim = createOpenAI({
  baseURL: "https://integrate.api.nvidia.com/v1",
  apiKey: process.env.NVIDIA_API_KEY ?? "",
});

const openai = createOpenAI({
  apiKey: process.env.OPENAI_API_KEY ?? "",
});

function pickModel(provider: string) {
  switch (provider) {
    case "nim":
      return nim("nvidia/llama-3.3-nemotron-super-49b-v1");
    case "openai":
      return openai("gpt-4o-mini");
    default:
      return anthropic("claude-haiku-4-5");
  }
}

export async function POST(req: Request) {
  const { messages, provider = "anthropic" } = await req.json();
  const query = messages.at(-1)?.content ?? "";

  const backendUrl = process.env.BACKEND_URL ?? "http://localhost:8001";

  let chunks: Array<{ content: string; source: string }> = [];
  let backendError = false;
  try {
    const retrieveRes = await fetch(`${backendUrl}/api/retrieve`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query, k: 5 }),
      signal: AbortSignal.timeout(8000),
    });
    if (retrieveRes.ok) {
      const data = await retrieveRes.json();
      chunks = data.chunks ?? [];
    } else {
      backendError = true;
    }
  } catch {
    backendError = true;
  }

  const context = backendError
    ? "The knowledge base is currently unavailable. Answer from general knowledge and note that the knowledge base could not be reached."
    : chunks.length > 0
    ? chunks
        .map((c, i) => `[${i + 1}] (source: ${c.source})\n${c.content}`)
        .join("\n\n")
    : "No relevant documents found in the knowledge base.";

  const result = streamText({
    model: pickModel(provider),
    system: `You are a helpful assistant. Answer using only the context below.
If the context doesn't contain the answer, say so.
Cite source numbers like [1] when you use them.

Context:
${context}`,
    messages,
  });

  return result.toDataStreamResponse();
}
