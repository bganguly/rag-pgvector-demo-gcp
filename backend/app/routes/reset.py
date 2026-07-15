from fastapi import APIRouter
from app.db import get_vector_store

router = APIRouter()


@router.delete("/reset")
def reset() -> dict:
    vs = get_vector_store()
    vs.delete_collection()
    vs.create_collection()
    return {"status": "cleared"}
