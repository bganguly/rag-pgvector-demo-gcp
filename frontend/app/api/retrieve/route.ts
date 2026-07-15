export async function POST(req: Request) {
  const body = await req.json();
  const backendUrl = process.env.BACKEND_URL ?? "http://localhost:8001";

  try {
    const res = await fetch(`${backendUrl}/api/retrieve`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    return Response.json(data, { status: res.status });
  } catch {
    return Response.json({ chunks: [], error: "Backend unavailable" }, { status: 503 });
  }
}
