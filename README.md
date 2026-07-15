# RAG + pgvector Demo — LangChain · Vercel AI SDK · NVIDIA NIM

End-to-end **RAG pipeline** over any unstructured corpus: LangChain chunking, OpenAI embeddings stored
in **pgvector**, cosine-similarity retrieval, and token-level SSE streaming via **Vercel AI SDK**.
Provider toggle switches between Anthropic, OpenAI, and **NVIDIA NIM (Nemotron)** at runtime — same
interface, configurable `base_url`.

Sister repo: [agent-orchestration-demo](https://github.com/bganguly/agent-orchestration-demo)

---

| | |
|---|---|
| **RAG pipeline** | LangChain `RecursiveCharacterTextSplitter` (800 chars / 150 overlap) → OpenAI `text-embedding-3-small` (1 536 dims) → pgvector cosine similarity |
| **Vector store** | PostgreSQL 16 + pgvector extension; `langchain-postgres` `PGVector` handles schema, IVFFlat index, and async upsert |
| **LLM streaming** | Next.js App Router API route calls FastAPI `/api/retrieve`, then pipes context into Vercel AI SDK `streamText`; tokens stream to the browser via the AI SDK data-stream protocol |
| **Provider toggle** | Anthropic `claude-3-5-haiku-20241022` (default) · OpenAI `gpt-4o-mini` · NVIDIA NIM `nvidia/llama-3.3-nemotron-super-49b-v1` — switched from the header without reloading |
| **Ingest API** | `POST /api/ingest` accepts `.txt` / `.md` file upload or raw pasted text; chunked and embedded in one call |
| **Backend** | FastAPI 0.115 + asyncio; `lifespan` hook initialises pgvector extension and LangChain collection on startup |
| **Frontend** | Next.js 15 App Router, React 19, TypeScript 5.7, Tailwind CSS; `useChat` from `ai/react` |
| **Infra** | AWS ECS Fargate (frontend + backend) · RDS PostgreSQL 16 · CloudFront · ECR · CodeBuild · EventBridge schedules |

---

## Architecture

```
Browser ──► CloudFront ──► ALB ──► ECS Fargate :3010 (Next.js)
                                         │
                                         ├──► /api/retrieve ──► ECS Fargate :8001 (FastAPI)
                                         │                            │
                                         │                       LangChain pipeline
                                         │                       pgvector (RDS PG16)
                                         │                       OpenAI embeddings
                                         │
                                    Vercel AI SDK streamText ──► LLM provider

Ingest path:
  UI topic select / file upload ──► Next.js /api/ingest ──► FastAPI /api/ingest
                                                              LangChain splitter
                                                              OpenAI embed → pgvector
```

---

## Deploy (AWS ECS Fargate)

### Prerequisites

```bash
aws configure            # IAM user needs: ECS, ECR, RDS, S3, CodeBuild, IAM, CloudFront, EventBridge
cp .env.example .env     # fill in OPENAI_API_KEY (required) and optionally ANTHROPIC/NVIDIA keys
```

### Deploy

```bash
./scripts/deploy.sh
# → choose [2] Lite  (ECS Fargate + RDS db.t3.micro, ~$40-60/mo while running)
```

The script:
1. Provisions infra via Terraform (ECS cluster, ALB, RDS PG16, ECR repos, CodeBuild projects, EventBridge schedules)
2. Uploads source to S3 and builds both Docker images remotely via CodeBuild — no local Docker required
3. Registers new ECS task definitions and force-deploys both services
4. Prints the CloudFront URL when done (~5-10 min total)

**Auto-schedule:** ECS tasks start at 8 am and stop at 5 pm PT on weekdays. Use `[1] Start now` / `[2] Stop now` inside `deploy.sh` to control manually without a full re-deploy.

### Tear down

```bash
./scripts/infra-down.sh --aws
```

---

## Deploy (GCP Cloud Run)

```bash
gcloud auth login
gcloud config set project <your-project-id>
./scripts/deploy.sh
# → choose [3] Cloud
```

Provisions Cloud SQL PG16, Artifact Registry, and two Cloud Run services (backend + frontend). Images built via Cloud Build — no local Docker required.

---

## Using the App

1. **Select topics** — toggle the Wikipedia topic chips in the left panel (Federal Reserve, Inflation, GDP, etc.), then click **Load Selected** to fetch, chunk, embed, and store them.
2. **Ask a question** — pick from the **Sample questions** strip above the input (auto-submits), or type your own and press **Ask**.
3. **Switch provider** — use the Anthropic / OpenAI / NVIDIA NIM toggle in the header at any time.
4. **Custom documents** *(optional)* — expand **Custom Documents** at the bottom of the left panel to paste text or upload a `.txt` / `.md` file.

---

## Local Dev (no Docker)

### Prerequisites

```bash
brew install postgresql@16 redis pgvector node python@3.12
brew services start postgresql@16
brew services start redis
```

### Start

```bash
cp .env.example .env   # fill in API keys
./scripts/local-dev.sh
# or: ./scripts/local-dev.sh --seed   (also loads Wikipedia articles on first run)
```

| | |
|---|---|
| App | http://localhost:3010 |
| FastAPI docs | http://localhost:8001/docs |

The script auto-adjusts the DB/Redis ports for Homebrew (5432/6379), creates the `ragdb` database, enables the `vector` extension, sets up the Python venv, and starts both services.

---

## Quick Test

```bash
curl http://localhost:8001/health

curl -X POST http://localhost:8001/api/ingest \
  -F "text=The Federal Reserve sets interest rates to control inflation." \
  -F "source=test"

curl -X POST http://localhost:8001/api/retrieve \
  -H "Content-Type: application/json" \
  -d '{"query": "How does the Fed control inflation?", "k": 3}' | jq '.chunks[].score'
```
