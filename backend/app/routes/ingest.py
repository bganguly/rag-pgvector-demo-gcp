from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from langchain_core.documents import Document
from langchain_text_splitters import RecursiveCharacterTextSplitter

from app.db import get_vector_store

router = APIRouter()

_splitter = RecursiveCharacterTextSplitter(chunk_size=800, chunk_overlap=150)


@router.post("/ingest")
async def ingest(
    file: UploadFile | None = File(default=None),
    text: str | None = Form(default=None),
    source: str = Form(default="manual"),
) -> dict:
    if file:
        raw = (await file.read()).decode("utf-8", errors="replace")
        source = source or file.filename or "upload"
    elif text:
        raw = text
    else:
        raise HTTPException(400, "Provide file or text")

    chunks = _splitter.split_text(raw)
    if not chunks:
        raise HTTPException(400, "No content extracted")

    docs = [Document(page_content=c, metadata={"source": source}) for c in chunks]
    vs = get_vector_store()
    await vs.aadd_documents(docs)

    return {"source": source, "chunks": len(chunks)}
