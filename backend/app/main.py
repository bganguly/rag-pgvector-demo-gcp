import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.docs import get_swagger_ui_html
from fastapi.responses import HTMLResponse
from mangum import Mangum

from app.db import init_db
from app.routes import ingest, reset, retrieve


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


app = FastAPI(
    title="RAG API",
    version="1.0.0",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
)

_raw_origins = os.getenv("CORS_ORIGINS", "*")
_origins = [o.strip() for o in _raw_origins.split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(ingest.router, prefix="/api")
app.include_router(retrieve.router, prefix="/api")
app.include_router(reset.router, prefix="/api")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/docs", include_in_schema=False)
async def custom_swagger() -> HTMLResponse:
    html = get_swagger_ui_html(
        openapi_url=app.openapi_url,
        title=app.title,
    )
    back_script = """
<script>
(function() {
  var a = document.createElement('a');
  a.href = 'https://bganguly.github.io/#rag';
  a.textContent = '← Portfolio';
  Object.assign(a.style, {
    position:'fixed', top:'12px', left:'12px', zIndex:9999,
    display:'inline-flex', alignItems:'center', gap:'4px',
    padding:'4px 10px', borderRadius:'6px', fontSize:'11px',
    fontFamily:'sans-serif', background:'rgba(0,0,0,0.7)',
    border:'1px solid rgba(255,255,255,0.12)', color:'#d4d4d8',
    textDecoration:'none', cursor:'pointer',
  });
  a.addEventListener('click', function(e) {
    e.preventDefault();
    var url = 'https://bganguly.github.io/#rag';
    try {
      if (window.opener && !window.opener.closed) {
        window.opener.location.href = url;
        window.close();
        return;
      }
    } catch(_) {}
    window.location.href = url;
  });
  document.body.appendChild(a);
})();
</script>"""
    body = html.body.decode().replace("</body>", back_script + "</body>")
    return HTMLResponse(content=body)


handler = Mangum(app, lifespan="auto")
