export async function GET() {
  const backendUrl = process.env.BACKEND_URL ?? "http://localhost:8001";
  try {
    await fetch(`${backendUrl}/health`, { signal: AbortSignal.timeout(30000) });
  } catch {}
  return new Response("ok", {
    status: 200,
    headers: {
      "Content-Type": "text/plain",
      "Access-Control-Allow-Origin": "*",
    },
  });
}
