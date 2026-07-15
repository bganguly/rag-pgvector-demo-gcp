"""Pull Wikipedia articles and ingest them into the RAG backend."""

import sys
import httpx

TOPICS = [
    "Federal Reserve",
    "Inflation",
    "Interest rate",
    "Quantitative easing",
    "Monetary policy",
    "Gross domestic product",
]

BACKEND = "http://localhost:8001"


def fetch_wikipedia(topic: str) -> str:
    slug = topic.replace(" ", "_")
    url = f"https://en.wikipedia.org/api/rest_v1/page/summary/{slug}"
    r = httpx.get(url, timeout=10)
    r.raise_for_status()
    data = r.json()
    return data.get("extract", "")


def ingest(text: str, source: str) -> None:
    r = httpx.post(
        f"{BACKEND}/api/ingest",
        data={"text": text, "source": f"wikipedia/{source}"},
        timeout=60,
    )
    r.raise_for_status()
    result = r.json()
    print(f"  ✓  {source}: {result['chunks']} chunks")


def main() -> None:
    print(f"Seeding {len(TOPICS)} Wikipedia articles into {BACKEND}...\n")
    for topic in TOPICS:
        try:
            text = fetch_wikipedia(topic)
            if text:
                ingest(text, topic.replace(" ", "_"))
            else:
                print(f"  ✗  {topic}: empty extract")
        except Exception as exc:
            print(f"  ✗  {topic}: {exc}", file=sys.stderr)

    print("\nSeed complete. Try asking: 'How does the Fed control inflation?'")


if __name__ == "__main__":
    main()
