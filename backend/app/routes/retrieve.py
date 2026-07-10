from pydantic import BaseModel

from fastapi import APIRouter

from app.db import get_vector_store

router = APIRouter()


class RetrieveRequest(BaseModel):
    query: str
    k: int = 5


class Chunk(BaseModel):
    content: str
    source: str
    score: float


@router.post("/retrieve")
async def retrieve(req: RetrieveRequest) -> dict:
    vs = get_vector_store()
    results = await vs.asimilarity_search_with_relevance_scores(req.query, k=req.k)
    return {
        "query": req.query,
        "chunks": [
            Chunk(
                content=doc.page_content,
                source=doc.metadata.get("source", ""),
                score=round(score, 4),
            )
            for doc, score in results
        ],
    }
