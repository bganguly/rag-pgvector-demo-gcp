export async function POST(req: Request) {
  const formData = await req.formData();
  const backendUrl = process.env.BACKEND_URL ?? "http://localhost:8001";

  try {
    const res = await fetch(`${backendUrl}/api/ingest`, {
      method: "POST",
      body: formData,
      signal: AbortSignal.timeout(90000),
    });
    const data = await res.json();
    return Response.json(data, { status: res.status });
  } catch {
    return Response.json({ detail: "Backend unavailable" }, { status: 503 });
  }
}
