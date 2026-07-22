import type { Metadata } from "next";
import "./globals.css";
import BackToPortfolio from "../components/BackToPortfolio";

export const metadata: Metadata = {
  title: "RAG Demo — pgvector + LangChain",
  description: "Ingest documents, search by meaning, stream grounded answers.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen">
        <BackToPortfolio />
        {children}
      </body>
    </html>
  );
}
