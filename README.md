# RAG + pgvector Demo — LangChain · Vercel AI SDK · NVIDIA NIM

End-to-end **Retrieval-Augmented Generation pipeline** over any unstructured corpus: LangChain chunking,
OpenAI embeddings stored in **pgvector**, cosine-similarity retrieval, and token-level SSE streaming via
**Vercel AI SDK**. Provider toggle switches between Anthropic, OpenAI, and **NVIDIA NIM (Nemotron)** at
runtime — same interface, configurable `base_url`.

**[Live demo →](https://bganguly.github.io/?open=rag)**

---

## Using the App

Load full Wikipedia articles by topic label, then ask questions against what you've loaded. Once one or more topics are loaded, run the prebaked sample queries or write your own. When there isn't enough context loaded — or none at all — the selected LLM will respond based on what it already knows, and will say so at the top of its reply.

1. **Select topics** — toggle the topic chips in the left panel to choose which Wikipedia articles to load.
2. **Click Load Selected** — fetches and indexes the selected articles; per-topic progress is shown as each one completes.
3. **Ask a question** — pick from the **Sample questions** strip above the input, or type your own and press **Ask**.
4. **Switch provider** — use the Anthropic / OpenAI / NVIDIA NIM toggle in the header at any time.
5. **Clear & Re-index** — appears after a successful load; wipes all loaded content and re-fetches the selected topics fresh.
6. **Custom documents** *(optional)* — paste text or upload a `.txt` / `.md` file to add your own content alongside the Wikipedia articles.

---

## Running

```bash
./scripts/deploy.sh      # local [1], AWS Lambda + Neon + Vercel [2], or GCP Cloud Run [3]
./scripts/infra-down.sh  # tear down local [1] or AWS [--aws] or GCP [--cloud]
```

---

| Component | Implementation |
|---|---|
| **RAG pipeline** | LangChain `RecursiveCharacterTextSplitter` (800 chars / 150 overlap) → OpenAI `text-embedding-3-small` (1 536 dims) → pgvector cosine similarity |
| **Vector store** | PostgreSQL 16 + pgvector extension; `langchain-postgres` `PGVector` handles schema, IVFFlat index, and async upsert |
| **LLM streaming** | Next.js App Router API route calls FastAPI `/api/retrieve`, injects chunks as context, then streams via Vercel AI SDK `streamText`; tokens arrive at the browser via the AI SDK data-stream protocol |
| **Provider toggle** | Anthropic `claude-haiku-4-5` (default) · OpenAI `gpt-4o-mini` · NVIDIA NIM `nvidia/llama-3.3-nemotron-super-49b-v1` — switched from the header without reloading |
| **Ingest API** | `POST /api/ingest` accepts `.txt` / `.md` file upload or raw pasted text; chunked and embedded in one call |
| **Backend** | FastAPI 0.115 + asyncio; `lifespan` hook initialises pgvector extension and LangChain collection on startup; served via **Mangum** on AWS Lambda |
| **Frontend** | Next.js 15 App Router, React 19, TypeScript 5.7, Tailwind CSS; `useChat` from `ai/react`; deployed on **Vercel** |
| **IaC** | Terraform (`infra/aws/`) — Lambda, ECR, CodeBuild, S3, IAM, CloudWatch |

---

## Architecture

### Ingest flow

```mermaid
sequenceDiagram
    participant B as Browser
    participant V as Vercel (Next.js)
    participant L as Lambda (FastAPI)
    participant LC as LangChain
    participant PG as pgvector (Neon)

    B->>V: POST /api/ingest (file or pasted text)
    V->>L: POST /api/ingest (proxy)
    L->>LC: raw text string
    Note over LC: RecursiveCharacterTextSplitter<br/>800 chars · 150 overlap
    LC->>LC: OpenAIEmbeddings<br/>text-embedding-3-small → 1536-dim vectors
    LC->>PG: PGVector.aadd_documents()<br/>upsert chunks + embeddings
    PG-->>B: { chunks: N } ✓
```

### Chat / query flow

```mermaid
sequenceDiagram
    participant B as Browser
    participant V as Vercel (Next.js)
    participant L as Lambda (FastAPI)
    participant LC as LangChain
    participant PG as pgvector (Neon)
    participant AI as Vercel AI SDK
    participant LLM as LLM Provider

    B->>V: POST /api/chat { query, provider }
    V->>L: POST /api/retrieve { query, k:5 }
    L->>LC: query string
    LC->>PG: embed query → cosine similarity search
    PG-->>V: top-5 chunks + relevance scores
    Note over V: inject chunks into system prompt
    V->>AI: streamText(model, context + query)
    AI->>LLM: grounded request<br/>(claude-haiku-4-5 / gpt-4o-mini / nemotron)
    LLM-->>B: token stream via SSE data-stream protocol
```

### What LangChain replaces

<table>
<colgroup>
  <col style="width:20%">
  <col style="width:20%">
  <col style="width:60%">
</colgroup>
<thead>
<tr><th>Component</th><th>Without LangChain</th><th>Why it matters</th></tr>
</thead>
<tbody>
<tr>
  <td><code>RecursiveCharacterTextSplitter</code></td>
  <td>Manual regex split + overlap bookkeeping</td>
  <td>Overlap prevents semantic units being cut at chunk boundaries — retrieval precision drops without it</td>
</tr>
<tr>
  <td><code>OpenAIEmbeddings</code></td>
  <td>Raw <code>openai.embeddings.create()</code> + batching</td>
  <td>Guarantees same model ID at ingest and query time — a mismatch silently breaks cosine scores</td>
</tr>
<tr>
  <td><code>PGVector.aadd_documents()</code></td>
  <td><code>CREATE TABLE</code>, <code>CREATE INDEX</code>, parameterised <code>INSERT</code> per chunk</td>
  <td>Schema + IVFFlat index provisioned automatically on startup; no migrations to write</td>
</tr>
<tr>
  <td><code>PGVector.similarity_search_with_relevance_scores()</code></td>
  <td>Embed query → <code>SELECT … ORDER BY embedding &lt;=&gt; $1 LIMIT k</code></td>
  <td>One call returns typed <code>(Document, float)</code> tuples that map directly to the API response</td>
</tr>
</tbody>
</table>

### Key design decisions

| Concern | Approach |
|---|---|
| **Retrieval** | pgvector IVFFlat cosine index; top-k chunks injected into the LLM system prompt at request time |
| **Streaming** | Next.js API route proxies Lambda retrieve call, then calls `streamText`; the AI SDK data-stream protocol delivers deltas directly to `useChat` — no polling |
| **Provider abstraction** | `pickModel()` in `app/api/chat/route.ts` returns the SDK model object; the rest of the route is provider-agnostic |
| **Embeddings** | Always OpenAI `text-embedding-3-small` regardless of LLM provider toggle — Anthropic has no embeddings API |
| **Lambda cold start** | Mangum wraps FastAPI; `lifespan` hook runs `init_db()` on cold start; asyncpg pool uses `max_inactive_connection_lifetime=30` to handle Neon's auto-pause reconnection |
| **No LLM response cache** | Same prompt + updated KB should return a different answer as documents change |

