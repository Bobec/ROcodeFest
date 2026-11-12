import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import Document from "@/components/Document";

export const metadata: Metadata = { title: "IMPULS 2027" };
export const viewport: Viewport = { width: "device-width", initialScale: 1 };

export default function SiteLayout({ children }: { children: ReactNode }) {
  return <Document>{children}</Document>;
}
