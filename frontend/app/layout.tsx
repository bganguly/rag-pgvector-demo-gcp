import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "RAG Demo — pgvector + LangChain",
  description: "Ingest documents, search by meaning, stream grounded answers.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen">{children}</body>
    </html>
  );
}
